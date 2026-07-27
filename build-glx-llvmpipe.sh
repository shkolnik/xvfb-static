#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$root/build-common.sh"

arch="$(xvfb_static_arch "${1:-}" "./build-glx-llvmpipe.sh")" || exit $?

xvfb_static_build "$root" "$arch" \
  xvfb-static-glx-llvmpipe-alpha \
  "glx-llvmpipe-alpha/$arch" \
  xvfb-static-glx-llvmpipe-alpha
