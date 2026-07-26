# The one implementation of the embedded keymap catalog.
#
# Three package derivations and one integration check previously carried their
# own copy of this logic. They agreed, but only because nobody had changed one
# of them yet.
#
# Consumers get two things:
#
#   blobs   a derivation containing <id>.xkm for every profile
#   header  a shell snippet that writes xkb/xvfb_static_keymap_blob.h,
#           to be appended to the Xvfb derivation's postPatch
#
{ lib, runCommand, xkbcomp, xkeyboard_config
, profiles ? import ../keyboard-profiles.nix
  # Each variant keeps the derivation name it already had, so extracting this
  # module leaves every store path and derivation hash untouched. They could be
  # unified -- the standard and llvmpipe blobs are byte-identical -- but that
  # would force a rebuild of both GLX variants to prove something this refactor
  # does not need to change.
, name ? "xvfb-static-keymaps"
  # Name of a profile whose embedded bytes should be corrupted, for fault
  # injection. The build must then fail to load that profile at runtime; see
  # flake.nix's checks.
, corruptEmbeddedProfile ? null
}:
let
  # A profile is a rules/model/layout/variant/options tuple, and AGENTS.md
  # section 3 requires that none of those fields be implicit. The generator
  # below emits an XKB source description, which means it has to turn the
  # tuple into a set of includes -- normally the job of the rules files that
  # xkbcomp consults at runtime, which this project deliberately does not ship.
  #
  # Rather than reimplement rules resolution, resolve through explicit tables
  # and fail on anything not in them. Every current profile is
  # evdev/pc105/no-options, so the tables have one entry each; the point is
  # that adding a profile with a different model can no longer silently
  # compile as pc105.
  #
  # This was a live bug: the three copies of the generator read `layout` and
  # `variant` and ignored `rules`, `model`, and `options` entirely.
  rulesTable = {
    evdev = {
      keycodes = "evdev+aliases(qwerty)";
      types = "complete";
      compatibility = "complete";
      symbolsSuffix = "inet(evdev)";
    };
  };

  modelTable = {
    pc105 = {
      symbolsPrefix = "pc";
      geometry = "pc(pc105)";
    };
  };

  known = table: field: profile:
    let value = profile.${field}; in
    if table ? ${value} then table.${value}
    else throw ''
      xvfb-static: keyboard profile '${profile.id}' declares ${field} = "${value}",
      which nix/keymap-catalog.nix has no include mapping for.
      Add an entry to its ${field}Table -- do not leave the field unread, or the
      profile will compile as something other than what it declares.
    '';

  resolve = profile:
    let
      rules = known rulesTable "rules" profile;
      model = known modelTable "model" profile;
      symbols = profile.layout
        + (if profile.variant == "" then "" else "(${profile.variant})");
    in
    assert lib.assertMsg (profile.options == "") ''
      xvfb-static: keyboard profile '${profile.id}' declares options =
      "${profile.options}". Translating XKB options into includes needs the
      rules engine this build deliberately omits, so options are not yet
      supported. Either drop the field or teach nix/keymap-catalog.nix to
      resolve it.
    '';
    profile // {
      inherit (rules) keycodes types compatibility;
      inherit (model) geometry;
      symbolInclude = "${model.symbolsPrefix}+${symbols}+${rules.symbolsSuffix}";
    };

  resolved = map resolve profiles;

  # C identifiers cannot contain the hyphen that profile ids like `rs-latin`
  # and `us-intl` use.
  symbol = id: builtins.replaceStrings [ "-" ] [ "_" ] id;

  # xkbcomp and its source data generate embedded bytes at build time; they are
  # not linked into the target and must use the normal native toolchain.
  blobs = runCommand name {
    nativeBuildInputs = [ xkbcomp ];
  } ''
    mkdir -p $out
    ${lib.concatMapStringsSep "\n" (profile: ''
      cat > ${profile.id}.xkb <<'EOF'
      xkb_keymap "${profile.id}" {
        xkb_keycodes { include "${profile.keycodes}" };
        xkb_types { include "${profile.types}" };
        xkb_compatibility { include "${profile.compatibility}" };
        xkb_symbols { include "${profile.symbolInclude}" };
        xkb_geometry { include "${profile.geometry}" };
      };
      EOF
      xkbcomp -I${xkeyboard_config}/share/X11/xkb -xkm ${profile.id}.xkb $out/${profile.id}.xkm
      test -s $out/${profile.id}.xkm
    '') resolved}
  '';

  header = ''
    header=xkb/xvfb_static_keymap_blob.h
    : > "$header"
    ${lib.concatMapStringsSep "\n" (profile: ''
      echo 'static const unsigned char xvfb_static_keymap_${symbol profile.id}[] = {' >> "$header"
      od -An -v -tu1 ${blobs}/${profile.id}.xkm | tr -s ' ' | sed 's/ /,/g; s/^,//; s/$/,/' >> "$header"
      echo '};' >> "$header"
    '') profiles}
    cat >> "$header" <<'EOF'
    struct xvfb_static_keymap_entry { const char *id; const unsigned char *data; size_t size; };
    static const struct xvfb_static_keymap_entry xvfb_static_keymaps[] = {
    EOF
    ${lib.concatMapStringsSep "\n" (profile: ''
      echo '{ "${profile.id}", xvfb_static_keymap_${symbol profile.id}, sizeof(xvfb_static_keymap_${symbol profile.id}) },' >> "$header"
    '') profiles}
    echo '};' >> "$header"
    ${lib.optionalString (corruptEmbeddedProfile != null) ''
      sed -i '/static const unsigned char xvfb_static_keymap_${symbol corruptEmbeddedProfile}/ { n; s/[0-9][0-9]*/0/; }' "$header"
    ''}
  '';
in
{
  inherit blobs header profiles;
  # The resolved tuples, for tests that regenerate the XKB sources and diff
  # them against what the build embedded.
  resolvedProfiles = resolved;
}
