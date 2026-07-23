#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
nix_image="nixos/nix@sha256:377d4887aca98f0dfa12971c1ea6d6a625a435d8b610d4c95a436843da6fbfd1"
nix_volume="xvfb-static-manylinux-nix"
probe_output="${1:-}"

if [[ $# -gt 1 ]]; then
  echo "usage: ./test/manylinux-2-28-toolchain.sh [NIX_OUTPUT_PATH]" >&2
  exit 2
fi

case "$(uname -m)" in
  arm64|aarch64)
    platform="linux/arm64"
    system="aarch64-linux"
    expected_loader="ld-linux-aarch64.so.1"
    ;;
  x86_64|amd64)
    platform="linux/amd64"
    system="x86_64-linux"
    expected_loader="ld-linux-x86-64.so.2"
    ;;
  *)
    echo "unsupported host architecture: $(uname -m)" >&2
    exit 2
    ;;
esac

command -v docker >/dev/null || {
  echo "required command is unavailable: docker" >&2
  exit 1
}

audit_output=$(
  docker run --rm --platform "$platform" \
    -e NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1 \
    -e 'NIX_CONFIG=experimental-features = nix-command flakes' \
    -e PROBE_OUTPUT="$probe_output" \
    -e TASK_SYSTEM="$system" \
    -e EXPECTED_LOADER="$expected_loader" \
    -v "$repo_root":/src:ro \
    -v "$nix_volume":/nix \
    -w /src \
    "$nix_image" sh -eu -c '
      if test -z "$PROBE_OUTPUT"; then
        PROBE_OUTPUT=$(nix build \
          --impure --no-link --print-out-paths --cores 8 --option log-lines 200 \
          --file /src/test/manylinux-2-28-toolchain.nix \
          --argstr system "$TASK_SYSTEM")
      fi

      test -x "$PROBE_OUTPUT/bin/manylinux-2-28-probe-c"
      test -x "$PROBE_OUTPUT/bin/manylinux-2-28-probe-cxx"
      test -x "$PROBE_OUTPUT/bin/manylinux-2-28-probe-zlib"
      test -s "$PROBE_OUTPUT/nix-support/audit-path"
      test -s "$PROBE_OUTPUT/nix-support/zlib-link-command"
      grep -F -- '--sysroot=' "$PROBE_OUTPUT/nix-support/zlib-link-command" >/dev/null
      grep -F -- 'manylinux-2-28-libc-facade' \
        "$PROBE_OUTPUT/nix-support/zlib-link-command" >/dev/null
      PATH=$(cat "$PROBE_OUTPUT/nix-support/audit-path")
      export PATH

      maximum_glibc_version() {
        readelf --version-info -W "$1" |
          sed -n "s/.*Name: GLIBC_\([0-9][0-9.]*\).*/\1/p" |
          sort -Vu |
          tail -n 1
      }

      audit_executable() {
        binary=$1
        label=$2
        maximum=$(maximum_glibc_version "$binary")
        test -n "$maximum" || {
          echo "$label has no imported GLIBC symbol versions" >&2
          exit 1
        }
        if ! printf "%s\n%s\n" "$maximum" 2.28 | sort -V -C; then
          echo "$label imports GLIBC_$maximum, newer than GLIBC_2.28" >&2
          readelf --dyn-syms -W "$binary" |
            grep -E "@GLIBC_([2-9][9-9]|[3-9][0-9]|2\\.(29|[3-9][0-9]))" >&2 || true
          exit 1
        fi
        if readelf -dW "$binary" | grep -Eq "\\((RPATH|RUNPATH)\\)"; then
          echo "$label contains RPATH or RUNPATH" >&2
          exit 1
        fi
        interpreter=$(readelf -lW "$binary" |
          sed -n "s/.*Requesting program interpreter: \\([^]]*\\)].*/\\1/p")
        test "$interpreter" = "/lib/$EXPECTED_LOADER" -o \
          "$interpreter" = "/lib64/$EXPECTED_LOADER" || {
          echo "$label uses unexpected program interpreter: ${interpreter:-missing}" >&2
          exit 1
        }
        if strings "$binary" | grep -F /nix/store >/dev/null; then
          echo "$label contains a /nix/store reference" >&2
          strings "$binary" | grep -F /nix/store >&2
          exit 1
        fi
        readelf -dW "$binary" |
          sed -n "s/.*Shared library: \\[\([^]]*\)\\].*/\1/p" |
          while IFS= read -r library; do
            case "$library" in
              libc.so.6|libdl.so.2|libm.so.6|libpthread.so.0|librt.so.1|"$EXPECTED_LOADER") ;;
              *) echo "$label has unexpected dynamic dependency: $library" >&2; exit 1 ;;
            esac
          done
        printf "TASK3_MAX_%s=%s\n" "$label" "$maximum"
      }

      audit_executable "$PROBE_OUTPUT/bin/manylinux-2-28-probe-c" C
      audit_executable "$PROBE_OUTPUT/bin/manylinux-2-28-probe-cxx" CXX
      audit_executable "$PROBE_OUTPUT/bin/manylinux-2-28-probe-zlib" ZLIB
      printf "TASK3_OUTPUT_PATH=%s\n" "$PROBE_OUTPUT"
    '
)

printf '%s\n' "$audit_output"
probe_output=$(printf '%s\n' "$audit_output" |
  sed -n 's/^TASK3_OUTPUT_PATH=//p' | tail -n 1)
[[ "$probe_output" == /nix/store/* ]] || {
  echo "invalid Nix probe output path: ${probe_output:-missing}" >&2
  exit 1
}

run_probes() {
  image=$1
  distribution=$2
  docker run --rm --platform "$platform" \
    -v "$nix_volume":/nix:ro \
    "$image" "$probe_output/bin/manylinux-2-28-probe-c"
  echo "manylinux_2_28 C probe passed on $distribution"
  docker run --rm --platform "$platform" \
    -v "$nix_volume":/nix:ro \
    "$image" "$probe_output/bin/manylinux-2-28-probe-cxx"
  echo "manylinux_2_28 C++ probe passed on $distribution"
  docker run --rm --platform "$platform" \
    -v "$nix_volume":/nix:ro \
    "$image" "$probe_output/bin/manylinux-2-28-probe-zlib"
  echo "manylinux_2_28 zlib probe passed on $distribution"
}

run_probes debian:11-slim "Debian 11"
run_probes ubuntu:24.04 "Ubuntu 24.04"

echo "maximum imported glibc symbol: GLIBC_2.28 or older"
