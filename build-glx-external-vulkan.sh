#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$root/build-common.sh"

arch="$(xvfb_static_arch "${1:-}" "./build-glx-external-vulkan.sh")"
xvfb_static_build "$root" "$arch" \
  xvfb-static-glx-external-vulkan-alpha \
  "glx-external-vulkan-alpha/$arch" \
  xvfb-static-glx-external-vulkan-alpha
