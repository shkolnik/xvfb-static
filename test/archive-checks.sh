#!/usr/bin/env bash
# Variant-agnostic release-archive checks.
#
# Every published archive must satisfy these, including the host-assisted
# external Vulkan variant that cannot take the fully static Alpine boot test.
# Keep anything that assumes static linkage or a bootable Alpine container in
# test/smoke.sh instead; this script must stay safe for all variants.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archive="${1:-}"
if [[ -z "$archive" ]]; then
  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) echo "unsupported host architecture: $(uname -m)" >&2; exit 2 ;;
  esac
  archive="$root/out/no-glx/$arch/xvfb-static-no-glx-linux-$arch.tar.gz"
fi

for command in jq tar find diff; do
  command -v "$command" >/dev/null || {
    echo "required command is unavailable: $command" >&2
    exit 1
  }
done
test -s "$archive" || { echo "missing archive: $archive" >&2; exit 1; }

# The curated catalog in keyboard-profiles.nix is the single source of truth for
# the profile count. Deriving it here keeps the assertion from silently
# disagreeing with the catalog when a profile is added or removed.
profiles="$root/keyboard-profiles.nix"
test -s "$profiles" || { echo "missing profile catalog: $profiles" >&2; exit 1; }
expected_profiles="$(grep -c '^  { id = ' "$profiles")"
test "$expected_profiles" -gt 0 || {
  echo "could not derive profile count from $profiles" >&2
  exit 1
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/xvfb-static-archive-checks.XXXXXX")"
cleanup() {
  chmod -R u+w "$tmp" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$tmp"

# Archive shape: exactly one executable, plus metadata and licence texts.
test -x "$tmp/bin/Xvfb"
test -s "$tmp/share/xvfb-static/manifest.json"
test -d "$tmp/share/xvfb-static/licenses"
test "$(find "$tmp/bin" -maxdepth 1 -type f | wc -l)" -eq 1
test -z "$(find "$tmp/share/xvfb-static/licenses" -type f -empty -print -quit)"

# The manifest must list every packaged file and nothing else.
actual_files="$tmp/actual-files"
manifest_files="$tmp/manifest-files"
(cd "$tmp" && find bin share -type f | LC_ALL=C sort) > "$actual_files"
jq -er '.files[]' "$tmp/share/xvfb-static/manifest.json" | LC_ALL=C sort > "$manifest_files"
diff -u "$manifest_files" "$actual_files"

# No packaged file may name a Nix store path. The build scrubs the binary (see
# nix/scrub-store-references.sh); checking the extracted archive instead of
# trusting the derivation keeps the guarantee attached to the bytes users
# download, and applies it to the manifest and licence texts too. A store path
# here would mean the artifact both advertises its build closure and carries a
# hash that changes its checksum whenever an unrelated input moves.
store_references="$(grep -alr /nix/store "$tmp" || true)"
if [[ -n "$store_references" ]]; then
  echo "packaged files retain Nix store references:" >&2
  printf '%s\n' "$store_references" >&2
  exit 1
fi

# The single-file runtime promise: no keymap compiler, no XKB tree, no loose XKM.
test "$(find "$tmp" -type f \( -name xkbcomp -o -name '*.xkm' \) | wc -l)" -eq 0
test ! -d "$tmp/share/X11/xkb"

# Every artifact declares both discriminators, so a variant that forgets one
# fails here rather than shipping a manifest a consumer cannot classify. The
# per-variant values are pinned by each variant's own smoke test.
jq -e --argjson expected "$expected_profiles" \
  '.schema_version == 3 and .keyboard.default == "us" and
   (.variant as $v | ["no-glx", "glx"] | index($v)) != null and
   (.maturity as $m | ["stable", "alpha"] | index($m)) != null and
   (.keyboard.profiles | length) == $expected and
   ([.keyboard.profiles[].id] | index("us-intl")) != null and
   ([.keyboard.profiles[].id] | index("rs-latin")) != null' \
  "$tmp/share/xvfb-static/manifest.json" >/dev/null

echo "xvfb-static archive checks passed ($expected_profiles keyboard profiles)"
