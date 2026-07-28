# Builds test/xi2-scroll-check.c as a fully static X11 client. It reaches the
# packaged Xvfb only over the X11/XInput2/XTest wire protocol, so it needs no
# runtime relationship to the binary under test.
#
# Libraries are linked by explicit archive path rather than -l/pkg-config,
# because the link order below is what resolves cleanly against pkgsStatic.
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
