{ system }:
let
  locks = builtins.fromJSON (builtins.readFile ./manylinux-2-28-images.json);
  lock = locks.${system} or (throw "manylinux_2_28: unsupported system ${system}");
  digestPattern = "^sha256:[0-9a-f]{64}$";
in
assert lock.policy == "manylinux_2_28";
assert lock.glibcFloor == "2.28";
assert builtins.match digestPattern lock.imageDigest != null;
assert builtins.match "sha256-[A-Za-z0-9+/]{43}=" lock.sha256 != null;
assert builtins.match ".*:latest" lock.imageName == null;
lock
