#!/usr/bin/env bash
set -euo pipefail

arch="${1:-}"
if [[ -z "$arch" ]]; then
  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) echo "unsupported host architecture: $(uname -m)" >&2; exit 2 ;;
  esac
fi
case "$arch" in
  x86_64|aarch64) ;;
  *) echo "usage: ./build.sh [x86_64|aarch64]" >&2; exit 2 ;;
esac

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
image="nixos/nix@sha256:22c0a3a816eb3d315eb6720d2a58a3c3b622c9717c578f3c80b687668c6da277"
uid="$(id -u)"
gid="$(id -g)"
mkdir -p "$root/out/$arch"

docker run --rm \
  -e NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1 \
  -e BUILD_UID="$uid" -e BUILD_GID="$gid" \
  -e CACHIX_CACHE_NAME -e CACHIX_AUTH_TOKEN -e CACHIX_SIGNING_KEY \
  -v "$root":/src -w /src \
  -v xvfb-static-nix:/nix \
  "$image" sh -c "
    set -eu
    git config --global --add safe.directory /src
    /src/nix-build-cached.sh \\
      nix --extra-experimental-features 'nix-command flakes' \\
      build '.#xvfb-static-$arch' -o /src/out/$arch/result --option log-lines 200 --impure
    rm -rf /src/out/$arch/package
    mkdir -p /src/out/$arch/package/bin /src/out/$arch/package/share/xvfb-static/licenses
    cp -L /src/out/$arch/result/bin/Xvfb /src/out/$arch/package/bin/
    cp -L /src/out/$arch/result/share/xvfb-static/manifest.json /src/out/$arch/package/share/xvfb-static/
    cp -L /src/out/$arch/result/share/xvfb-static/licenses/* /src/out/$arch/package/share/xvfb-static/licenses/
    cd /src/out/$arch/package
    LC_ALL=C tar --sort=name --owner=0 --group=0 --numeric-owner \\
      --mtime=@315532800 -czf /src/out/$arch/xvfb-static-linux-$arch.tar.gz bin share
    cd /src/out/$arch
    sha256sum xvfb-static-linux-$arch.tar.gz > SHA256SUMS
    chown -R \"\$BUILD_UID:\$BUILD_GID\" /src/out/$arch
  "

cat "$root/out/$arch/SHA256SUMS"
