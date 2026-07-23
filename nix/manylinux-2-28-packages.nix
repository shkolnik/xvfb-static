{ system ? builtins.currentSystem
, hostSystem ? builtins.currentSystem
, hostPkgs ?
    let
      flake = builtins.getFlake (toString ../.);
    in
    import flake.inputs.nixpkgs { system = hostSystem; }
}:

let
  toolchain = import ./manylinux-2-28-stdenv.nix {
    inherit system hostPkgs;
  };
  flake = builtins.getFlake (toString ../.);
  nixpkgsSource = flake.inputs.nixpkgs;
  targetPkgs = import nixpkgsSource {
    inherit system;
    config.replaceStdenv = _pkgs:
      hostPkgs.stdenvAdapters.makeStaticLibraries toolchain.stdenv;
    overlays = [
      (_final: _previous: {
        # These packages are executed while target libraries are built. Keep
        # them on the normal host stdenv; only libraries incorporated into the
        # target artifact use the manylinux compatibility stdenv.
        file = hostPkgs.file;
        meson = hostPkgs.meson;
        ninja = hostPkgs.ninja;
        pkg-config = hostPkgs.pkg-config;
        bison = hostPkgs.bison;
        flex = hostPkgs.flex;
        intltool = hostPkgs.intltool;
        cmake = hostPkgs.cmake;
        cmakeMinimal = hostPkgs.cmakeMinimal;
        python3 = hostPkgs.python3;
        python3Packages = hostPkgs.python3Packages;
        perl = hostPkgs.perl;
        libtool = hostPkgs.libtool;
        swig = hostPkgs.swig;
      })
    ];
  };
in
{
  inherit hostPkgs targetPkgs toolchain;
}
