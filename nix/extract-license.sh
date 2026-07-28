# Shared licence-text extractor, interpolated into every package derivation.
#
# Kept in one file because the hardened matcher below was originally written for
# the GLX derivations only: the standard package kept an older
# `tar -tf --wildcards "*/$rel"` form that matches at any depth, so the fix
# reached two of three copies. Extract exactly the pinned source's own text, or
# fail -- never guess between candidates.
extract_license() {
  src="$1"; rel="$2"; dest="$3"
  if [ -d "$src" ]; then
    test -s "$src/$rel"
    cp "$src/$rel" "$dest"
  else
    matches="$(tar -tf "$src" | while IFS= read -r member; do
      # Treat rel as relative to the source root. Release archives commonly
      # wrap that root in one directory, but nested files with the same
      # basename (notably GCC's several COPYING3 files) are not equivalent.
      case "$member" in
        "$rel") printf '%s\n' "$member" ;;
        */"$rel")
          prefix="${member%/"$rel"}"
          case "$prefix" in
            */*) ;;
            *) printf '%s\n' "$member" ;;
          esac
          ;;
      esac
    done)"
    match_count="$(printf '%s\n' "$matches" | awk 'NF { count++ } END { print count + 0 }')"
    if [ "$match_count" -ne 1 ]; then
      echo "xvfb-static: expected exactly one $rel in $src, found $match_count" >&2
      exit 1
    fi
    tar -xf "$src" -O "$matches" > "$dest"
    test -s "$dest"
  fi
}

# xorgproto ships one COPYING-<protocol> file per protocol instead of one
# aggregate license file, so a single extract_license call cannot represent
# it accurately. Copies every top-level file matching a shell glob, each
# renamed with destprefix prepended to its basename -- flat files, not a
# subdirectory, because the archive assembly step in build-common.sh installs
# licenses/* with a single flat `install -m`, which cannot descend into a
# directory. Fails if nothing matches.
extract_license_glob() {
  src="$1"; pattern="$2"; destprefix="$3"
  found=0
  if [ -d "$src" ]; then
    for f in "$src"/$pattern; do
      [ -e "$f" ] || continue
      cp "$f" "${destprefix}$(basename "$f")"
      found=$((found + 1))
    done
  else
    while IFS= read -r member; do
      [ -n "$member" ] || continue
      tar -xf "$src" -O "$member" > "${destprefix}${member##*/}"
      found=$((found + 1))
    done < <(tar -tf "$src" | while IFS= read -r m; do
      base="${m##*/}"; prefix="${m%/*}"
      case "$prefix" in */*) continue ;; esac
      case "$base" in $pattern) printf '%s\n' "$m" ;; esac
    done)
  fi
  if [ "$found" -eq 0 ]; then
    echo "xvfb-static: expected at least one match for $pattern in $src, found none" >&2
    exit 1
  fi
}
