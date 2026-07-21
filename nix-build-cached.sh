#!/bin/sh
set -eu

cache_name="${CACHIX_CACHE_NAME:-}"
if [ -z "$cache_name" ]; then
  exec "$@"
fi

cachix_path="$(
  nix --extra-experimental-features 'nix-command flakes' build \
    --impure --file /src/cachix.nix --no-link --print-out-paths
)"
cachix="$cachix_path/bin/cachix"

"$cachix" use "$cache_name"

auth_token="${CACHIX_AUTH_TOKEN:-}"
signing_key="${CACHIX_SIGNING_KEY:-}"
if { [ -n "$auth_token" ] && [ -z "$signing_key" ]; } || \
   { [ -z "$auth_token" ] && [ -n "$signing_key" ]; }; then
  echo "CACHIX_AUTH_TOKEN and CACHIX_SIGNING_KEY must be set together" >&2
  exit 2
fi

if [ -n "$auth_token" ]; then
  exec "$cachix" watch-exec "$cache_name" -- "$@"
fi

exec "$@"
