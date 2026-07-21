{
  description = "Reproducible, fully static Xvfb binaries for Linux";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

  outputs = { nixpkgs, ... }:
    let
      host = import nixpkgs { system = "x86_64-linux"; };
      mk = pkgs: pkgs.callPackage ./package.nix { };
    in {
      packages.x86_64-linux = {
        default = mk host.pkgsStatic;
        static-xvfb-x86_64 = mk host.pkgsStatic;
        static-xvfb-aarch64 = mk host.pkgsCross.aarch64-multiplatform.pkgsStatic;
      };
    };
}

