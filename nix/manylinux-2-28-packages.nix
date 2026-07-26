# nixpkgsSource is a parameter so flake.nix can pass its own locked input in.
# The getFlake default is only for direct `nix build --file` use; leaving it as
# an unconditional call made this file re-enter the flake from inside the
# flake's own outputs, on an unlocked store path, which forced --impure.
{ system ? builtins.currentSystem
# x86_64 and aarch64 are built as native siblings, so the build host matches the
# target by default. Defaulting to `system` rather than builtins.currentSystem
# keeps evaluation pure once a caller states the system explicitly.
, hostSystem ? system
, nixpkgsSource ? (builtins.getFlake (toString ../.)).inputs.nixpkgs
, hostPkgs ? import nixpkgsSource { system = hostSystem; }
}:

let
  toolchain = import ./manylinux-2-28-stdenv.nix {
    inherit system hostPkgs;
  };
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
