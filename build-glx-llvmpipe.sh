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
  *) echo "usage: ./build-glx-llvmpipe.sh [x86_64|aarch64]" >&2; exit 2 ;;
esac

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
image="nixos/nix@sha256:377d4887aca98f0dfa12971c1ea6d6a625a435d8b610d4c95a436843da6fbfd1"
uid="$(id -u)"
gid="$(id -g)"
output="$root/out/glx-llvmpipe-alpha/$arch"
mkdir -p "$output"

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
      build 'path:/src#xvfb-static-glx-llvmpipe-alpha-$arch' \\
      -o /src/out/glx-llvmpipe-alpha/$arch/result --option log-lines 200 --impure
    rm -rf /src/out/glx-llvmpipe-alpha/$arch/package
    mkdir -p \
      /src/out/glx-llvmpipe-alpha/$arch/package/bin \
      /src/out/glx-llvmpipe-alpha/$arch/package/share/xvfb-static/licenses
    install -m 0755 \
      /src/out/glx-llvmpipe-alpha/$arch/result/bin/Xvfb \
      /src/out/glx-llvmpipe-alpha/$arch/package/bin/Xvfb
    install -m 0644 \
      /src/out/glx-llvmpipe-alpha/$arch/result/share/xvfb-static/manifest.json \
      /src/out/glx-llvmpipe-alpha/$arch/package/share/xvfb-static/manifest.json
    install -m 0644 \
      /src/out/glx-llvmpipe-alpha/$arch/result/share/xvfb-static/licenses/* \
      /src/out/glx-llvmpipe-alpha/$arch/package/share/xvfb-static/licenses/
    cd /src/out/glx-llvmpipe-alpha/$arch/package
    LC_ALL=C tar --sort=name --owner=0 --group=0 --numeric-owner \\
      --mtime=@315532800 \\
      -czf /src/out/glx-llvmpipe-alpha/$arch/xvfb-static-glx-llvmpipe-alpha-linux-$arch.tar.gz \\
      bin share
    cd /src/out/glx-llvmpipe-alpha/$arch
    sha256sum xvfb-static-glx-llvmpipe-alpha-linux-$arch.tar.gz > SHA256SUMS
    chown -R \"\$BUILD_UID:\$BUILD_GID\" /src/out/glx-llvmpipe-alpha/$arch
  "

cat "$output/SHA256SUMS"
