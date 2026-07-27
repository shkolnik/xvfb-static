# The one patched-umoci derivation: applies the rootless privileged-mode-bit
# mask and proves it with umoci's own upstream unpack-mode test. Shared by the
# manylinux sysroot unpacker and the fixture that exercises the patch in
# isolation -- the two previously carried verbatim copies of this derivation.
{ hostPkgs }:
hostPkgs.umoci.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [
    ../patches/umoci-0001-rootless-mask-privileged-mode-bits.patch
  ];
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    go test ./oci/layer -run '^TestModeForUnpack$'
    runHook postCheck
  '';
})
