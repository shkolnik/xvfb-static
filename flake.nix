{
  description = "Reproducible, fully static Xvfb binaries for Linux";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { nixpkgs, ... }:
    let
      x86Host = import nixpkgs { system = "x86_64-linux"; };
      armHost = import nixpkgs { system = "aarch64-linux"; };
      mk = pkgs: pkgs.callPackage ./package.nix { };
      mkCorrupt = pkgs: pkgs.callPackage ./package.nix {
        corruptEmbeddedProfile = "de";
      };
      mkCheck = host: package: corruptPackage: host.callPackage ./integration-test.nix {
        xvfbStatic = package;
        corruptXvfb = corruptPackage;
      };
    in {
      packages.x86_64-linux = {
        default = mk x86Host.pkgsStatic;
        xvfb-static-x86_64 = mk x86Host.pkgsStatic;
        xvfb-static-glx-alpha-x86_64 = import ./package-glx.nix {
          system = "x86_64-linux";
        };
      };

      packages.aarch64-linux = {
        default = mk armHost.pkgsStatic;
        xvfb-static-aarch64 = mk armHost.pkgsStatic;
        xvfb-static-glx-alpha-aarch64 = import ./package-glx.nix {
          system = "aarch64-linux";
        };
      };
      checks.x86_64-linux.keyboard-profiles =
        mkCheck x86Host (mk x86Host.pkgsStatic) (mkCorrupt x86Host.pkgsStatic);
      checks.aarch64-linux.keyboard-profiles =
        mkCheck armHost (mk armHost.pkgsStatic) (mkCorrupt armHost.pkgsStatic);
    };
}
