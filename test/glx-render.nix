{ system ? builtins.currentSystem }:
let
  flake = builtins.getFlake "path:/src";
  pkgs = import flake.inputs.nixpkgs { inherit system; };
  static = pkgs.pkgsStatic;
  mesaLLVMpipe = import /src/mesa-llvmpipe.nix { inherit system; };
in
static.stdenv.mkDerivation {
  pname = "xvfb-static-glx-render-test";
  version = "1";
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.pkg-config ];
  buildInputs = [
    mesaLLVMpipe
    static.libx11
    static.libxext
    static.libxau
    static.libxdmcp
  ];
  buildPhase = ''
    runHook preBuild
    $CC -O2 -static -Wl,--allow-multiple-definition ${./glx-render.c} \
      $(pkg-config --cflags --libs gl) \
      ${static.libxau}/lib/libXau.a ${static.libxdmcp}/lib/libXdmcp.a \
      -L${static.stdenv.cc.cc.lib}/lib -lstdc++ \
      -o glx-render-test
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp glx-render-test $out/bin/
    runHook postInstall
  '';
}
