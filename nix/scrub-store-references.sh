# Shared store-reference scrub, interpolated into every derivation that
# packages or audits a binary this project ships.
#
# Static libraries compile build-time resource defaults into the final string
# table -- OpenSSL's module and certificate directories, libX11's locale and
# XErrorDB paths, the font path, Mesa's DRI search path, the XKB tree the
# embedded keymap replaced, and the X server's own protocol.txt location.
# Linker-supplied RPATH strings survive there too: patchelf --remove-rpath
# deletes the DT_RUNPATH entry but leaves its text in .dynstr.
#
# None of those paths can resolve on a target host, so scrubbing them costs
# nothing at runtime and buys two things:
#
#   1. The shipped bytes stop depending on the build closure's hashes. A
#      compiled-in store path carries a hash; an unrelated input change moves
#      that hash; the archive checksum then changes with no functional
#      difference. The server's own output path is the worst case, because it
#      makes the artifact's bytes a function of its own derivation hash.
#   2. The artifact stops advertising its build closure to anyone who runs
#      strings(1) on it.
#
# nuke-refs rewrites each store hash to a run of 'e', then the uniform dead
# prefix becomes an equally sized, explicitly unavailable runtime path. Equal
# size matters: rewriting in place moves no offset in the string table, so
# this is safe on a linked executable.
#
# Requires nuke-refs and perl on PATH.
scrub_store_references() {
  binary="$1"

  nuke-refs "$binary"
  perl -0pi -e \
    's{/nix/store/e{32}-}{/nonexistent/xvfb-static/store-reference-xxx}g' \
    "$binary"

  # Fail rather than ship a partially scrubbed binary. nuke-refs rewrites only
  # well-formed store paths, so anything still matching here is a form this
  # scrub does not understand, and silently shipping it would restore exactly
  # the hash dependency the scrub exists to remove.
  if grep -a -q /nix/store "$binary"; then
    echo "xvfb-static: $binary retains store references after scrubbing:" >&2
    grep -a -o '/nix/store[!-~]*' "$binary" | sort -u | head -n 20 >&2
    exit 1
  fi
}
