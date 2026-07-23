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
case "$arch" in x86_64|aarch64) ;; *) echo "usage: $0 [x86_64|aarch64]" >&2; exit 2 ;; esac

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="nixos/nix@sha256:22c0a3a816eb3d315eb6720d2a58a3c3b622c9717c578f3c80b687668c6da277"
docker run --rm \
  -e NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1 \
  -e CACHIX_CACHE_NAME -e CACHIX_AUTH_TOKEN -e CACHIX_SIGNING_KEY \
  -v "$root":/src -w /src -v xvfb-static-nix:/nix \
  "$image" sh -eu -c "
    git config --global --add safe.directory /src
    bash /src/nix-build-cached.sh nix --extra-experimental-features 'nix-command flakes' \
      build '.#checks.$(case "$arch" in x86_64) echo x86_64-linux ;; aarch64) echo aarch64-linux ;; esac).keyboard-profiles' \
      --no-link --option log-lines 200 --impure
  "

echo "xvfb-static keyboard integration test passed ($arch)"
