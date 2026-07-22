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
  archive="$root/out/glx-external-vulkan-alpha/$arch/xvfb-static-glx-external-vulkan-alpha-linux-$arch.tar.gz"
fi

for command in jq readelf strings tar; do
  command -v "$command" >/dev/null || {
    echo "required command is unavailable: $command" >&2
    exit 1
  }
done
test -s "$archive" || { echo "missing archive: $archive" >&2; exit 1; }

tmp="$(mktemp -d /tmp/xvfb-static-glx-external-vulkan.XXXXXX)"
name="xvfb-static-glx-external-vulkan-$$"
cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  chmod -R u+w "$tmp" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

tar -xzf "$archive" -C "$tmp"
manifest="$tmp/share/xvfb-static/manifest.json"
binary="$tmp/bin/Xvfb"

jq -e '
  .variant == "glx" and
  .maturity == "alpha" and
  .renderer == "zink" and
  .graphics_backend == "external-vulkan" and
  .runtime_model == "host-assisted" and
  (.glibc_symbol_floor | type == "string") and
  ((has("minimum_host_glibc") | not) or (.minimum_host_glibc | type == "string")) and
  .required_graphics_library == "libvulkan.so.1" and
  (.components | has("mesa")) and
  (.components | has("llvm") | not)
' "$manifest" >/dev/null

manifest_arch="$(jq -r .arch "$manifest")"
case "$manifest_arch" in
  x86_64) expected_interpreter="/lib64/ld-linux-x86-64.so.2" ;;
  aarch64) expected_interpreter="/lib/ld-linux-aarch64.so.1" ;;
  *) echo "unsupported manifest architecture: $manifest_arch" >&2; exit 1 ;;
esac

actual_interpreter="$(readelf -lW "$binary" | sed -n 's/.*Requesting program interpreter: \([^]]*\).*/\1/p')"
[[ "$actual_interpreter" == "$expected_interpreter" ]] || {
  echo "unexpected ELF interpreter: ${actual_interpreter:-none} (expected $expected_interpreter)" >&2
  exit 1
}
if readelf -dW "$binary" | grep -Eq '\((RPATH|RUNPATH)\)'; then
  echo "external Vulkan Xvfb must not contain RPATH or RUNPATH" >&2
  exit 1
fi
forbidden_strings="$(strings "$binary" | grep -E '/nix/store|libLLVM|LLVM_[0-9]' || true)"
if [[ -n "$forbidden_strings" ]]; then
  echo "external Vulkan Xvfb contains forbidden Nix-store or LLVM references:" >&2
  printf '%s\n' "$forbidden_strings" >&2
  exit 1
fi

newest_glibc="$({
  readelf --version-info -W "$binary" |
    sed -n 's/.*Name: GLIBC_\([0-9][0-9.]*\).*/\1/p'
} | sort -Vu | tail -n 1)"
declared_glibc_floor="$(jq -r .glibc_symbol_floor "$manifest")"
if [[ -z "$newest_glibc" ]] || [[ "$declared_glibc_floor" != "$newest_glibc" ]]; then
  echo "manifest GLIBC symbol floor ${declared_glibc_floor:-unknown} does not match binary maximum ${newest_glibc:-unknown}" >&2
  exit 1
fi

minimum_host_glibc="$(jq -r 'if has("minimum_host_glibc") then .minimum_host_glibc else empty end' "$manifest")"
if [[ -n "$minimum_host_glibc" ]]; then
  if [[ "$(printf '%s\n' "$minimum_host_glibc" 2.31 | sort -V | tail -n 1)" != "2.31" ]]; then
    echo "minimum_host_glibc must not claim a version newer than 2.31" >&2
    exit 1
  fi
  if [[ "$(printf '%s\n' "$newest_glibc" "$minimum_host_glibc" | sort -V | tail -n 1)" != "$minimum_host_glibc" ]]; then
    echo "binary GLIBC symbol floor exceeds the declared minimum host glibc" >&2
    exit 1
  fi
fi

if [[ "${XVFB_STATIC_REQUIRE_GLIBC_231:-0}" == "1" ]]; then
  [[ "$minimum_host_glibc" == "2.31" ]] || {
    echo "release-floor mode requires minimum_host_glibc=2.31" >&2
    exit 1
  }
  if [[ "$(printf '%s\n' "$newest_glibc" 2.31 | sort -V | tail -n 1)" != "2.31" ]]; then
    echo "release-floor mode rejects GLIBC_$newest_glibc; maximum is GLIBC_2.31" >&2
    exit 1
  fi
fi

needed="$(readelf -dW "$binary" | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p')"
while IFS= read -r library; do
  [[ -z "$library" ]] && continue
  case "$library" in
    libc.so.6|libdl.so.2|libm.so.6|libpthread.so.0|librt.so.1|libvulkan.so.1|\
      ld-linux-aarch64.so.1|ld-linux-x86-64.so.2) ;;
    *) echo "unexpected dynamic dependency: $library" >&2; exit 1 ;;
  esac
done <<< "$needed"

if [[ "$(printf '%s\n' "$newest_glibc" 2.31 | sort -V | tail -n 1)" != "2.31" ]]; then
  echo "skipping Debian 11 runtime checks: prototype requires GLIBC_$newest_glibc (Debian 11 provides GLIBC_2.31)"
  echo "xvfb-static GLX external Vulkan alpha structural ABI checks passed"
  exit 0
fi

command -v docker >/dev/null || {
  echo "required command is unavailable: docker" >&2
  exit 1
}
test -x "$render_test" || { echo "missing render test: $render_test" >&2; exit 1; }
cp -L "$render_test" "$tmp/glx-render-test"

docker run --name "$name" --rm \
  -v "$tmp":/package:ro \
  debian:11-slim sh -eu -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update >/dev/null
    apt-get install -y --no-install-recommends libvulkan1 mesa-vulkan-drivers >/dev/null

    run_failure_case() {
      label=$1
      shift
      : >"/tmp/$label.xvfb.log"
      : >"/tmp/$label.client.log"
      env "$@" /package/bin/Xvfb :99 +iglx -screen 0 64x64x24 \
        >"/tmp/$label.xvfb.log" 2>&1 &
      pid=$!
      sleep 1
      if kill -0 "$pid" 2>/dev/null; then
        if DISPLAY=:99 XVFB_STATIC_EXPECT_RENDERER=zink \
          /package/glx-render-test >"/tmp/$label.client.log" 2>&1; then
          echo "$label unexpectedly rendered successfully" >&2
          kill "$pid" 2>/dev/null || true
          wait "$pid" 2>/dev/null || true
          return 1
        fi
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
      else
        wait "$pid" 2>/dev/null || true
      fi
      if ! cat "/tmp/$label.xvfb.log" "/tmp/$label.client.log" |
        grep -Eiq "vulkan|zink|libvulkan|glx.*(fail|error)|failed.*glx"; then
        echo "$label did not produce a clear Vulkan/GLX diagnostic" >&2
        cat "/tmp/$label.xvfb.log" "/tmp/$label.client.log" >&2
        return 1
      fi
    }

    loader_dir=$(dirname "$(ldconfig -p | sed -n "s/.*libvulkan.so.1 .* => //p" | head -n 1)")
    test -n "$loader_dir"
    mkdir /tmp/vulkan-loader
    for library in "$loader_dir"/libvulkan.so.1*; do
      mv "$library" /tmp/vulkan-loader/
    done
    run_failure_case missing-loader
    for library in /tmp/vulkan-loader/*; do
      mv "$library" "$loader_dir"/
    done
    ldconfig

    run_failure_case missing-icd VK_ICD_FILENAMES=/nonexistent/xvfb-static-vulkan-icd.json

    icd=$(find /usr/share/vulkan/icd.d -type f -name "lvp_icd*.json" -print -quit)
    test -n "$icd"
    VK_ICD_FILENAMES="$icd" \
      /package/bin/Xvfb :99 +iglx -screen 0 64x64x24 >/tmp/positive.xvfb.log 2>&1 &
    pid=$!
    trap "kill $pid 2>/dev/null || true" EXIT
    sleep 1
    DISPLAY=:99 \
      XVFB_STATIC_EXPECT_RENDERER=zink \
      /package/glx-render-test
    kill "$pid"
    wait "$pid" || true
    trap - EXIT
  '

echo "xvfb-static GLX external Vulkan alpha ABI and Zink render smoke test passed"
