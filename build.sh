#!/usr/bin/env bash
set -euo pipefail

arch="${1:-x86_64}"
case "$arch" in
  x86_64|aarch64) ;;
  *) echo "usage: ./build.sh [x86_64|aarch64]" >&2; exit 2 ;;
esac

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
image="nixos/nix@sha256:377d4887aca98f0dfa12971c1ea6d6a625a435d8b610d4c95a436843da6fbfd1"
uid="$(id -u)"
gid="$(id -g)"
mkdir -p "$root/out/$arch"

docker run --rm \
  -e NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1 \
  -e BUILD_UID="$uid" -e BUILD_GID="$gid" \
  -v "$root":/src -w /src \
  -v static-xvfb-nix:/nix \
  "$image" sh -c "
    set -eu
    git config --global --add safe.directory /src
    nix --extra-experimental-features 'nix-command flakes' \\
      build '.#static-xvfb-$arch' -o /src/out/$arch/result --print-build-logs --impure
    rm -rf /src/out/$arch/package
    mkdir -p /src/out/$arch/package
    cp -RL /src/out/$arch/result/. /src/out/$arch/package/
    cd /src/out/$arch/package
    LC_ALL=C tar --sort=name --owner=0 --group=0 --numeric-owner \\
      --mtime=@315532800 -czf /src/out/$arch/static-xvfb-linux-$arch.tar.gz bin share
    cd /src/out/$arch
    sha256sum static-xvfb-linux-$arch.tar.gz > SHA256SUMS
    chown -R \"\$BUILD_UID:\$BUILD_GID\" /src/out/$arch
  "

cat "$root/out/$arch/SHA256SUMS"
