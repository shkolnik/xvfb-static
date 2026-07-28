# See mesa-llvmpipe.nix for why nixpkgsSource is a parameter with a getFlake
# default: passing the flake's own locked input in keeps this out of an
# unlocked self-referential getFlake, which is what forced --impure.
{ system ? builtins.currentSystem
, nixpkgsSource ? (builtins.getFlake (toString ./.)).inputs.nixpkgs
, corruptEmbeddedProfile ? null
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
  manifest = import ./nix/manifest.nix { inherit (pkgs) lib; };
  licenseClosure = import ./nix/license-closure.nix { inherit (pkgs) lib; };
  # Single source for the fields that used to be written twice -- once in
  # passthru, once in the manifest jq filter -- with nothing checking the
  # two copies agreed.
  variant = "glx";
  maturity = "alpha";
  renderer = "zink";
  graphicsBackend = "external-vulkan";
  runtimeModel = "host-assisted";
  requiredGraphicsLibrary = "libvulkan.so.1";
  bzip2Static = pkgs.bzip2.override { enableStatic = true; };
  opensslStatic = (pkgs.openssl.override { static = true; }).overrideAttrs (old: {
    configureFlags = (old.configureFlags or [ ]) ++ [ "no-tests" ];
    doCheck = false;
  });
  catalog = import ./nix/keymap-catalog.nix {
    inherit (pkgs) lib runCommand;
    inherit (hostPkgs) xkbcomp xkeyboard_config;
    name = "xvfb-static-glx-external-vulkan-keymaps";
    inherit corruptEmbeddedProfile;
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
    # See package.nix's xvfbPatched; needed here too so the version-agreement
    # assert below matches standardPackage.upstreamVersion.
    inherit (pkgs.xorg-server) src version;
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
  # pkgs.stdenv.cc.cc(.lib) is referenced below only for libstdc++'s own two
  # license files; its buildInputs describe what was needed to *build* GCC
  # (gmp, mpfr, isl, python3, bash, ...), not what Xvfb links against. See
  # nix/license-closure.nix's opaqueLeaves doc comment and
  # package-glx-llvmpipe.nix, which hit the same closure noise first.
  licenseOpaqueLeaves = [ pkgs.stdenv.cc.cc.lib ];
  findClosurePkg = licenseClosure.findInClosure {
    root = xvfbGlx;
    opaqueLeaves = licenseOpaqueLeaves;
  };
  licenseEntries = [
    { pkg = pkgs.xorg-server; rel = "COPYING"; dest = "xorg-server.COPYING"; }
    { pkg = hostPkgs.xkbcomp; rel = "COPYING"; dest = "xkbcomp.COPYING"; }
    { pkg = hostPkgs.xkeyboard_config; rel = "COPYING"; dest = "xkeyboard-config.COPYING"; }
    { pkg = pkgs.libx11; rel = "COPYING"; dest = "libX11.COPYING"; }
    { pkg = pkgs.libxext; rel = "COPYING"; dest = "libXext.COPYING"; }
    { pkg = pkgs.libxfont_2; rel = "COPYING"; dest = "libXfont2.COPYING"; }
    { pkg = pkgs.libxcvt; rel = "COPYING"; dest = "libxcvt.COPYING"; }
    { pkg = pkgs.pixman; rel = "COPYING"; dest = "pixman.COPYING"; }
    { pkg = pkgs.zlib; rel = "LICENSE"; dest = "zlib.LICENSE"; }
    { pkg = pkgs.libmd; rel = "COPYING"; dest = "libmd.COPYING"; }
    { pkg = pkgs.mesa; rel = "docs/license.rst"; dest = "mesa.LICENSE"; }
    # libdrm's release archive has no standalone COPYING file. Its primary
    # public header carries the complete MIT notice; retain that exact
    # pinned source file rather than sourcing replacement text elsewhere.
    { pkg = pkgs.libdrm; rel = "xf86drm.h"; dest = "libdrm-xf86drm.LICENSE-SOURCE"; }
    { pkg = pkgs.libxshmfence; rel = "COPYING"; dest = "libxshmfence.COPYING"; }
    { pkg = pkgs.libxrandr; rel = "COPYING"; dest = "libXrandr.COPYING"; }
    { pkg = pkgs.libxrender; rel = "COPYING"; dest = "libXrender.COPYING"; }
    { pkg = pkgs.libxxf86vm; rel = "COPYING"; dest = "libXxf86vm.COPYING"; }
    { pkg = pkgs.libxcb; rel = "COPYING"; dest = "libxcb.COPYING"; }
    { pkg = pkgs.libxau; rel = "COPYING"; dest = "libXau.COPYING"; }
    { pkg = pkgs.libxdmcp; rel = "COPYING"; dest = "libXdmcp.COPYING"; }
    { pkg = pkgs.libxfixes; rel = "COPYING"; dest = "libXfixes.COPYING"; }
    { pkg = pkgs.expat; rel = "COPYING"; dest = "expat.COPYING"; }
    { pkg = pkgs.stdenv.cc.cc; rel = "COPYING3"; dest = "libstdc++-COPYING3"; }
    { pkg = pkgs.stdenv.cc.cc; rel = "COPYING.RUNTIME"; dest = "libstdc++-COPYING.RUNTIME"; }

    # Below: found via the link-closure walk by pname, not a new explicit
    # reference, since nixpkgs' pname and its top-level attribute name
    # frequently disagree (e.g. pname "libxcb-image" is attribute
    # xcbutilimage). Same set as the standard and llvmpipe variants; see
    # package.nix for the freetype and mesa-gl-headers licensing rationale.
    { pkg = findClosurePkg "brotli"; rel = "LICENSE"; dest = "brotli.LICENSE"; }
    { pkg = findClosurePkg "bzip2"; rel = "LICENSE"; dest = "bzip2.LICENSE"; }
    { pkg = findClosurePkg "font-util"; rel = "COPYING"; dest = "font-util.COPYING"; }
    { pkg = findClosurePkg "freetype"; rel = "docs/FTL.TXT"; dest = "freetype.FTL"; }
    { pkg = findClosurePkg "libfontenc"; rel = "COPYING"; dest = "libfontenc.COPYING"; }
    { pkg = findClosurePkg "libpng-apng"; rel = "LICENSE"; dest = "libpng.LICENSE"; }
    { pkg = findClosurePkg "libpthread-stubs"; rel = "COPYING"; dest = "libpthread-stubs.COPYING"; }
    { pkg = findClosurePkg "libxcb-image"; rel = "COPYING"; dest = "xcb-util-image.COPYING"; }
    { pkg = findClosurePkg "libxcb-keysyms"; rel = "COPYING"; dest = "xcb-util-keysyms.COPYING"; }
    { pkg = findClosurePkg "libxcb-render-util"; rel = "COPYING"; dest = "xcb-util-renderutil.COPYING"; }
    { pkg = findClosurePkg "libxcb-util"; rel = "COPYING"; dest = "xcb-util.COPYING"; }
    { pkg = findClosurePkg "libxcb-wm"; rel = "COPYING"; dest = "xcb-util-wm.COPYING"; }
    { pkg = findClosurePkg "libxkbfile"; rel = "COPYING"; dest = "libxkbfile.COPYING"; }
    { pkg = findClosurePkg "mesa-gl-headers"; rel = "licenses/Apache-2.0"; dest = "mesa-gl-headers.Apache-2.0"; }
    { pkg = findClosurePkg "mesa-gl-headers"; rel = "licenses/MIT"; dest = "mesa-gl-headers.MIT"; }
    { pkg = findClosurePkg "mesa-gl-headers"; rel = "licenses/SGI-B-2.0"; dest = "mesa-gl-headers.SGI-B-2.0"; }
    # opensslStatic replaces pkgs.openssl in xvfbGlx's actual buildInputs
    # (see prepareDependencies above); findClosurePkg resolves to that same
    # overridden object, whose .src is the identical pinned openssl source.
    { pkg = findClosurePkg "openssl"; rel = "LICENSE.txt"; dest = "openssl.LICENSE"; }
    { pkg = findClosurePkg "xcb-proto"; rel = "COPYING"; dest = "xcb-proto.COPYING"; }
    { pkg = findClosurePkg "xtrans"; rel = "COPYING"; dest = "xtrans.COPYING"; }
    # zstd is dual-licensed (BSD or GPLv2, its own LICENSE/COPYING files
    # respectively); elect the permissive BSD text, consistent with
    # freetype's FTL election and the llvmpipe variant's zstd entry.
    { pkg = findClosurePkg "zstd"; rel = "LICENSE"; dest = "zstd.LICENSE"; }
  ];
  xorgprotoPkg = findClosurePkg "xorgproto";
  licenseAllowlist = [
    {
      pname = "dri-pkgconfig-stub";
      reason = "nixpkgs-internal generated pkg-config stub (writes a .pc file at build time); carries no upstream source or license.";
    }
    {
      pname = "empty-directory";
      reason = "nixpkgs-internal placeholder derivation used wherever an optional dependency is disabled; carries no upstream source.";
    }
    {
      pname = "bash";
      reason = "pulled in by nixpkgs setup-hook scripts; an interpreter for build-time hooks, not linked into the shipped binary.";
    }
    # Unlike the llvmpipe variant, this closure does not reach libxml2 (no
    # LLVM here) or the rest of that xz/find-xml-catalogs-hook chain, so
    # those entries have no match to allowlist here -- an unmatched
    # allowlist entry fails the audit as a stale-entry protection. See
    # package-glx-llvmpipe.nix for where that chain does apply.
  ];
  licenseAudit = licenseClosure.audit {
    root = xvfbGlx;
    label = "xvfb-static-glx-external-vulkan-alpha";
    entries = licenseEntries;
    allowlist = licenseAllowlist;
    extraCoveredPnames = [ "xorgproto" ];
    opaqueLeaves = licenseOpaqueLeaves;
  };
  licenseExtractLines = pkgs.lib.concatMapStrings
    (e: "extract_license ${e.pkg.src} ${e.rel} $L/${e.dest}\n")
    licenseEntries;
  standardPackage = static.callPackage ./package.nix { };
  releaseVersion = standardPackage.releaseVersion;
  releaseRevision = standardPackage.releaseRevision;
in
# The manifest's `version` field (releaseVersion, above) is derived from the
# *standard* variant's own patched Xvfb, built against hostPkgs.pkgsStatic,
# while its `xorg-server` component field (xvfbGlx.version, below) is derived
# from this build's independently evaluated GLX-patched Xvfb, built against
# the manylinux target package set. Both describe the same upstream X.Org
# Server release; nothing enforced that agreement before this assertion.
assert pkgs.lib.assertMsg (xvfbGlx.version == standardPackage.upstreamVersion) ''
  xvfb-static: GLX external-Vulkan Xvfb build reports X.Org Server version
  ${xvfbGlx.version}, but the standard static package reports
  ${standardPackage.upstreamVersion}. The manifest's version and xorg-server
  fields would disagree.'';
assert pkgs.lib.assertMsg licenseAudit.ok licenseAudit.message;
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
    inherit variant maturity renderer graphicsBackend runtimeModel;
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
  ${licenseExtractLines}
  extract_license_glob ${xorgprotoPkg.src} "COPYING-*" $L/xorgproto-

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

  ${manifest.mkManifestScript {
    arch = "${pkgs.stdenv.hostPlatform.parsed.cpu.name}";
    version = releaseVersion;
    revision = releaseRevision;
    xorgVersion = xvfbGlx.version;
    mesaVersion = mesaZink.version;
    glibcSymbolFloorVar = "glibc_symbol_floor";
    inherit variant maturity renderer graphicsBackend runtimeModel requiredGraphicsLibrary;
    inherit profiles;
  }}
''
