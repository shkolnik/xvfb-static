{ system ? builtins.currentSystem
, pkgs ? import (builtins.getFlake (toString ./.)).inputs.nixpkgs { inherit system; }
}:
pkgs.cachix
