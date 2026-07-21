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
image="nixos/nix@sha256:377d4887aca98f0dfa12971c1ea6d6a625a435d8b610d4c95a436843da6fbfd1"
docker run --rm \
  -e NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1 \
  -e CACHIX_CACHE_NAME -e CACHIX_AUTH_TOKEN -e CACHIX_SIGNING_KEY \
  -v "$root":/src -w /src -v xvfb-static-nix:/nix \
  "$image" sh -eu -c "
    git config --global --add safe.directory /src
    /src/nix-build-cached.sh nix --extra-experimental-features 'nix-command flakes' \
      build '.#checks.$(case "$arch" in x86_64) echo x86_64-linux ;; aarch64) echo aarch64-linux ;; esac).keyboard-profiles' \
      --no-link --print-build-logs --impure
  "

echo "xvfb-static keyboard integration test passed ($arch)"
