# See mesa-llvmpipe.nix for why pkgs is a parameter with a getFlake default.
{ system ? builtins.currentSystem
, pkgs ? import (builtins.getFlake (toString ./.)).inputs.nixpkgs { inherit system; }
, corruptEmbeddedProfile ? null
}:
let
  static = pkgs.pkgsStatic;
  mesaLLVMpipe = import ./mesa-llvmpipe.nix { inherit system pkgs; };
  targetLLVM = mesaLLVMpipe.targetLLVM;
  manifest = import ./nix/manifest.nix { inherit (pkgs) lib; };
  licenseClosure = import ./nix/license-closure.nix { inherit (pkgs) lib; };
  # Single source for the fields that used to be written twice -- once in
  # passthru, once in the manifest jq filter -- with nothing checking the
  # two copies agreed.
  variant = "glx";
  maturity = "alpha";
  renderer = "llvmpipe";
  graphicsBackend = "embedded";
  runtimeModel = "fully-static";
  catalog = import ./nix/keymap-catalog.nix {
    inherit (pkgs) lib;
    inherit (static) runCommand xkbcomp xkeyboard_config;
    name = "xvfb-static-glx-keymaps";
    inherit corruptEmbeddedProfile;
  };
  profiles = catalog.profiles;
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
    ./patches/xserver-0001-xkb-env-overrides.patch
    ./patches/xserver-0002-embedded-keymap.patch
    ./patches/xserver-0003-keyboard-profile-option.patch
    ./patches/xserver-0004-component-log-prefixes.patch
    ./patches/xserver-0005-linked-swrast.patch
  ];
  postPatch = (old.postPatch or "") + ''
    substituteInPlace hw/vfb/meson.build \
      --replace-fail 'dependencies: common_dep,' \
      "dependencies: common_dep, link_args: '-Wl,--gc-sections',"
  '' + catalog.header;
  postInstall = (old.postInstall or "") + ''
    chmod u+w $out/bin/Xvfb
    ${static.stdenv.cc.targetPrefix}strip --strip-all $out/bin/Xvfb
  '';
  });
  # static.stdenv.cc.cc(.lib) is referenced below only for libstdc++'s own
  # two license files; its buildInputs describe what was needed to *build*
  # GCC (gmp, mpfr, isl, python3, bash, ...), not what Xvfb links against.
  # See nix/license-closure.nix's opaqueLeaves doc comment.
  # xvfbGlx's buildInputs reference the .lib output specifically (a
  # different outPath than the default "out" output), so opaqueLeaves must
  # match that exact output to be recognized during the closure walk.
  #
  # static.python3 is propagated by both stdenv.cc.cc.lib (GCC's own build
  # tooling) and static.mesa (Mesa's Meson-based code generators, e.g. its
  # GLSL builtin and dispatch-table generators) -- confirmed (2026-07) via
  # direct buildInputs inspection of both. Python is not itself statically
  # compiled into Xvfb; its own huge stdlib dependency closure (sqlite,
  # gdbm, readline, tzdata, mpdecimal, bluez-headers, libxcrypt, ...) is
  # exactly the same category of noise as GCC's build-time closure above.
  licenseOpaqueLeaves = [ static.stdenv.cc.cc.lib static.python3 ];
  findClosurePkg = licenseClosure.findInClosure {
    root = xvfbGlx;
    opaqueLeaves = licenseOpaqueLeaves;
  };
  licenseEntries = [
    { pkg = static.xorg-server; rel = "COPYING"; dest = "xorg-server.COPYING"; }
    { pkg = static.xkbcomp; rel = "COPYING"; dest = "xkbcomp.COPYING"; }
    { pkg = static.xkeyboard_config; rel = "COPYING"; dest = "xkeyboard-config.COPYING"; }
    { pkg = static.libx11; rel = "COPYING"; dest = "libX11.COPYING"; }
    { pkg = static.libxext; rel = "COPYING"; dest = "libXext.COPYING"; }
    { pkg = static.libxfont_2; rel = "COPYING"; dest = "libXfont2.COPYING"; }
    { pkg = static.libxcvt; rel = "COPYING"; dest = "libxcvt.COPYING"; }
    { pkg = static.pixman; rel = "COPYING"; dest = "pixman.COPYING"; }
    { pkg = static.zlib; rel = "LICENSE"; dest = "zlib.LICENSE"; }
    { pkg = static.libmd; rel = "COPYING"; dest = "libmd.COPYING"; }

    { pkg = static.mesa; rel = "docs/license.rst"; dest = "mesa.LICENSE"; }
    { pkg = targetLLVM; rel = "llvm/LICENSE.TXT"; dest = "llvm.LICENSE"; }
    { pkg = targetLLVM; rel = "llvm/lib/Support/BLAKE3/LICENSE"; dest = "llvm-BLAKE3.LICENSE"; }
    { pkg = targetLLVM; rel = "llvm/tools/polly/LICENSE.TXT"; dest = "llvm-polly.LICENSE"; }
    { pkg = targetLLVM; rel = "llvm/tools/polly/lib/External/isl/LICENSE"; dest = "llvm-polly-isl.LICENSE"; }
    { pkg = targetLLVM; rel = "llvm/tools/polly/lib/External/isl/imath/LICENSE"; dest = "llvm-polly-isl-imath.LICENSE"; }
    # libdrm 2.4.133's release archive has no standalone COPYING file. Its
    # primary public header carries the complete MIT notice; retain that
    # exact pinned source file rather than sourcing replacement text
    # elsewhere.
    { pkg = static.libdrm; rel = "xf86drm.h"; dest = "libdrm-xf86drm.LICENSE-SOURCE"; }
    { pkg = static.libxshmfence; rel = "COPYING"; dest = "libxshmfence.COPYING"; }
    { pkg = static.libxrandr; rel = "COPYING"; dest = "libXrandr.COPYING"; }
    { pkg = static.libxrender; rel = "COPYING"; dest = "libXrender.COPYING"; }
    { pkg = static.libxxf86vm; rel = "COPYING"; dest = "libXxf86vm.COPYING"; }
    { pkg = static.libxcb; rel = "COPYING"; dest = "libxcb.COPYING"; }
    { pkg = static.libxau; rel = "COPYING"; dest = "libXau.COPYING"; }
    { pkg = static.libxdmcp; rel = "COPYING"; dest = "libXdmcp.COPYING"; }
    { pkg = static.libxfixes; rel = "COPYING"; dest = "libXfixes.COPYING"; }
    { pkg = static.libunwind; rel = "LICENSE"; dest = "libunwind.LICENSE"; }
    { pkg = static.libunwind; rel = "COPYING"; dest = "libunwind.COPYING"; }
    { pkg = static.ncurses; rel = "COPYING"; dest = "ncurses.COPYING"; }
    { pkg = static.stdenv.cc.cc; rel = "COPYING3"; dest = "libstdc++-COPYING3"; }
    { pkg = static.stdenv.cc.cc; rel = "COPYING.RUNTIME"; dest = "libstdc++-COPYING.RUNTIME"; }
    # Direct buildInputs of targetLLVM (libxml2, libffi, libpfm) and of
    # static.mesa (expat, zstd) surfaced by the closure audit; none had a
    # notice before. libxml2's license text lives in a file conventionally
    # named "Copyright", not COPYING/LICENSE.
    { pkg = static.libxml2; rel = "Copyright"; dest = "libxml2.Copyright"; }
    { pkg = static.libffi; rel = "LICENSE"; dest = "libffi.LICENSE"; }
    { pkg = static.libpfm; rel = "COPYING"; dest = "libpfm.COPYING"; }
    { pkg = static.expat; rel = "COPYING"; dest = "expat.COPYING"; }
    # zstd is dual-licensed (BSD or GPLv2, its own LICENSE/COPYING files
    # respectively); elect the permissive BSD text, consistent with
    # freetype's FTL election in package.nix.
    { pkg = static.zstd; rel = "LICENSE"; dest = "zstd.LICENSE"; }

    # Below: found via the link-closure walk by pname, not a new explicit
    # reference, since nixpkgs' pname and its top-level attribute name
    # frequently disagree (e.g. pname "libxcb-image" is attribute
    # xcbutilimage). Same set as package.nix's standard variant; see there
    # for the freetype and mesa-gl-headers licensing rationale.
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
    { pkg = findClosurePkg "openssl"; rel = "LICENSE.txt"; dest = "openssl.LICENSE"; }
    { pkg = findClosurePkg "xcb-proto"; rel = "COPYING"; dest = "xcb-proto.COPYING"; }
    { pkg = findClosurePkg "xtrans"; rel = "COPYING"; dest = "xtrans.COPYING"; }
  ];
  xorgprotoPkg = findClosurePkg "xorgproto";
  licenseAllowlist = [
    {
      pname = "dri-pkgconfig-stub";
      reason = "nixpkgs-internal generated pkg-config stub (writes a .pc file at build time); carries no upstream source or license.";
    }
    {
      pname = "python3";
      reason = "propagated by GCC and Mesa as a build-time code-generation tool; not linked into the shipped binary. See licenseOpaqueLeaves above.";
    }
    {
      pname = "empty-directory";
      reason = "nixpkgs-internal placeholder derivation used wherever an optional dependency is disabled; carries no upstream source.";
    }
    {
      pname = "bash";
      reason = "pulled in by nixpkgs setup-hook scripts (e.g. libxml2's find-xml-catalogs-hook); an interpreter for build-time hooks, not linked into the shipped binary.";
    }
    {
      pname = "xz";
      reason = "build-time compression tool pulled in transitively by nixpkgs build tooling; not a direct buildInput of anything in this closure, so not evidence of real static linkage.";
    }
    {
      pname = "find-xml-catalogs-hook";
      reason = "nixpkgs setup-hook that registers XML catalog paths at build time; no upstream source or shipped code.";
    }
  ];
  licenseAudit = licenseClosure.audit {
    root = xvfbGlx;
    label = "xvfb-static-glx-llvmpipe-alpha";
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
  nativeBuildInputs = [
    static.gnutar
    static.gzip
    static.jq
    static.xz
    static.stdenv.cc.bintools
    # nuke-refs and perl scrub the binary; they run on the build machine and
    # must not come from the static target package set.
    pkgs.nukeReferences
    pkgs.perl
  ];
in
# The manifest's `version` field (releaseVersion, above) is derived from the
# *standard* variant's own patched Xvfb, while its `xorg-server` component
# field (xvfbGlx.version, below) is derived from this build's independently
# evaluated GLX-patched Xvfb. Both describe the same upstream X.Org Server
# release; nothing enforced that agreement before this assertion.
assert pkgs.lib.assertMsg (xvfbGlx.version == standardPackage.upstreamVersion) ''
  xvfb-static: GLX llvmpipe Xvfb build reports X.Org Server version
  ${xvfbGlx.version}, but the standard static package reports
  ${standardPackage.upstreamVersion}. The manifest's version and xorg-server
  fields would disagree.'';
assert pkgs.lib.assertMsg licenseAudit.ok licenseAudit.message;
static.runCommand "xvfb-static-glx-llvmpipe-alpha-${releaseVersion}" {
  inherit nativeBuildInputs;
  passthru = {
    inherit releaseRevision releaseVersion;
    upstreamVersion = xvfbGlx.version;
    mesaVersion = mesaLLVMpipe.version;
    llvmVersion = targetLLVM.version;
    inherit variant maturity renderer graphicsBackend runtimeModel;
  };
} ''
  set -euo pipefail
  mkdir -p $out/bin $out/share/xvfb-static/licenses
  cp ${xvfbGlx}/bin/Xvfb $out/bin/Xvfb
  chmod u+w $out/bin/Xvfb
  ${static.stdenv.cc.targetPrefix}strip --strip-all $out/bin/Xvfb

  ${builtins.readFile ./nix/scrub-store-references.sh}
  scrub_store_references $out/bin/Xvfb

  ${builtins.readFile ./nix/extract-license.sh}

  L=$out/share/xvfb-static/licenses
  ${licenseExtractLines}
  extract_license_glob ${xorgprotoPkg.src} "COPYING-*" $L/xorgproto-

  ${manifest.mkManifestScript {
    arch = "${static.stdenv.hostPlatform.parsed.cpu.name}";
    version = releaseVersion;
    revision = releaseRevision;
    xorgVersion = xvfbGlx.version;
    mesaVersion = mesaLLVMpipe.version;
    llvmVersion = targetLLVM.version;
    inherit variant maturity renderer graphicsBackend runtimeModel;
    inherit profiles;
  }}
''
