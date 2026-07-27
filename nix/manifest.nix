# The one manifest-writing implementation shared by all three package
# derivations.
#
# Before this file existed, `schema_version` and `keyboard.default` were
# restated as literals in three places, and each GLX derivation wrote
# `variant`/`maturity`/`renderer` twice -- once as a hardcoded literal in its
# `passthru`, once again as the same hardcoded literal inside the embedded jq
# filter string -- with nothing checking the two copies still agreed. Callers
# now pass each GLX field once; this module threads that single value into
# both the returned `passthru` fragment and the jq invocation, so the two
# copies can no longer drift apart.
{ lib }:
let
  schemaVersion = 2;
  keyboardDefault = "us";

  # Renders the `files=...` capture and the final `jq -n` manifest-writing
  # command. Field order below is fixed and matches every manifest shipped to
  # date; changing it changes shipped bytes.
  #
  #   arch, version, revision, xorgVersion, profiles   -- required, all variants
  #   mesaVersion, llvmVersion                         -- optional components
  #   variant, maturity, renderer,
  #   graphicsBackend, runtimeModel                    -- GLX-only; pass all or none
  #   glibcSymbolFloorVar                              -- shell variable name already
  #                                                        holding the measured floor
  #   requiredGraphicsLibrary                          -- external-Vulkan only
  mkManifestScript =
    { arch, version, revision, xorgVersion, profiles
    , mesaVersion ? null
    , llvmVersion ? null
    , variant ? null
    , maturity ? null
    , renderer ? null
    , graphicsBackend ? null
    , runtimeModel ? null
    , glibcSymbolFloorVar ? null
    , requiredGraphicsLibrary ? null
    }:
    let
      hasGlxFields = variant != null;
      glxArgs = lib.optionalString hasGlxFields ''--arg variant "${variant}" --arg maturity "${maturity}" --arg renderer "${renderer}" --arg graphics_backend "${graphicsBackend}" --arg runtime_model "${runtimeModel}" '';
      glxFields = lib.optionalString hasGlxFields
        "variant:$variant,maturity:$maturity,renderer:$renderer,graphics_backend:$graphics_backend,runtime_model:$runtime_model,";

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
        ${glxArgs}${glibcArgs}${componentArgs}\
        '{name:"xvfb-static",version:$version,revision:$revision,schema_version:${toString schemaVersion},arch:$arch,${glxFields}${glibcFields}${requiredGraphicsLibraryFields}components:{"xorg-server":$xorg_version${componentFields}},keyboard:{default:"${keyboardDefault}",profiles:$keyboard_profiles},files:$files}' \
        > $out/share/xvfb-static/manifest.json
    '';
in
{
  inherit schemaVersion keyboardDefault mkManifestScript;
}
