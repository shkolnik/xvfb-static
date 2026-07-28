# Builds test/xi2-scroll-check.c (owned by a separate workstream; do not
# modify it here) as a fully static X11 client, for the XI2.1 scroll-valuators
# patch (patches/xserver-0006-scroll-valuators.patch). It talks to the
# packaged Xvfb only over the X11/XInput2/XTest wire protocol.
#
# Ordinary callPackage-style module: takes explicit package arguments, the
# same way package.nix and integration-test.nix do, so it evaluates purely
# and flake.nix can supply pkgsStatic via callPackage without any
# getFlake/currentSystem default here.
#
# The include/link recipe below (include dirs, link order, and -static -O2
# -Wall flags) was proven to compile and link cleanly inside this project's
# pinned build container; reused verbatim rather than re-derived through
# pkg-config, since xi2-scroll-check.c's own small, fixed dependency set gets
# no real benefit from that indirection.
{ stdenv, xorgproto, libx11, libxi, libxext, libxfixes, libxtst, libxcb, libxau, libxdmcp }:

stdenv.mkDerivation {
  pname = "xi2-scroll-check";
  version = "1";
  dontUnpack = true;
  buildInputs = [
    xorgproto
    libx11
    libxi
    libxext
    libxfixes
    libxtst
    libxcb
    libxau
    libxdmcp
  ];
  buildPhase = ''
    runHook preBuild
    $CC -O2 -static -Wall \
      -I${xorgproto.out}/include \
      -I${libx11.dev}/include \
      -I${libxi.dev}/include \
      -I${libxext.dev}/include \
      -I${libxfixes.dev}/include \
      -I${libxtst}/include \
      ${./xi2-scroll-check.c} \
      ${libxtst}/lib/libXtst.a \
      ${libxi}/lib/libXi.a \
      ${libx11}/lib/libX11.a \
      ${libxext}/lib/libXext.a \
      ${libxfixes}/lib/libXfixes.a \
      ${libxcb}/lib/libxcb.a \
      ${libxau}/lib/libXau.a \
      ${libxdmcp}/lib/libXdmcp.a \
      -o xi2-scroll-check
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp xi2-scroll-check $out/bin/
    runHook postInstall
  '';
}
