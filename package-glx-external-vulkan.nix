{ system ? builtins.currentSystem }:
let
  flake = builtins.getFlake "path:/src";
  pkgs = import flake.inputs.nixpkgs {
    inherit system;
    config.replaceStdenv = { pkgs }:
      pkgs.stdenvAdapters.makeStaticLibraries pkgs.stdenv;
    overlays = [
      (_final: previous: {
        # makeStaticLibraries does not mark the platform as isStatic, so
        # curl's default feature detection otherwise enables GSS/Kerberos.
        # Curl is build infrastructure here; the artifact neither links nor
        # needs its Kerberos integration.
        curlMinimal = previous.curlMinimal.override { gssSupport = false; };
        curl = previous.curl.override { gssSupport = false; };
        # CMake's bootstrap script rejects Autoconf's --disable-shared flag.
        cmakeMinimal = previous.cmakeMinimal.overrideAttrs (old: {
          dontAddStaticConfigureFlags = true;
          configureFlags = builtins.filter
            (flag: flag != "--enable-static" && flag != "--disable-shared")
            (old.configureFlags or [ ]);
        });
        # Build-only consumers here need the CMake generator, not CTest/CPack
        # or full CMake's static libarchive dependency closure.
        cmake = previous.cmakeMinimal.overrideAttrs (old: {
          dontAddStaticConfigureFlags = true;
          configureFlags = builtins.filter
            (flag: flag != "--enable-static" && flag != "--disable-shared")
            (old.configureFlags or [ ]);
        });
        libdrm = previous.libdrm.override {
          withIntel = false;
          withValgrind = false;
        };
        # libffi's checks add DejaGNU/Expect and a build-platform Tcl whose
        # shared-library assumptions are incompatible with this static stdenv.
        # The final Xvfb render/readback test exercises the incorporated FFI
        # path at the product boundary.
        libffi = previous.libffi.overrideAttrs (_old: {
          doCheck = false;
        });
        # SQLite is pulled in by the Python/Meson build toolchain, not linked
        # into Xvfb.  Its multi-minute upstream suite does not validate the
        # external-Vulkan artifact.
        sqlite = previous.sqlite.overrideAttrs (_old: {
          doCheck = false;
        });
        pythonPackagesExtensions = previous.pythonPackagesExtensions ++ [
          (_pythonFinal: pythonPrevious:
            previous.lib.mapAttrs (_name: package:
              if previous.lib.isDerivation package && package ? overridePythonAttrs
              then package.overridePythonAttrs (_old: {
                # These packages are build tooling for Mesa, not runtime
                # contents. Their upstream suites assume optional dynamic
                # Python extensions that this static-library environment may
                # omit. Mesa configuration/compilation and the packaged GLX
                # render test exercise the relevant behavior instead.
                doCheck = false;
                doInstallCheck = false;
              })
              else package
            ) pythonPrevious)
        ];
        # The static build cannot dlopen libxml2's shared test module.  The
        # library and command-line tools still build normally; only that
        # shared-module-dependent check phase is incompatible with this
        # package set.
        libxml2 = previous.libxml2.overrideAttrs (_old: {
          doCheck = false;
        });
        tcl = previous.tcl.overrideAttrs (old: {
          preFixup = (old.preFixup or "") + ''
            if [ -f "$out/lib/libtcl8.6.a" ]; then
              ln -sfn libtcl8.6.a "$out/lib/libtcl.so"
            fi
          '';
        });
      })
    ];
  };
  static = (import flake.inputs.nixpkgs { inherit system; }).pkgsStatic;
  mesaZink = import /src/mesa-zink.nix { inherit system; };
  profiles = import /src/keyboard-profiles.nix;
  libxcvtStatic = pkgs.libxcvt.overrideAttrs (old: {
    meta = old.meta // { badPlatforms = [ ]; };
    postPatch = (old.postPatch or "") + ''
      substituteInPlace lib/meson.build --replace-fail 'shared_library(' 'library('
    '';
  });
  prepareDependencies = dependencies:
    builtins.filter (dependency: (dependency.pname or "") != "libglvnd")
      (map (dependency:
        if (dependency.pname or "") == "libxcvt" then libxcvtStatic else dependency
      ) dependencies);
  profileInputs = map (profile: profile // {
    symbolInclude = profile.layout + (if profile.variant == "" then "" else "(${profile.variant})");
  }) profiles;
  keymapBlobs = pkgs.runCommand "xvfb-static-glx-external-vulkan-keymaps" {
    nativeBuildInputs = [ pkgs.xkbcomp ];
  } ''
    mkdir -p $out
    ${builtins.concatStringsSep "\n" (map (profile: ''
      cat > ${profile.id}.xkb <<'EOF'
      xkb_keymap "${profile.id}" {
        xkb_keycodes { include "evdev+aliases(qwerty)" };
        xkb_types { include "complete" };
        xkb_compatibility { include "complete" };
        xkb_symbols { include "pc+${profile.symbolInclude}+inet(evdev)" };
        xkb_geometry { include "pc(pc105)" };
      };
      EOF
      xkbcomp -I${pkgs.xkeyboard_config}/share/X11/xkb -xkm ${profile.id}.xkb $out/${profile.id}.xkm
      test -s $out/${profile.id}.xkm
    '') profileInputs)}
  '';
  interpreter = if pkgs.stdenv.hostPlatform.isAarch64
    then "/lib/ld-linux-aarch64.so.1"
    else "/lib64/ld-linux-x86-64.so.2";
  xvfbGlx = pkgs.xvfb.overrideAttrs (old: {
    pname = "xvfb-static-glx-external-vulkan";
    NIX_LDFLAGS = (old.NIX_LDFLAGS or "") + " -lstdc++";
    NIX_CFLAGS_LINK = (old.NIX_CFLAGS_LINK or "") + " -static-libgcc -static-libstdc++";
    buildInputs = prepareDependencies (old.buildInputs or [ ]) ++ [ mesaZink ];
    propagatedBuildInputs =
      prepareDependencies (old.propagatedBuildInputs or [ ]) ++ [ mesaZink ];
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.patchelf ];
    mesonFlags = (old.mesonFlags or [ ]) ++ [
      "-Dglx=true"
      "-Dc_link_args=-Wl,--allow-multiple-definition"
    ];
    patches = (old.patches or [ ]) ++ [
      /src/patches/xserver-0001-xkb-env-overrides.patch
      /src/patches/xserver-0002-embedded-keymap.patch
      /src/patches/xserver-0003-keyboard-profile-option.patch
      /src/patches/xserver-0004-component-log-prefixes.patch
      /src/patches/xserver-0004-linked-swrast.patch
    ];
    postPatch = (old.postPatch or "") + ''
      substituteInPlace hw/vfb/meson.build \
        --replace-fail 'dependencies: common_dep,' \
        "dependencies: common_dep, link_args: '-Wl,--gc-sections',"
      header=xkb/xvfb_static_keymap_blob.h
      : > "$header"
      ${builtins.concatStringsSep "\n" (map (profile: ''
        echo 'static const unsigned char xvfb_static_keymap_${builtins.replaceStrings ["-"] ["_"] profile.id}[] = {' >> "$header"
        od -An -v -tu1 ${keymapBlobs}/${profile.id}.xkm | tr -s ' ' | sed 's/ /,/g; s/^,//; s/$/,/' >> "$header"
        echo '};' >> "$header"
      '') profiles)}
      cat >> "$header" <<'EOF'
      struct xvfb_static_keymap_entry { const char *id; const unsigned char *data; size_t size; };
      static const struct xvfb_static_keymap_entry xvfb_static_keymaps[] = {
      EOF
      ${builtins.concatStringsSep "\n" (map (profile: ''
        echo '{ "${profile.id}", xvfb_static_keymap_${builtins.replaceStrings ["-"] ["_"] profile.id}, sizeof(xvfb_static_keymap_${builtins.replaceStrings ["-"] ["_"] profile.id}) },' >> "$header"
      '') profiles)}
      echo '};' >> "$header"
    '';
    postInstall = (old.postInstall or "") + ''
      chmod u+w $out/bin/Xvfb
      ${pkgs.stdenv.cc.targetPrefix}strip --strip-all $out/bin/Xvfb
      patchelf --set-interpreter ${interpreter} --remove-rpath $out/bin/Xvfb
    '';
  });
  standardPackage = static.callPackage /src/package.nix { };
  releaseVersion = standardPackage.releaseVersion;
  releaseRevision = standardPackage.releaseRevision;
in
pkgs.runCommand "xvfb-static-glx-external-vulkan-alpha-${releaseVersion}" {
  nativeBuildInputs = [ pkgs.gnutar pkgs.gzip pkgs.jq pkgs.patchelf pkgs.xz pkgs.stdenv.cc.bintools ];
  passthru = {
    inherit releaseRevision releaseVersion;
    upstreamVersion = xvfbGlx.version;
    mesaVersion = mesaZink.version;
    variant = "glx";
    maturity = "alpha";
    renderer = "zink";
    graphicsBackend = "external-vulkan";
    runtimeModel = "host-assisted";
  };
} ''
  set -euo pipefail
  mkdir -p $out/bin $out/share/xvfb-static/licenses
  cp ${xvfbGlx}/bin/Xvfb $out/bin/Xvfb
  chmod u+w $out/bin/Xvfb
  ${pkgs.stdenv.cc.targetPrefix}strip --strip-all $out/bin/Xvfb
  patchelf --set-interpreter ${interpreter} --remove-rpath $out/bin/Xvfb

  test "$(patchelf --print-interpreter $out/bin/Xvfb)" = "${interpreter}"
  test -z "$(patchelf --print-rpath $out/bin/Xvfb)"
  if strings $out/bin/Xvfb | grep -q '/nix/store'; then
    echo 'xvfb-static: external Vulkan binary contains a Nix store reference' >&2
    exit 1
  fi
  if strings $out/bin/Xvfb | grep -Eq 'libLLVM|LLVM_[0-9]'; then
    echo 'xvfb-static: external Vulkan binary unexpectedly contains LLVM' >&2
    exit 1
  fi

  glibc_symbol_floor="$(readelf --version-info -W $out/bin/Xvfb |
    sed -n 's/.*Name: GLIBC_\([0-9][0-9.]*\).*/\1/p' |
    sort -Vu | tail -n 1)"
  test -n "$glibc_symbol_floor"

  needed="$(readelf -dW $out/bin/Xvfb | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p')"
  while IFS= read -r library; do
    test -n "$library" || continue
    case "$library" in
      libc.so.6|libdl.so.2|libm.so.6|libpthread.so.0|librt.so.1) ;;
      *) echo "xvfb-static: unexpected dynamic dependency: $library" >&2; exit 1 ;;
    esac
  done <<< "$needed"

  extract_license() {
    src="$1"; rel="$2"; dest="$3"
    if [ -d "$src" ]; then
      test -s "$src/$rel"
      cp "$src/$rel" "$dest"
    else
      matches="$(tar -tf "$src" | while IFS= read -r member; do
        # Treat rel as relative to the source root. Release archives commonly
        # wrap that root in one directory, but nested files with the same
        # basename (notably GCC's several COPYING3 files) are not equivalent.
        case "$member" in
          "$rel") printf '%s\n' "$member" ;;
          */"$rel")
            prefix="''${member%/"$rel"}"
            case "$prefix" in
              */*) ;;
              *) printf '%s\n' "$member" ;;
            esac
            ;;
        esac
      done)"
      match_count="$(printf '%s\n' "$matches" | awk 'NF { count++ } END { print count + 0 }')"
      test "$match_count" -eq 1 || {
        echo "xvfb-static: expected exactly one $rel in $src, found $match_count" >&2
        exit 1
      }
      tar -xf "$src" -O "$matches" > "$dest"
      test -s "$dest"
    fi
  }

  L=$out/share/xvfb-static/licenses
  extract_license ${pkgs.xorg-server.src} COPYING $L/xorg-server.COPYING
  extract_license ${pkgs.xkbcomp.src} COPYING $L/xkbcomp.COPYING
  extract_license ${pkgs.xkeyboard_config.src} COPYING $L/xkeyboard-config.COPYING
  extract_license ${pkgs.libx11.src} COPYING $L/libX11.COPYING
  extract_license ${pkgs.libxext.src} COPYING $L/libXext.COPYING
  extract_license ${pkgs.libxfont_2.src} COPYING $L/libXfont2.COPYING
  extract_license ${pkgs.libxcvt.src} COPYING $L/libxcvt.COPYING
  extract_license ${pkgs.pixman.src} COPYING $L/pixman.COPYING
  extract_license ${pkgs.zlib.src} LICENSE $L/zlib.LICENSE
  extract_license ${pkgs.libmd.src} COPYING $L/libmd.COPYING
  extract_license ${pkgs.mesa.src} docs/license.rst $L/mesa.LICENSE
  # libdrm 2.4.133's release archive has no standalone COPYING file. Its
  # primary public header carries the complete MIT notice; retain that exact
  # pinned source file rather than sourcing replacement text elsewhere.
  extract_license ${pkgs.libdrm.src} xf86drm.h $L/libdrm-xf86drm.LICENSE-SOURCE
  extract_license ${pkgs.libxshmfence.src} COPYING $L/libxshmfence.COPYING
  extract_license ${pkgs.libxrandr.src} COPYING $L/libXrandr.COPYING
  extract_license ${pkgs.libxrender.src} COPYING $L/libXrender.COPYING
  extract_license ${pkgs.libxxf86vm.src} COPYING $L/libXxf86vm.COPYING
  extract_license ${pkgs.libxcb.src} COPYING $L/libxcb.COPYING
  extract_license ${pkgs.libxau.src} COPYING $L/libXau.COPYING
  extract_license ${pkgs.libxdmcp.src} COPYING $L/libXdmcp.COPYING
  extract_license ${pkgs.libxfixes.src} COPYING $L/libXfixes.COPYING
  extract_license ${pkgs.expat.src} COPYING $L/expat.COPYING
  extract_license ${pkgs.stdenv.cc.cc.src} COPYING3 $L/libstdc++-COPYING3
  extract_license ${pkgs.stdenv.cc.cc.src} COPYING.RUNTIME $L/libstdc++-COPYING.RUNTIME

  files=$(cd $out && find . -type f | cut -c3- | {
    cat
    echo share/xvfb-static/manifest.json
  } | LC_ALL=C sort -u | jq -R -s 'split("\n") | map(select(length > 0))')
  jq -n \
    --arg arch "${pkgs.stdenv.hostPlatform.parsed.cpu.name}" \
    --arg version "${releaseVersion}" \
    --argjson revision ${toString releaseRevision} \
    --arg xorg_version "${xvfbGlx.version}" \
    --arg mesa_version "${mesaZink.version}" \
    --arg glibc_symbol_floor "$glibc_symbol_floor" \
    --argjson files "$files" \
    --argjson keyboard_profiles '${builtins.toJSON profiles}' \
    '{name:"xvfb-static",version:$version,revision:$revision,schema_version:2,arch:$arch,variant:"glx",maturity:"alpha",renderer:"zink",graphics_backend:"external-vulkan",runtime_model:"host-assisted",target_minimum_host_glibc:"2.31",glibc_symbol_floor:$glibc_symbol_floor,required_graphics_library:"libvulkan.so.1",components:{"xorg-server":$xorg_version,mesa:$mesa_version},keyboard:{default:"us",profiles:$keyboard_profiles},files:$files}' \
    > $out/share/xvfb-static/manifest.json
''
