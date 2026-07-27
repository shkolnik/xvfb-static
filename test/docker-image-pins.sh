#!/usr/bin/env bash
# Every Docker image this project runs must be named once, by digest.
#
# build-image.txt holds the build container and test/images.sh holds the test
# containers. Before those files existed the nixos/nix digest was restated in
# ten places under a rule that only required two of them to agree, and the two
# Alpine references had already drifted to different majors. Nothing detected
# either. This check does.
#
# It is deliberately keyed to the image repositories the project actually uses
# rather than trying to recognise image references generically: a generic
# name:tag pattern matches far too much YAML to be useful. Adding a new base
# image therefore means adding it here and to a pin file.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# Repositories whose images this project runs. A digest reference separates the
# repository from the digest with '@', so a ':' after the repository is a
# mutable tag by construction and an '@' is a reference of any kind.
repositories='nixos/nix|alpine|debian|ubuntu'
tagged="(^|[^A-Za-z0-9._/-])($repositories):[A-Za-z0-9._-]+"
reference="(^|[^A-Za-z0-9._/-])($repositories)@"
pinned="($repositories)@sha256:[0-9a-f]{64}"

# The files allowed to name an image. The manylinux lock pins its own images by
# digest in JSON and is checked by test/manylinux-2-28-lock.sh.
pin_files=(build-image.txt test/images.sh)
exempt='^(build-image\.txt|test/images\.sh|nix/manylinux-2-28-images\.json)$'

# grep exits 0 on a match, 1 on none, and 2 or more on error. Treating anything
# but 1 as success would let a broken invocation report a clean repository --
# the exact vacuous pass this project keeps finding elsewhere. The output is
# published through a variable rather than returned through a command
# substitution, because aborting from inside a substitution would only leave
# its subshell and the caller would read the abort as "no match".
grep_capture() {
  local status=0
  GREP_OUTPUT=""
  GREP_OUTPUT="$(grep "$@")" || status=$?
  if (( status > 1 )); then
    echo "grep failed with status $status: grep $*" >&2
    exit 1
  fi
  return "$status"
}

status=0

mapfile -t files < <(git ls-files | grep -Ev "$exempt")
test "${#files[@]}" -gt 0

if grep_capture -nE "$tagged" "${files[@]}"; then
  echo "images must be pinned by digest in build-image.txt or test/images.sh," \
       "not named by mutable tag:" >&2
  printf '%s\n' "$GREP_OUTPUT" >&2
  status=1
fi

# Once is the point. Copying the digest instead of the tag would still leave
# the drift this replaces: the nixos/nix digest was restated in ten places and
# all ten happened to agree, which is not the same as being kept in agreement.
if grep_capture -nE "$reference" "${files[@]}"; then
  echo "images must be named only in build-image.txt or test/images.sh," \
       "and read from there:" >&2
  printf '%s\n' "$GREP_OUTPUT" >&2
  status=1
fi

# The pin files themselves must carry digests, and may name a tag only in a
# comment recording which tag a digest was resolved from.
for file in "${pin_files[@]}"; do
  uncommented=""
  if grep_capture -nE "$tagged" "$file"; then
    uncommented="$(printf '%s\n' "$GREP_OUTPUT" | grep -vE '^[0-9]+:#' || true)"
  fi
  if [[ -n "$uncommented" ]]; then
    echo "$file names an image by tag outside a comment:" >&2
    printf '%s\n' "$uncommented" >&2
    status=1
  fi
  if ! grep_capture -qE "$pinned" "$file"; then
    echo "$file contains no digest-pinned image reference" >&2
    status=1
  fi
done

if (( status == 0 )); then
  echo "Docker image pin checks passed"
fi
exit "$status"
