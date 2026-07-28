{ lib, xvfb, runCommand, xkeyboard_config, stdenv, buildPackages, gnutar, gzip, jq
, pixman, zlib, libmd
, xkbcomp, libxcvt, xorg-server, libx11, libxext, libxfont_2
, corruptEmbeddedProfile ? null
}:
let
  manifest = import ./nix/manifest.nix { inherit lib; };
  licenseClosure = import ./nix/license-closure.nix { inherit lib; };
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
    # nixpkgs' xvfb pins an older src/version than xorg-server as an internal
    # rebuild-avoidance hack; the two sources are otherwise identical, so track
    # xorg-server's instead (verified in this build container).
    inherit (xorg-server) src version;
    buildInputs = prepareXvfbDependencies (old.buildInputs or [ ]);
    propagatedBuildInputs = prepareXvfbDependencies (old.propagatedBuildInputs or [ ]);
    mesonFlags = (old.mesonFlags or [ ]) ++ [ "-Dglx=false" ];
    patches = (old.patches or [ ]) ++ [
      ./patches/xserver-0001-xkb-env-overrides.patch
      ./patches/xserver-0002-embedded-keymap.patch
      ./patches/xserver-0003-keyboard-profile-option.patch
      ./patches/xserver-0004-component-log-prefixes.patch
      ./patches/xserver-0006-scroll-valuators.patch
    ];
    postPatch = (old.postPatch or "") + catalog.header;
  });
  findClosurePkg = licenseClosure.findInClosure { root = xvfbPatched; };
  licenseEntries = [
    { pkg = xorg-server; rel = "COPYING"; dest = "xorg-server.COPYING"; }
    { pkg = xkbcomp; rel = "COPYING"; dest = "xkbcomp.COPYING"; }
    { pkg = xkeyboard_config; rel = "COPYING"; dest = "xkeyboard-config.COPYING"; }
    { pkg = libx11; rel = "COPYING"; dest = "libX11.COPYING"; }
    { pkg = libxext; rel = "COPYING"; dest = "libXext.COPYING"; }
    { pkg = libxfont_2; rel = "COPYING"; dest = "libXfont2.COPYING"; }
    { pkg = libxcvt; rel = "COPYING"; dest = "libxcvt.COPYING"; }
    { pkg = pixman; rel = "COPYING"; dest = "pixman.COPYING"; }
    { pkg = zlib; rel = "LICENSE"; dest = "zlib.LICENSE"; }
    { pkg = libmd; rel = "COPYING"; dest = "libmd.COPYING"; }
    # Below: found via the link-closure walk by pname, not a new
    # callPackage-wired argument, since nixpkgs' pname and its top-level
    # attribute name frequently disagree (e.g. pname "libxcb-image" is
    # attribute xcbutilimage).
    { pkg = findClosurePkg "brotli"; rel = "LICENSE"; dest = "brotli.LICENSE"; }
    { pkg = findClosurePkg "bzip2"; rel = "LICENSE"; dest = "bzip2.LICENSE"; }
    { pkg = findClosurePkg "font-util"; rel = "COPYING"; dest = "font-util.COPYING"; }
    # FreeType is dual-licensed: its own LICENSE.TXT says the FTL and GPLv2
    # options are "mutually exclusive" and the redistributor must choose one.
    # This project deliberately elects the permissive FTL, never GPLv2, to
    # stay consistent with an otherwise all-permissive closure. Ship
    # docs/FTL.TXT itself, not the top-level LICENSE.TXT explainer.
    { pkg = findClosurePkg "freetype"; rel = "docs/FTL.TXT"; dest = "freetype.FTL"; }
    # libdrm's release archive has no standalone COPYING file. Its primary
    # public header carries the complete MIT notice; retain that exact
    # pinned source file rather than sourcing replacement text elsewhere.
    { pkg = findClosurePkg "libdrm"; rel = "xf86drm.h"; dest = "libdrm-xf86drm.LICENSE-SOURCE"; }
    { pkg = findClosurePkg "libfontenc"; rel = "COPYING"; dest = "libfontenc.COPYING"; }
    { pkg = findClosurePkg "libpng-apng"; rel = "LICENSE"; dest = "libpng.LICENSE"; }
    { pkg = findClosurePkg "libpthread-stubs"; rel = "COPYING"; dest = "libpthread-stubs.COPYING"; }
    { pkg = findClosurePkg "libxau"; rel = "COPYING"; dest = "libXau.COPYING"; }
    { pkg = findClosurePkg "libxcb"; rel = "COPYING"; dest = "libxcb.COPYING"; }
    { pkg = findClosurePkg "libxcb-image"; rel = "COPYING"; dest = "xcb-util-image.COPYING"; }
    { pkg = findClosurePkg "libxcb-keysyms"; rel = "COPYING"; dest = "xcb-util-keysyms.COPYING"; }
    { pkg = findClosurePkg "libxcb-render-util"; rel = "COPYING"; dest = "xcb-util-renderutil.COPYING"; }
    { pkg = findClosurePkg "libxcb-util"; rel = "COPYING"; dest = "xcb-util.COPYING"; }
    { pkg = findClosurePkg "libxcb-wm"; rel = "COPYING"; dest = "xcb-util-wm.COPYING"; }
    { pkg = findClosurePkg "libxdmcp"; rel = "COPYING"; dest = "libXdmcp.COPYING"; }
    { pkg = findClosurePkg "libxfixes"; rel = "COPYING"; dest = "libXfixes.COPYING"; }
    { pkg = findClosurePkg "libxkbfile"; rel = "COPYING"; dest = "libxkbfile.COPYING"; }
    { pkg = findClosurePkg "libxshmfence"; rel = "COPYING"; dest = "libxshmfence.COPYING"; }
    # mesa-gl-headers vendors Mesa's own include/{GL,EGL,GLES*} tree as a
    # headers-only dependency -- pulled in directly by upstream xorg-server
    # for DRI3/Present support, independent of whether GLX is enabled, and
    # confirmed (2026-07) to be a direct propagatedBuildInput of nixpkgs'
    # own xvfb derivation, not something this project's overrides add. Its
    # aggregate licenses/ directory covers Mesa's entire upstream
    # repository, not just this header subset; the actual public GL/EGL API
    # headers packaged here are Khronos-style permissive. Ship the
    # plausibly-applicable permissive texts and deliberately omit the
    # GPL-1.0, GPL-2.0, and BSL-1.0 texts also present in that directory,
    # which cover unrelated files elsewhere in Mesa's tree.
    { pkg = findClosurePkg "mesa-gl-headers"; rel = "licenses/Apache-2.0"; dest = "mesa-gl-headers.Apache-2.0"; }
    { pkg = findClosurePkg "mesa-gl-headers"; rel = "licenses/MIT"; dest = "mesa-gl-headers.MIT"; }
    { pkg = findClosurePkg "mesa-gl-headers"; rel = "licenses/SGI-B-2.0"; dest = "mesa-gl-headers.SGI-B-2.0"; }
    { pkg = findClosurePkg "openssl"; rel = "LICENSE.txt"; dest = "openssl.LICENSE"; }
    { pkg = findClosurePkg "xcb-proto"; rel = "COPYING"; dest = "xcb-proto.COPYING"; }
    { pkg = findClosurePkg "xtrans"; rel = "COPYING"; dest = "xtrans.COPYING"; }
  ];
  # xorgproto ships one COPYING-<protocol> file per protocol instead of one
  # aggregate license file; extracted separately via extract_license_glob,
  # so it is not part of licenseEntries and is instead named explicitly to
  # the audit below as covered.
  xorgprotoPkg = findClosurePkg "xorgproto";
  licenseAllowlist = [
    {
      pname = "dri-pkgconfig-stub";
      reason = "nixpkgs-internal generated pkg-config stub (writes a .pc file at build time); carries no upstream source or license.";
    }
  ];
  licenseAudit = licenseClosure.audit {
    root = xvfbPatched;
    label = "xvfb-static";
    entries = licenseEntries;
    allowlist = licenseAllowlist;
    extraCoveredPnames = [ "xorgproto" ];
  };
  licenseExtractLines = lib.concatMapStrings
    (e: "extract_license ${e.pkg.src} ${e.rel} $L/${e.dest}\n")
    licenseEntries;
  releaseRevision = 1;
  releaseVersion = "${xvfbPatched.version}-r${toString releaseRevision}";
  # Single source for the fields written into both passthru and the manifest.
  # This variant carries no renderer/graphicsBackend/runtimeModel: it links no
  # GL stack at all, so those axes have no value to report rather than a
  # default one.
  variant = "no-glx";
  maturity = "stable";
  # nuke-refs and perl scrub the binary; they run on the build machine and must
  # not come from the static target package set.
  nativeBuildInputs = [
    gnutar gzip jq stdenv.cc.bintools
    buildPackages.nukeReferences buildPackages.perl
  ];
  strip = "${stdenv.cc.targetPrefix}strip";
in
assert lib.assertMsg licenseAudit.ok licenseAudit.message;
runCommand "xvfb-static-no-glx-${releaseVersion}" {
  inherit nativeBuildInputs;
  passthru = {
    inherit releaseRevision releaseVersion;
    upstreamVersion = xvfbPatched.version;
    inherit variant maturity;
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
  ${licenseExtractLines}
  extract_license_glob ${xorgprotoPkg.src} "COPYING-*" $L/xorgproto-
  ${manifest.mkManifestScript {
    arch = "${stdenv.hostPlatform.parsed.cpu.name}";
    version = releaseVersion;
    revision = releaseRevision;
    xorgVersion = xvfbPatched.version;
    inherit variant maturity profiles;
  }}
''
