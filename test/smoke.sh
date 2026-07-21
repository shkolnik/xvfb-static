#!/usr/bin/env bash
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
test -s "$archive" || { echo "missing archive: $archive" >&2; exit 1; }
tmp="$(mktemp -d /tmp/xvfb-static-smoke.XXXXXX)"
name="xvfb-static-smoke-$$"
cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  chmod -R u+w "$tmp" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
tar -xzf "$archive" -C "$tmp"
test -x "$tmp/bin/Xvfb"
test -s "$tmp/share/xvfb-static/manifest.json"
test -d "$tmp/share/xvfb-static/licenses"
test "$(find "$tmp/bin" -maxdepth 1 -type f | wc -l)" -eq 1
file "$tmp/bin/Xvfb" | grep -q 'statically linked'
test "$(find "$tmp" -type f \( -name xkbcomp -o -name '*.xkm' \) | wc -l)" -eq 0
test ! -d "$tmp/share/X11/xkb"
jq -e '.schema_version == 2 and .keyboard.default == "us" and
  (.keyboard.profiles | length) == 28 and
  ([.keyboard.profiles[].id] | index("us-intl")) != null and
  ([.keyboard.profiles[].id] | index("rs-latin")) != null' \
  "$tmp/share/xvfb-static/manifest.json" >/dev/null
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
  grep -q "selected keyboard profile: ru" /tmp/xvfb-95.log
  boot 96 -keyboard us-intl
  grep -q "selected keyboard profile: us-intl" /tmp/xvfb-96.log
  if /package/bin/Xvfb :97 -keyboard unsupported >/tmp/invalid.log 2>&1; then
    echo "invalid keyboard profile unexpectedly booted" >&2
    exit 1
  fi
  grep -q "unknown keyboard profile.*unsupported" /tmp/invalid.log
'
echo "xvfb-static smoke test passed"
