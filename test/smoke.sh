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
test -z "$(find "$tmp/share/xvfb-static/licenses" -type f -empty -print -quit)"
actual_files="$tmp/actual-files"
manifest_files="$tmp/manifest-files"
(cd "$tmp" && find bin share -type f | LC_ALL=C sort) > "$actual_files"
jq -er '.files[]' "$tmp/share/xvfb-static/manifest.json" | LC_ALL=C sort > "$manifest_files"
diff -u "$manifest_files" "$actual_files"
docker run --name "$name" --rm -v "$tmp":/package:ro alpine:3.20 sh -eu -c '
  /package/bin/Xvfb :94 -screen 0 1280x1024x24 -nolisten tcp -fp built-ins >/tmp/xvfb.log 2>&1 &
  pid=$!
  sleep 2
  kill -0 "$pid"
  test ! -s /tmp/xvfb.log
  kill "$pid"
  wait "$pid" || true
'
echo "xvfb-static smoke test passed"
