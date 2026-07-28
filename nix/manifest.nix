# The one manifest-writing implementation shared by all three package
# derivations.
#
# Each caller passes a field once and this module threads that single value
# into both the returned `passthru` fragment and the jq invocation. Do not
# reintroduce a literal in either place: the manifest and the `passthru` would
# then be free to disagree, and nothing checks them against each other.
{ lib }:
let
  # Bump when a change would make a manifest that is still published either
  # unreadable or misread by a consumer written against this schema. Adding a
  # field does not qualify on its own, and neither does changing one whose
  # every published carrier has been withdrawn.
  schemaVersion = 2;
  keyboardDefault = "us";

  # Renders the `files=...` capture and the final `jq -n` manifest-writing
  # command. Field order below is fixed and matches every manifest shipped to
  # date; changing it changes shipped bytes.
  #
  #   arch, version, revision, xorgVersion, profiles   -- required, all variants
  #   variant, maturity                                -- required, all variants
  #   mesaVersion, llvmVersion                         -- optional components
  #   renderer, graphicsBackend, runtimeModel          -- GLX-only; pass all or none
  #   glibcSymbolFloorVar                              -- shell variable name already
  #                                                        holding the measured floor
  #   requiredGraphicsLibrary                          -- external-Vulkan only
  #
  # `variant` and `maturity` have no defaults, so a new variant cannot ship a
  # manifest that silently omits either one.
  mkManifestScript =
    { arch, version, revision, xorgVersion, profiles
    , variant
    , maturity
    , mesaVersion ? null
    , llvmVersion ? null
    , renderer ? null
    , graphicsBackend ? null
    , runtimeModel ? null
    , glibcSymbolFloorVar ? null
    , requiredGraphicsLibrary ? null
    }:
    let
      variantArgs = ''--arg variant "${variant}" --arg maturity "${maturity}" '';
      variantFields = "variant:$variant,maturity:$maturity,";

      hasGlxFields = renderer != null;
      glxArgs = lib.optionalString hasGlxFields ''--arg renderer "${renderer}" --arg graphics_backend "${graphicsBackend}" --arg runtime_model "${runtimeModel}" '';
      glxFields = lib.optionalString hasGlxFields
        "renderer:$renderer,graphics_backend:$graphics_backend,runtime_model:$runtime_model,";

      # `${"$" + glibcSymbolFloorVar}` -- not `$${glibcSymbolFloorVar}` -- because
      # in an indented string, a literal "$" immediately followed by "${" is
      # itself an escape sequence for a literal "${", not a literal "$" plus a
      # fresh interpolation. Concatenating the "$" onto the Nix value first and
      # interpolating the whole result sidesteps that escape entirely.
      glibcArgs = lib.optionalString (glibcSymbolFloorVar != null) ''--arg glibc_symbol_floor "${"$" + glibcSymbolFloorVar}" '';
      glibcFields = lib.optionalString (glibcSymbolFloorVar != null)
        "glibc_symbol_floor:$glibc_symbol_floor,";

      requiredGraphicsLibraryFields = lib.optionalString (requiredGraphicsLibrary != null)
        "required_graphics_library:${builtins.toJSON requiredGraphicsLibrary},";

      componentArgs = lib.optionalString (mesaVersion != null) ''--arg mesa_version "${mesaVersion}" ''
        + lib.optionalString (llvmVersion != null) ''--arg llvm_version "${llvmVersion}" '';
      componentFields = lib.optionalString (mesaVersion != null) ",mesa:$mesa_version"
        + lib.optionalString (llvmVersion != null) ",llvm:$llvm_version";
    in ''
      files=$(cd $out && find . -type f | cut -c3- | { cat; echo share/xvfb-static/manifest.json; } | LC_ALL=C sort -u | jq -R -s 'split("\n") | map(select(length > 0))')
      jq -n --arg arch "${arch}" --arg version "${version}" --argjson revision ${toString revision} \
        --arg xorg_version "${xorgVersion}" --argjson files "$files" \
        --argjson keyboard_profiles '${builtins.toJSON profiles}' \
        ${variantArgs}${glxArgs}${glibcArgs}${componentArgs}\
        '{name:"xvfb-static",version:$version,revision:$revision,schema_version:${toString schemaVersion},arch:$arch,${variantFields}${glxFields}${glibcFields}${requiredGraphicsLibraryFields}components:{"xorg-server":$xorg_version${componentFields}},keyboard:{default:"${keyboardDefault}",profiles:$keyboard_profiles},files:$files}' \
        > $out/share/xvfb-static/manifest.json
    '';
in
{
  inherit schemaVersion keyboardDefault mkManifestScript;
}
