#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archive="${1:-}"
render_test="${2:-$root/result-glx-render-test/bin/glx-render-test}"
if [[ -z "$archive" ]]; then
  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) echo "unsupported host architecture: $(uname -m)" >&2; exit 2 ;;
  esac
  archive="$root/out/glx-llvmpipe-alpha/$arch/xvfb-static-glx-llvmpipe-alpha-linux-$arch.tar.gz"
fi

test -s "$archive" || { echo "missing archive: $archive" >&2; exit 1; }
test -x "$render_test" || { echo "missing render test: $render_test" >&2; exit 1; }

tmp="$(mktemp -d /tmp/xvfb-static-glx-smoke.XXXXXX)"
name="xvfb-static-glx-smoke-$$"
cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  chmod -R u+w "$tmp" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

tar -xzf "$archive" -C "$tmp"
cp -L "$render_test" "$tmp/glx-render-test"
jq -e '.variant == "glx" and .maturity == "alpha" and .renderer == "llvmpipe"' \
  "$tmp/share/xvfb-static/manifest.json" >/dev/null

docker run --name "$name" --rm \
  -e GALLIUM_DRIVER=llvmpipe \
  -v "$tmp":/package:ro \
  alpine:3.22 sh -eu -c '
    /package/bin/Xvfb :99 +iglx -screen 0 64x64x24 >/tmp/xvfb.log 2>&1 &
    pid=$!
    trap "kill $pid 2>/dev/null || true" EXIT
    sleep 1
    DISPLAY=:99 /package/glx-render-test
    test ! -s /tmp/xvfb.log
    kill "$pid"
    wait "$pid" || true
    trap - EXIT
  '

echo "xvfb-static GLX llvmpipe alpha render smoke test passed"
