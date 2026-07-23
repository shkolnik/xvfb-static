{ system ? builtins.currentSystem
, hostPkgs ?
    let
      flake = builtins.getFlake (toString ../.);
    in
    import flake.inputs.nixpkgs { inherit system; }
}:

let
  patchedUmoci = hostPkgs.umoci.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      ../patches/umoci-0001-rootless-mask-privileged-mode-bits.patch
    ];
    doCheck = true;
    checkPhase = ''
      runHook preCheck
      go test ./oci/layer -run '^TestModeForUnpack$'
      runHook postCheck
    '';
  });
in
hostPkgs.runCommand "manylinux-2-28-umoci-fixture" {
  nativeBuildInputs = [
    hostPkgs.coreutils
    hostPkgs.gnutar
    patchedUmoci
  ];
} ''
  mkdir -p lower/bin lower/plain lower/opaque upper/plain upper/opaque

  printf ordinary > lower/bin/ordinary
  printf setuid > lower/bin/setuid
  printf setgid > lower/bin/setgid
  ln -s ordinary lower/bin/relative-link
  printf remove > lower/plain/remove-me
  printf old-a > lower/opaque/old-a
  printf old-b > lower/opaque/old-b

  : > upper/plain/.wh.remove-me
  : > upper/opaque/.wh..wh..opq
  printf new > upper/opaque/new

  tar_flags=(
    --format=gnu
    --mtime=@1
    --owner=0
    --group=0
    --numeric-owner
    --no-recursion
  )

  tar -cf lower.tar --files-from /dev/null
  tar -rf lower.tar "''${tar_flags[@]}" --mode=0755 \
    -C lower ./bin ./plain ./opaque
  tar -rf lower.tar "''${tar_flags[@]}" --mode=0755 \
    -C lower ./bin/ordinary
  tar -rf lower.tar "''${tar_flags[@]}" --mode=04755 \
    -C lower ./bin/setuid
  tar -rf lower.tar "''${tar_flags[@]}" --mode=02755 \
    -C lower ./bin/setgid
  tar -rf lower.tar "''${tar_flags[@]}" \
    -C lower ./bin/relative-link
  tar -rf lower.tar "''${tar_flags[@]}" --mode=0644 \
    -C lower ./plain/remove-me ./opaque/old-a ./opaque/old-b

  tar -cf upper.tar --files-from /dev/null
  tar -rf upper.tar "''${tar_flags[@]}" --mode=0755 \
    -C upper ./plain ./opaque
  tar -rf upper.tar "''${tar_flags[@]}" --mode=0644 \
    -C upper ./plain/.wh.remove-me ./opaque/.wh..wh..opq ./opaque/new

  umoci init --layout image
  umoci new --image image:fixture
  umoci raw add-layer --no-history --image image:fixture lower.tar
  umoci raw add-layer --no-history --image image:fixture upper.tar
  umoci unpack --rootless --image image:fixture unpacked

  test "$(stat -c %a unpacked/rootfs/bin/ordinary)" = 755
  test "$(stat -c %a unpacked/rootfs/bin/setuid)" = 755
  test "$(stat -c %a unpacked/rootfs/bin/setgid)" = 755
  test "$(readlink unpacked/rootfs/bin/relative-link)" = ordinary
  test ! -e unpacked/rootfs/plain/remove-me
  test ! -e unpacked/rootfs/opaque/old-a
  test ! -e unpacked/rootfs/opaque/old-b
  test "$(cat unpacked/rootfs/opaque/new)" = new

  mkdir -p "$out"
  printf '%s\n' 'rootless umoci fixture passed' > "$out/result"
''
