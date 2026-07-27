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
