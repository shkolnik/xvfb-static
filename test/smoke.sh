#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archive="${1:-$root/out/x86_64/static-xvfb-linux-x86_64.tar.gz}"
test -s "$archive" || { echo "missing archive: $archive" >&2; exit 1; }
tmp="$(mktemp -d /tmp/static-xvfb-smoke.XXXXXX)"
name="static-xvfb-smoke-$$"
cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT
tar -xzf "$archive" -C "$tmp"
test -x "$tmp/bin/Xvfb"
test -s "$tmp/share/static-xvfb/manifest.json"
test -d "$tmp/share/static-xvfb/licenses"
test "$(find "$tmp/bin" -maxdepth 1 -type f | wc -l)" -eq 1
file "$tmp/bin/Xvfb" | grep -q 'statically linked'
docker run --name "$name" --rm -v "$tmp":/package:ro alpine:3.20 sh -eu -c '
  /package/bin/Xvfb :94 -screen 0 1280x1024x24 -nolisten tcp -fp built-ins >/tmp/xvfb.log 2>&1 &
  pid=$!
  sleep 2
  kill -0 "$pid"
  test ! -s /tmp/xvfb.log
  kill "$pid"
  wait "$pid" || true
'
echo "static-xvfb smoke test passed"
