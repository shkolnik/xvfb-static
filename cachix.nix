let
  flake = builtins.getFlake "path:/src";
  pkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; };
in
pkgs.cachix
