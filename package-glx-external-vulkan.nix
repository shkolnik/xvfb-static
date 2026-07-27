# See mesa-llvmpipe.nix for why nixpkgsSource is a parameter with a getFlake
# default: passing the flake's own locked input in keeps this out of an
# unlocked self-referential getFlake, which is what forced --impure.
{ system ? builtins.currentSystem
, nixpkgsSource ? (builtins.getFlake (toString ./.)).inputs.nixpkgs
}:
let
  staticOverrides = import ./nix/manylinux-2-28-static-overrides.nix;
  inherit (staticOverrides) noLsfontdir noPixmanTests noIntelNoValgrindLibdrm;
  packageSets = import ./nix/manylinux-2-28-packages.nix {
    inherit system nixpkgsSource;
  };
  # Target libraries are built by the manylinux compatibility stdenv.  Keep
  # native executables (build tools and archive assembly) on the ordinary host
  # package set; this is the only package-set boundary used by this derivation.
  pkgs = packageSets.targetPkgs;
  hostPkgs = packageSets.hostPkgs;
  toolchain = packageSets.toolchain;
  static = hostPkgs.pkgsStatic;
  mesaZink = import ./mesa-zink.nix {
    inherit system;
    targetPkgs = pkgs;
    hostPkgs = hostPkgs;
  };
  bzip2Static = pkgs.bzip2.override { enableStatic = true; };
  opensslStatic = (pkgs.openssl.override { static = true; }).overrideAttrs (old: {
    configureFlags = (old.configureFlags or [ ]) ++ [ "no-tests" ];
    doCheck = false;
  });
  catalog = import ./nix/keymap-catalog.nix {
    inherit (pkgs) lib runCommand;
    inherit (hostPkgs) xkbcomp xkeyboard_config;
    name = "xvfb-static-glx-external-vulkan-keymaps";
  };
  profiles = catalog.profiles;
  libxcvtStatic = pkgs.libxcvt.overrideAttrs (old: {
    meta = old.meta // { badPlatforms = [ ]; };
    postPatch = (old.postPatch or "") + ''
      substituteInPlace lib/meson.build --replace-fail 'shared_library(' 'library('
    '';
  });
  # Xvfb's fixed nixpkgs dependency graph can retain the unmodified
  # libXfont2 derivation even when the package-set overlay replaces the public
  # attribute.  Patch the exact dependency at the Xvfb boundary as well; see
  # nix/manylinux-2-28-static-overrides.nix.
  libxfont2Static = noLsfontdir pkgs.libxfont_2;
  pixmanStatic = noPixmanTests pkgs.pixman;
  valgrindStatic = pkgs.valgrind.overrideAttrs (_old: {
    # Valgrind is a build-time libdrm check dependency here; its own test
    # suite expects the host development resolver library and is not shipped.
    doCheck = false;
  });
  libdrmStatic = noIntelNoValgrindLibdrm pkgs.libdrm;
  prepareDependencies = dependencies:
    builtins.filter (dependency: (dependency.pname or "") != "libglvnd")
      (map (dependency:
        if (dependency.pname or "") == "libxcvt" then libxcvtStatic
        else if (dependency.pname or "") == "libxfont_2" then libxfont2Static
        else if (dependency.pname or "") == "pixman" then pixmanStatic
        else if (dependency.pname or "") == "valgrind" then valgrindStatic
        else if (dependency.pname or "") == "libdrm" then libdrmStatic
        else if (dependency.pname or "") == "openssl" then opensslStatic
        else dependency
      ) dependencies);
  prepareNativeDependencies = dependencies:
    map (dependency:
      if (dependency.pname or "") == "xkbcomp" then hostPkgs.xkbcomp else dependency
    ) dependencies;
  prepareMesonFlag = flag:
    if builtins.match "-Dxkb_bin_dir=.*" flag != null then
      "-Dxkb_bin_dir=${hostPkgs.xkbcomp}/bin"
    else if builtins.match "-Dxkb_dir=.*" flag != null then
      "-Dxkb_dir=${hostPkgs.xkeyboard_config}/share/X11/xkb"
    else
      flag;
  # The package boundary rewrites the build-time sysroot loader to the
  # deployment path selected by the compatibility stdenv. Keep this single
  # source of truth rather than duplicating an architecture conditional here.
  interpreter = toolchain.deploymentLoader;
  xvfbGlx = pkgs.xvfb.overrideAttrs (old: {
    pname = "xvfb-static-glx-external-vulkan";
    # Unlike the llvmpipe variant, this one deliberately does NOT append
    # -lstdc++ to NIX_LDFLAGS. Mesa's pkg-config metadata adds libstdc++ at the
    # final GL/Zink link, and keeping it out of the global linker flags lets
    # Meson probe plain C programs without forcing a C++ archive into every
    # probe. The C++ runtime is pulled in statically at link time instead.
    #
    # The assignment below reads as a no-op and nearly is: it sets NIX_LDFLAGS
    # to its own value. It is retained deliberately. pkgs.xvfb carries no
    # NIX_LDFLAGS attribute, so `or ""` defines the variable as empty rather
    # than leaving it undefined, and dropping the line changes this
    # derivation's hash. cc-wrapper treats empty and undefined identically, so
    # the built bytes would not change -- but proving that costs a full Mesa
    # and manylinux rebuild, and there is nothing to gain by spending it. If
    # you are already rebuilding this variant for another reason, delete the
    # line then and compare the archive checksum.
    NIX_LDFLAGS = old.NIX_LDFLAGS or "";
    NIX_CFLAGS_LINK = (old.NIX_CFLAGS_LINK or "") + " -static-libgcc -static-libstdc++";
    buildInputs = prepareDependencies (old.buildInputs or [ ]) ++ [
      pkgs.brotli
      bzip2Static
      pkgs.freetype
      pkgs.libfontenc
      mesaZink
      libdrmStatic
      pkgs.libpng
      pkgs.libx11
      pkgs.libxcb
      pkgs.libxext
      pkgs.libxfixes
      pkgs.libxxf86vm
      opensslStatic
      pkgs.zlib
    ];
    propagatedBuildInputs =
      prepareDependencies (old.propagatedBuildInputs or [ ]) ++ [ mesaZink ];
    nativeBuildInputs = prepareNativeDependencies (old.nativeBuildInputs or [ ])
      ++ [ hostPkgs.patchelf ];
    mesonFlags = map prepareMesonFlag (old.mesonFlags or [ ]) ++ [
      "-Dglx=true"
      "-Dc_link_args=-Wl,--allow-multiple-definition"
    ];
    patches = (old.patches or [ ]) ++ [
      ./patches/xserver-0001-xkb-env-overrides.patch
      ./patches/xserver-0002-embedded-keymap.patch
      ./patches/xserver-0003-keyboard-profile-option.patch
      ./patches/xserver-0004-component-log-prefixes.patch
      ./patches/xserver-0005-linked-swrast.patch
    ];
    postPatch = (old.postPatch or "") + ''
      substituteInPlace meson.build \
        --replace-fail "libcrypto_dep = cc.find_library('crypto', required: false)" \
        "libcrypto_dep = cc.find_library('crypto', required: false, static: true)"
      substituteInPlace meson.build \
        --replace-fail "xfont2_dep = dependency('xfont2', version: '>= 2.0')" \
        "xfont2_dep = dependency('xfont2', version: '>= 2.0', static: true)"
      substituteInPlace glx/meson.build \
        --replace-fail "dependency('gl', version: '>= 1.2')" \
        "dependency('gl', version: '>= 1.2', static: true)"
      substituteInPlace meson.build \
        --replace-fail "if host_machine.system() != 'windows'
    subdir('test')
endif" "message('Skipping unshipped Xserver test targets')"
      substituteInPlace hw/vfb/meson.build \
        --replace-fail 'dependencies: common_dep,' \
        "dependencies: common_dep, link_args: ['-Wl,--gc-sections', '${pkgs.lib.getLib bzip2Static}/lib/libbz2.a', '${pkgs.lib.getLib opensslStatic}/lib/libcrypto.a'],"
    '' + catalog.header;
    postInstall = (old.postInstall or "") + ''
      chmod u+w $out/bin/Xvfb
      ${hostPkgs.stdenv.cc.targetPrefix}strip --strip-all $out/bin/Xvfb
      patchelf --set-interpreter ${interpreter} --remove-rpath $out/bin/Xvfb
    '';
  });
  standardPackage = static.callPackage ./package.nix { };
  releaseVersion = standardPackage.releaseVersion;
  releaseRevision = standardPackage.releaseRevision;
in
pkgs.runCommand "xvfb-static-glx-external-vulkan-alpha-${releaseVersion}" {
  nativeBuildInputs = [
    hostPkgs.gnutar
    hostPkgs.gzip
    hostPkgs.jq
    hostPkgs.perl
    hostPkgs.patchelf
    hostPkgs.xz
    hostPkgs.stdenv.cc.bintools
    hostPkgs.nukeReferences
  ];
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
  ${hostPkgs.stdenv.cc.targetPrefix}strip --strip-all $out/bin/Xvfb
  patchelf --set-interpreter ${interpreter} --remove-rpath $out/bin/Xvfb

  ${builtins.readFile ./nix/scrub-store-references.sh}
  scrub_store_references $out/bin/Xvfb

  test "$(patchelf --print-interpreter $out/bin/Xvfb)" = "${interpreter}"
  test -z "$(patchelf --print-rpath $out/bin/Xvfb)"
  forbidden_strings="$(strings $out/bin/Xvfb |
    grep -E '/nix/store|libLLVM|LLVM_[0-9]|swrast_dri|libGL\.so|libgallium[^ ]*\.so' || true)"
  if test -n "$forbidden_strings"; then
    echo 'xvfb-static: external Vulkan binary contains forbidden runtime or LLVM references:' >&2
    printf '%s\n' "$forbidden_strings" >&2
    exit 1
  fi
  loader_string="$(strings $out/bin/Xvfb | grep -F 'libvulkan.so.1' || true)"
  test -n "$loader_string" || {
    echo 'xvfb-static: external Vulkan binary does not contain the host Vulkan loader ABI' >&2
    exit 1
  }

  glibc_symbol_floor="$(readelf --version-info -W $out/bin/Xvfb |
    sed -n 's/.*Name: GLIBC_\([0-9][0-9.]*\).*/\1/p' |
    sort -Vu | tail -n 1)"
  test -n "$glibc_symbol_floor"

  needed="$(readelf -dW $out/bin/Xvfb | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p')"
  while IFS= read -r library; do
    test -n "$library" || continue
    case "$library" in
      libc.so.6|libdl.so.2|libm.so.6|libpthread.so.0|librt.so.1|\
      ld-linux-aarch64.so.1|ld-linux-x86-64.so.2) ;;
      *) echo "xvfb-static: unexpected dynamic dependency: $library" >&2; exit 1 ;;
    esac
  done <<< "$needed"

  ${builtins.readFile ./nix/extract-license.sh}

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

  # This variant forbids incorporating LLVM at all, so its archive must carry no
  # LLVM notice.  The binary string scan above proves no LLVM code was linked;
  # this proves the packaging layer did not ship an LLVM notice regardless.
  # Without it, adding an extract_license line for LLVM would produce an
  # LLVM-notice-bearing archive with a green build.
  llvm_notices="$(find $L -type f \( -iname '*llvm*' -o -iname '*polly*' -o -iname '*blake3*' \) )"
  if test -n "$llvm_notices"; then
    echo 'xvfb-static: external Vulkan archive must not contain LLVM license texts:' >&2
    printf '%s\n' "$llvm_notices" >&2
    exit 1
  fi

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
    '{name:"xvfb-static",version:$version,revision:$revision,schema_version:2,arch:$arch,variant:"glx",maturity:"alpha",renderer:"zink",graphics_backend:"external-vulkan",runtime_model:"host-assisted",glibc_symbol_floor:$glibc_symbol_floor,required_graphics_library:"libvulkan.so.1",components:{"xorg-server":$xorg_version,mesa:$mesa_version},keyboard:{default:"us",profiles:$keyboard_profiles},files:$files}' \
    > $out/share/xvfb-static/manifest.json
''
