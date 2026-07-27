{ lib, xvfb, runCommand, xkeyboard_config, stdenv, buildPackages, gnutar, gzip, jq
, pixman, zlib, libmd
, xkbcomp, libxcvt, xorg-server, libx11, libxext, libxfont_2
, corruptEmbeddedProfile ? null
}:
let
  manifest = import ./nix/manifest.nix { inherit lib; };
  catalog = import ./nix/keymap-catalog.nix {
    inherit lib runCommand xkbcomp xkeyboard_config corruptEmbeddedProfile;
  };
  profiles = catalog.profiles;
  libxcvtStatic = libxcvt.overrideAttrs (old: {
    meta = old.meta // { badPlatforms = [ ]; };
    postPatch = (old.postPatch or "") + ''
      substituteInPlace lib/meson.build --replace-fail 'shared_library(' 'library('
    '';
  });
  prepareXvfbDependencies = dependencies:
    builtins.filter (dependency: (dependency.pname or "") != "libglvnd")
      (map (dependency:
        if (dependency.pname or "") == "libxcvt" then libxcvtStatic else dependency
      ) dependencies);
  xvfbPatched = xvfb.overrideAttrs (old: {
    pname = "xvfb-static";
    buildInputs = prepareXvfbDependencies (old.buildInputs or [ ]);
    propagatedBuildInputs = prepareXvfbDependencies (old.propagatedBuildInputs or [ ]);
    mesonFlags = (old.mesonFlags or [ ]) ++ [ "-Dglx=false" ];
    patches = (old.patches or [ ]) ++ [
      ./patches/xserver-0001-xkb-env-overrides.patch
      ./patches/xserver-0002-embedded-keymap.patch
      ./patches/xserver-0003-keyboard-profile-option.patch
      ./patches/xserver-0004-component-log-prefixes.patch
    ];
    postPatch = (old.postPatch or "") + catalog.header;
  });
  releaseRevision = 4;
  releaseVersion = "${xvfbPatched.version}-r${toString releaseRevision}";
  # nuke-refs and perl scrub the binary; they run on the build machine and must
  # not come from the static target package set.
  nativeBuildInputs = [
    gnutar gzip jq stdenv.cc.bintools
    buildPackages.nukeReferences buildPackages.perl
  ];
  strip = "${stdenv.cc.targetPrefix}strip";
in runCommand "xvfb-static-${releaseVersion}" {
  inherit nativeBuildInputs;
  passthru = {
    inherit releaseRevision releaseVersion;
    upstreamVersion = xvfbPatched.version;
  };
} ''
  set -euo pipefail
  mkdir -p $out/bin $out/share/xvfb-static/licenses
  cp ${xvfbPatched}/bin/Xvfb $out/bin/Xvfb
  chmod u+w $out/bin/Xvfb
  ${strip} --strip-all $out/bin/Xvfb

  ${builtins.readFile ./nix/scrub-store-references.sh}
  scrub_store_references $out/bin/Xvfb

  ${builtins.readFile ./nix/extract-license.sh}
  L=$out/share/xvfb-static/licenses
  extract_license ${xorg-server.src} COPYING $L/xorg-server.COPYING
  extract_license ${xkbcomp.src} COPYING $L/xkbcomp.COPYING
  extract_license ${xkeyboard_config.src} COPYING $L/xkeyboard-config.COPYING
  extract_license ${libx11.src} COPYING $L/libX11.COPYING
  extract_license ${libxext.src} COPYING $L/libXext.COPYING
  extract_license ${libxfont_2.src} COPYING $L/libXfont2.COPYING
  extract_license ${libxcvt.src} COPYING $L/libxcvt.COPYING
  extract_license ${pixman.src} COPYING $L/pixman.COPYING
  extract_license ${zlib.src} LICENSE $L/zlib.COPYING
  extract_license ${libmd.src} COPYING $L/libmd.COPYING
  ${manifest.mkManifestScript {
    arch = "${stdenv.hostPlatform.parsed.cpu.name}";
    version = releaseVersion;
    revision = releaseRevision;
    xorgVersion = xvfbPatched.version;
    inherit profiles;
  }}
''
