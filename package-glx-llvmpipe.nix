{ system ? builtins.currentSystem }:
let
  flake = builtins.getFlake "path:/src";
  pkgs = import flake.inputs.nixpkgs { inherit system; };
  static = pkgs.pkgsStatic;
  mesaLLVMpipe = import /src/mesa-llvmpipe.nix { inherit system; };
  targetLLVM = mesaLLVMpipe.targetLLVM;
  profiles = import /src/keyboard-profiles.nix;
  libxcvtStatic = static.libxcvt.overrideAttrs (old: {
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
  keymapBlobs = static.runCommand "xvfb-static-glx-keymaps" {
    nativeBuildInputs = [ static.xkbcomp ];
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
      xkbcomp -I${static.xkeyboard_config}/share/X11/xkb -xkm ${profile.id}.xkb $out/${profile.id}.xkm
      test -s $out/${profile.id}.xkm
    '') profileInputs)}
  '';
  xvfbGlx = static.xvfb.overrideAttrs (old: {
  pname = "xvfb-static-glx-llvmpipe";
  NIX_LDFLAGS = (old.NIX_LDFLAGS or "") + " -lstdc++";
  buildInputs = prepareDependencies (old.buildInputs or [ ]) ++ [
    mesaLLVMpipe
    static.ncurses
    static.stdenv.cc.cc.lib
  ];
  propagatedBuildInputs =
    prepareDependencies (old.propagatedBuildInputs or [ ]) ++ [ mesaLLVMpipe ];
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
    ${static.stdenv.cc.targetPrefix}strip --strip-all $out/bin/Xvfb
  '';
  });
  standardPackage = static.callPackage /src/package.nix { };
  releaseVersion = standardPackage.releaseVersion;
  releaseRevision = standardPackage.releaseRevision;
  nativeBuildInputs = [
    static.gnutar
    static.gzip
    static.jq
    static.xz
    static.stdenv.cc.bintools
  ];
in
static.runCommand "xvfb-static-glx-llvmpipe-alpha-${releaseVersion}" {
  inherit nativeBuildInputs;
  passthru = {
    inherit releaseRevision releaseVersion;
    upstreamVersion = xvfbGlx.version;
    mesaVersion = mesaLLVMpipe.version;
    llvmVersion = targetLLVM.version;
    variant = "glx";
    maturity = "alpha";
    renderer = "llvmpipe";
    graphicsBackend = "embedded";
    runtimeModel = "fully-static";
  };
} ''
  set -euo pipefail
  mkdir -p $out/bin $out/share/xvfb-static/licenses
  cp ${xvfbGlx}/bin/Xvfb $out/bin/Xvfb
  chmod u+w $out/bin/Xvfb
  ${static.stdenv.cc.targetPrefix}strip --strip-all $out/bin/Xvfb

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
      if [ "$match_count" -ne 1 ]; then
        echo "xvfb-static: expected exactly one $rel in $src, found $match_count" >&2
        exit 1
      fi
      tar -xf "$src" -O "$matches" > "$dest"
      test -s "$dest"
    fi
  }

  L=$out/share/xvfb-static/licenses
  extract_license ${static.xorg-server.src} COPYING $L/xorg-server.COPYING
  extract_license ${static.xkbcomp.src} COPYING $L/xkbcomp.COPYING
  extract_license ${static.xkeyboard_config.src} COPYING $L/xkeyboard-config.COPYING
  extract_license ${static.libx11.src} COPYING $L/libX11.COPYING
  extract_license ${static.libxext.src} COPYING $L/libXext.COPYING
  extract_license ${static.libxfont_2.src} COPYING $L/libXfont2.COPYING
  extract_license ${static.libxcvt.src} COPYING $L/libxcvt.COPYING
  extract_license ${static.pixman.src} COPYING $L/pixman.COPYING
  extract_license ${static.zlib.src} LICENSE $L/zlib.LICENSE
  extract_license ${static.libmd.src} COPYING $L/libmd.COPYING

  extract_license ${static.mesa.src} docs/license.rst $L/mesa.LICENSE
  extract_license ${targetLLVM.src} llvm/LICENSE.TXT $L/llvm.LICENSE
  extract_license ${targetLLVM.src} llvm/lib/Support/BLAKE3/LICENSE $L/llvm-BLAKE3.LICENSE
  extract_license ${targetLLVM.src} llvm/tools/polly/LICENSE.TXT $L/llvm-polly.LICENSE
  extract_license ${targetLLVM.src} llvm/tools/polly/lib/External/isl/LICENSE $L/llvm-polly-isl.LICENSE
  extract_license ${targetLLVM.src} llvm/tools/polly/lib/External/isl/imath/LICENSE $L/llvm-polly-isl-imath.LICENSE
  # libdrm 2.4.133's release archive has no standalone COPYING file. Its
  # primary public header carries the complete MIT notice; retain that exact
  # pinned source file rather than sourcing replacement text elsewhere.
  extract_license ${static.libdrm.src} xf86drm.h $L/libdrm-xf86drm.LICENSE-SOURCE
  extract_license ${static.libxshmfence.src} COPYING $L/libxshmfence.COPYING
  extract_license ${static.libxrandr.src} COPYING $L/libXrandr.COPYING
  extract_license ${static.libxrender.src} COPYING $L/libXrender.COPYING
  extract_license ${static.libxxf86vm.src} COPYING $L/libXxf86vm.COPYING
  extract_license ${static.libxcb.src} COPYING $L/libxcb.COPYING
  extract_license ${static.libxau.src} COPYING $L/libXau.COPYING
  extract_license ${static.libxdmcp.src} COPYING $L/libXdmcp.COPYING
  extract_license ${static.libxfixes.src} COPYING $L/libXfixes.COPYING
  extract_license ${static.libunwind.src} LICENSE $L/libunwind.LICENSE
  extract_license ${static.libunwind.src} COPYING $L/libunwind.COPYING
  extract_license ${static.ncurses.src} COPYING $L/ncurses.COPYING
  extract_license ${static.stdenv.cc.cc.src} COPYING3 $L/libstdc++-COPYING3
  extract_license ${static.stdenv.cc.cc.src} COPYING.RUNTIME $L/libstdc++-COPYING.RUNTIME

  files=$(cd $out && find . -type f | cut -c3- | {
    cat
    echo share/xvfb-static/manifest.json
  } | LC_ALL=C sort -u | jq -R -s 'split("\n") | map(select(length > 0))')
  jq -n \
    --arg arch "${static.stdenv.hostPlatform.parsed.cpu.name}" \
    --arg version "${releaseVersion}" \
    --argjson revision ${toString releaseRevision} \
    --arg xorg_version "${xvfbGlx.version}" \
    --arg mesa_version "${mesaLLVMpipe.version}" \
    --arg llvm_version "${targetLLVM.version}" \
    --argjson files "$files" \
    --argjson keyboard_profiles '${builtins.toJSON profiles}' \
    '{name:"xvfb-static",version:$version,revision:$revision,schema_version:2,arch:$arch,variant:"glx",maturity:"alpha",renderer:"llvmpipe",graphics_backend:"embedded",runtime_model:"fully-static",components:{"xorg-server":$xorg_version,mesa:$mesa_version,llvm:$llvm_version},keyboard:{default:"us",profiles:$keyboard_profiles},files:$files}' \
    > $out/share/xvfb-static/manifest.json
''
