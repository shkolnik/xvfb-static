#!/usr/bin/env bash
# Fully static release-archive test: static linkage plus a clean Alpine boot.
#
# The variant-agnostic archive shape, manifest, and licence checks live in
# test/archive-checks.sh and are run first from here, so every variant can be
# checked even when it cannot take the static/Alpine parts below.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archive="${1:-}"
if [[ -z "$archive" ]]; then
  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) echo "unsupported host architecture: $(uname -m)" >&2; exit 2 ;;
  esac
  archive="$root/out/$arch/xvfb-static-linux-$arch.tar.gz"
fi

for command in tar file docker; do
  command -v "$command" >/dev/null || {
    echo "required command is unavailable: $command" >&2
    exit 1
  }
done
test -s "$archive" || { echo "missing archive: $archive" >&2; exit 1; }

"$root/test/archive-checks.sh" "$archive"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/xvfb-static-smoke.XXXXXX")"
name="xvfb-static-smoke-$$"
cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  chmod -R u+w "$tmp" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
tar -xzf "$archive" -C "$tmp"
file "$tmp/bin/Xvfb" | grep -q 'statically linked'
docker run --name "$name" --rm -v "$tmp":/package:ro alpine:3.20 sh -eu -c '
  boot() {
    display="$1"; shift
    /package/bin/Xvfb ":$display" "$@" -screen 0 1280x1024x24 -nolisten tcp -fp built-ins >"/tmp/xvfb-$display.log" 2>&1 &
    pid=$!
    sleep 2
    kill -0 "$pid"
    kill "$pid"
    wait "$pid" || true
  }
  boot 94
  test ! -s /tmp/xvfb-94.log
  boot 95 -keyboard ru
  grep -q "^\[xvfb-static:xserver\] selected keyboard profile: ru$" /tmp/xvfb-95.log
  boot 96 -keyboard us-intl
  grep -q "^\[xvfb-static:xserver\] selected keyboard profile: us-intl$" /tmp/xvfb-96.log
  if /package/bin/Xvfb :97 -keyboard unsupported >/tmp/invalid.log 2>&1; then
    echo "invalid keyboard profile unexpectedly booted" >&2
    exit 1
  fi
  grep -q "^\[xvfb-static:xserver\] unknown keyboard profile.*unsupported" /tmp/invalid.log
  if /package/bin/Xvfb :98 -keyboard >/tmp/missing.log 2>&1; then
    echo "missing keyboard profile unexpectedly booted" >&2
    exit 1
  fi
  grep -q "^\[xvfb-static:xserver\] -keyboard requires a profile" /tmp/missing.log
'
echo "xvfb-static smoke test passed"
