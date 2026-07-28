#!/usr/bin/env bash
# Source-tree checks that need no build: shell syntax, and consistency between
# the documentation and the files it describes.
#
# These are the claims that silently rot, because nothing else reads them: a
# profile count restated in prose, a repository-map row for a deleted file, a
# license list that drifted between variants. Everything checked here is
# derived from a single source of truth and compared, never restated.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

status=0
fail() {
  echo "repo check failed: $*" >&2
  status=1
}

# --- shell syntax --------------------------------------------------------

mapfile -t scripts < <(git ls-files '*.sh')
test "${#scripts[@]}" -gt 0 || { echo "no tracked shell scripts found" >&2; exit 1; }
# One invocation per file. `bash -n a.sh b.sh` parses only a.sh -- the remaining
# arguments become that script's positional parameters -- so it exits 0 on a
# broken b.sh. Both the CI job and release.sh passed the whole list at once and
# had therefore been checking exactly one script, whichever git ls-files
# happened to return first.
for script in "${scripts[@]}"; do
  bash -n "$script" || fail "$script does not parse"
done
printf 'parsed %d shell scripts\n' "${#scripts[@]}"

# --- keyboard profile catalog --------------------------------------------

# keyboard-profiles.nix is the single source. Anything that restates the count
# or the id list in prose has to agree with it.
mapfile -t profile_ids < <(
  sed -nE 's/^  \{ id = "([^"]+)".*/\1/p' keyboard-profiles.nix
)
profile_count="${#profile_ids[@]}"
test "$profile_count" -gt 0 || { echo "could not read keyboard-profiles.nix" >&2; exit 1; }
printf 'catalog declares %d keyboard profiles\n' "$profile_count"

readme_count="$(sed -nE 's/.*one of the ([0-9]+) embedded, precompiled profiles.*/\1/p' README.md)"
if [[ "$readme_count" != "$profile_count" ]]; then
  fail "README.md says $readme_count keyboard profiles; keyboard-profiles.nix declares $profile_count"
fi

# Both documents print the catalog as a plain-text block. Compare the set of
# ids they list against the source, ignoring layout of the block itself.
for document in README.md AGENTS.md; do
  listed="$(
    awk '/^```text$/ { capture = 1; buffer = ""; next }
         /^```$/ { if (capture && buffer ~ /(^| )us( |$)/) print buffer; capture = 0; next }
         capture { buffer = buffer " " $0 }' "$document" |
      tr ' ' '\n' | sed '/^$/d' | sort -u
  )"
  expected="$(printf '%s\n' "${profile_ids[@]}" | sort -u)"
  if [[ "$listed" != "$expected" ]]; then
    fail "$document lists a different profile set than keyboard-profiles.nix"
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$listed") >&2 || true
  fi
done

# --- repository map ------------------------------------------------------

# Every tracked file must appear in the AGENTS.md map, and the map must not
# name files that no longer exist. Directories and the map's own ignored-output
# row are exempt.
map_missing=""
while IFS= read -r file; do
  grep -qF "\`$file\`" AGENTS.md || map_missing+="  $file"$'\n'
done < <(git ls-files)
if [[ -n "$map_missing" ]]; then
  fail "tracked files absent from the AGENTS.md repository map:"
  printf '%s' "$map_missing" >&2
fi

while IFS= read -r referenced; do
  [[ -e "$referenced" ]] || fail "AGENTS.md names a path that does not exist: $referenced"
done < <(
  grep -oE '`(docs|test|nix|patches|scripts|\.github)/[A-Za-z0-9._/-]+`' AGENTS.md |
    tr -d '`' | sort -u
)

# --- flake attribute references ------------------------------------------

# A flake attribute named inside a shell string is invisible to every other
# gate: `bash -n` sees an ordinary string, and Nix never reads the file. A
# renamed output therefore leaves every stale reference parsing cleanly, and
# failing only when someone runs it -- which for release.sh means during a
# release.
#
# Definitions are collected permissively and references strictly. An attribute
# form this misses weakens the check; it cannot fail the build falsely.
#
# Write no literal flake selector below: this file is itself scanned, so an
# example in a comment would be read as a reference and reported.

architectures=(x86_64 aarch64)

# Any `name = ...` binding, plus the final component of a dotted path so
# `checks.<system>.<name> =` contributes `<name>`. Bindings that are not flake
# outputs land here too and are harmless.
mapfile -t flake_attrs < <(
  sed -nE 's/^[[:space:]]*([A-Za-z0-9_][A-Za-z0-9_.-]*)[[:space:]]*=[^=].*/\1/p' flake.nix |
    awk -F. '{ print; print $NF }' | sort -u
)
test "${#flake_attrs[@]}" -gt 0 || { echo "could not read attributes from flake.nix" >&2; exit 1; }

attribute_defined() {
  local needle="$1" candidate
  for candidate in "${flake_attrs[@]}"; do
    [[ "$candidate" == "$needle" ]] && return 0
  done
  return 1
}

checked_references=0
unresolvable_references=0
while IFS= read -r file; do
  while IFS= read -r reference; do
    # Collapse the architecture spellings used by the scripts and the workflow
    # matrix, then require the reference to resolve for every architecture.
    normalized="${reference//\$\{\{ matrix.arch \}\}/@ARCH@}"
    normalized="${normalized//\$\{arch\}/@ARCH@}"
    normalized="${normalized//\$arch/@ARCH@}"
    # Test for leftover variables before trimming, or a reference assembled by
    # a command substitution would lose its sigil and look literal.
    if [[ "$normalized" == *'$'* ]]; then
      # Assembled from shell variables this check cannot see through, as
      # build-common.sh does with its attribute prefix. Report, never drop.
      printf 'flake reference not statically resolvable: %s (%s)\n' "$reference" "$file"
      unresolvable_references=$((unresolvable_references + 1))
      continue
    fi
    case "$normalized" in
      # An output under a top-level set is named by its last component.
      checks.*|packages.*|devShells.*) normalized="${normalized##*.}" ;;
      # Anything else selects a package, and a trailing path selects a field
      # within it rather than a different output.
      *) normalized="${normalized%%.*}" ;;
    esac
    for architecture in "${architectures[@]}"; do
      candidate="${normalized//@ARCH@/$architecture}"
      attribute_defined "$candidate" ||
        fail "$file names flake attribute '$candidate', which flake.nix does not define"
    done
    checked_references=$((checked_references + 1))
  done < <(
    grep -oE '\.#[A-Za-z0-9_.$@{}-]+( matrix\.arch \}\})?' "$file" |
      sed 's/^\.#//' | sort -u
  )
done < <(git ls-files '*.sh' '*.yml' '*.md')
printf 'checked %d flake attribute references (%d not statically resolvable)\n' \
  "$checked_references" "$unresolvable_references"

# --- glibc floor ---------------------------------------------------------

# The floor belongs to the image lock. Documentation may explain it but must
# not contradict it.
floor="$(jq -er '.["x86_64-linux"].glibcFloor' nix/manylinux-2-28-images.json)"
mapfile -t documents < <(git ls-files '*.md')
for document in "${documents[@]}"; do
  if grep -qE 'glibc 2\.[0-9]+' "$document"; then
    while IFS= read -r mentioned; do
      if [[ "$mentioned" != "$floor" ]]; then
        fail "$document mentions glibc $mentioned; the lock declares $floor"
      fi
    done < <(grep -oE 'glibc 2\.[0-9]+' "$document" | sed 's/glibc //' | sort -u)
  fi
done

if (( status == 0 )); then
  echo "repository checks passed"
fi
exit "$status"
