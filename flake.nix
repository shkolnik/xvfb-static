{
  description = "Reproducible, fully static Xvfb binaries for Linux";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { nixpkgs, ... }:
    let
      x86Host = import nixpkgs { system = "x86_64-linux"; };
      armHost = import nixpkgs { system = "aarch64-linux"; };
      mk = pkgs: pkgs.callPackage ./package.nix { };
    in {
      packages.x86_64-linux = {
        default = mk x86Host.pkgsStatic;
        static-xvfb-x86_64 = mk x86Host.pkgsStatic;
      };

      packages.aarch64-linux = {
        default = mk armHost.pkgsStatic;
        static-xvfb-aarch64 = mk armHost.pkgsStatic;
      };
    };
}
