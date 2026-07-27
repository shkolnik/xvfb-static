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

# Cache setup is diagnostics, not output. Keeping it off stdout lets a caller
# capture the wrapped command's own output -- test/manylinux-2-28-toolchain.sh
# reads a store path back from `nix build --print-out-paths`.
"$cachix" use "$cache_name" >&2

# Prove the substituter took effect rather than assuming it did. A cache that
# is configured but not consulted is indistinguishable from a cold cache: the
# build still succeeds, just slowly, every time. That is exactly how the
# manylinux toolchain went on rebuilding GCC from source unnoticed.
substituters="$(
  nix --extra-experimental-features 'nix-command flakes' config show substituters
)"
if ! printf '%s\n' "$substituters" | grep -qF "$cache_name.cachix.org"; then
  echo "cachix use did not add $cache_name.cachix.org as a substituter" >&2
  echo "substituters: $substituters" >&2
  exit 1
fi

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
