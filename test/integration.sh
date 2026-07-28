#!/usr/bin/env bash
set -euo pipefail

arch="${1:-}"
if [[ -z "$arch" ]]; then
  case "$(uname -m)" in
    x86_64|amd64) arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) echo "unsupported host architecture: $(uname -m)" >&2; exit 2 ;;
  esac
fi
case "$arch" in x86_64|aarch64) ;; *) echo "usage: $0 [x86_64|aarch64] [check-name]" >&2; exit 2 ;; esac
check="${2:-no-glx-keyboard-profiles}"
case "$check" in
  no-glx-keyboard-profiles|glx-llvmpipe-keyboard-profiles) ;;
  *) echo "usage: $0 [x86_64|aarch64] [no-glx-keyboard-profiles|glx-llvmpipe-keyboard-profiles]" >&2; exit 2 ;;
esac

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Single source of truth for the pinned build container; see build-image.txt.
image="$(cat "$root/build-image.txt")"
docker run --rm \
  -e CACHIX_CACHE_NAME -e CACHIX_AUTH_TOKEN -e CACHIX_SIGNING_KEY \
  -v "$root":/src -w /src -v xvfb-static-nix:/nix \
  "$image" sh -eu -c "
    git config --global --add safe.directory /src
    bash /src/nix-build-cached.sh nix --extra-experimental-features 'nix-command flakes' \
      build '.#checks.$(case "$arch" in x86_64) echo x86_64-linux ;; aarch64) echo aarch64-linux ;; esac).$check' \
      --no-link --option log-lines 200
  "

echo "xvfb-static keyboard integration test passed ($arch, $check)"
