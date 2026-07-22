{ system ? builtins.currentSystem
, hostPkgs ?
    let
      flake = builtins.getFlake (toString ../.);
    in
    import flake.inputs.nixpkgs { inherit system; }
}:

let
  lock = import ./manylinux-2-28-images.nix { inherit system; };
  outputs = [ "out" "dev" "static" ];
in
assert outputs == [ "out" "dev" "static" ];
assert lock.policy == "manylinux_2_28";
assert lock.glibcFloor == "2.28";
throw "sysroot not implemented"
