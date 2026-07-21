{ xvfb, runCommand, xkeyboard_config, stdenv, gnutar, gzip, jq, pixman, zlib, libmd
, xkbcomp, libxcvt, xorg-server, libx11, libxext, libxfont_2
, corruptEmbeddedProfile ? null
}:
let
  profiles = import ./keyboard-profiles.nix;
  libxcvtStatic = libxcvt.overrideAttrs (old: {
    meta = old.meta // { badPlatforms = [ ]; };
    postPatch = (old.postPatch or "") + ''
      substituteInPlace lib/meson.build --replace-fail 'shared_library(' 'library('
    '';
  });
  prepareXvfbDependencies = dependencies:
    builtins.filter (dependency: (dependency.pname or "") != "libglvnd")
      (map (dependency:
        if (dependency.pname or "") == "libxcvt" then libxcvtStatic else dependency
      ) dependencies);
  profileInputs = map (profile: profile // {
    symbolInclude = profile.layout + (if profile.variant == "" then "" else "(${profile.variant})");
  }) profiles;
  keymapBlobs = runCommand "xvfb-static-keymaps" {
    nativeBuildInputs = [ xkbcomp ];
  } ''
    mkdir -p $out
    ${builtins.concatStringsSep "\n" (map (profile: ''
      cat > ${profile.id}.xkb <<'EOF'
      xkb_keymap "${profile.id}" {
        xkb_keycodes { include "evdev+aliases(qwerty)" };
        xkb_types { include "complete" };
        xkb_compatibility { include "complete" };
        xkb_symbols { include "pc+${profile.symbolInclude}+inet(evdev)" };
        xkb_geometry { include "pc(pc105)" };
      };
      EOF
      xkbcomp -I${xkeyboard_config}/share/X11/xkb -xkm ${profile.id}.xkb $out/${profile.id}.xkm
      test -s $out/${profile.id}.xkm
    '') profileInputs)}
  '';
  xvfbPatched = xvfb.overrideAttrs (old: {
    pname = "xvfb-static";
    buildInputs = prepareXvfbDependencies (old.buildInputs or [ ]);
    propagatedBuildInputs = prepareXvfbDependencies (old.propagatedBuildInputs or [ ]);
    mesonFlags = (old.mesonFlags or [ ]) ++ [ "-Dglx=false" ];
    patches = (old.patches or [ ]) ++ [
      ./patches/xserver-0001-xkb-env-overrides.patch
      ./patches/xserver-0002-embedded-keymap.patch
      ./patches/xserver-0003-keyboard-profile-option.patch
      ./patches/xserver-0004-component-log-prefixes.patch
    ];
    postPatch = (old.postPatch or "") + ''
      header=xkb/xvfb_static_keymap_blob.h
      : > "$header"
      ${builtins.concatStringsSep "\n" (map (profile: ''
        echo 'static const unsigned char xvfb_static_keymap_${builtins.replaceStrings ["-"] ["_"] profile.id}[] = {' >> "$header"
        od -An -v -tu1 ${keymapBlobs}/${profile.id}.xkm | tr -s ' ' | sed 's/ /,/g; s/^,//; s/$/,/' >> "$header"
        echo '};' >> "$header"
      '') profiles)}
      cat >> "$header" <<'EOF'
      struct xvfb_static_keymap_entry { const char *id; const unsigned char *data; size_t size; };
      static const struct xvfb_static_keymap_entry xvfb_static_keymaps[] = {
      EOF
      ${builtins.concatStringsSep "\n" (map (profile: ''
        echo '{ "${profile.id}", xvfb_static_keymap_${builtins.replaceStrings ["-"] ["_"] profile.id}, sizeof(xvfb_static_keymap_${builtins.replaceStrings ["-"] ["_"] profile.id}) },' >> "$header"
      '') profiles)}
      echo '};' >> "$header"
      ${if corruptEmbeddedProfile == null then "" else ''
        sed -i '/static const unsigned char xvfb_static_keymap_${builtins.replaceStrings ["-"] ["_"] corruptEmbeddedProfile}/ { n; s/[0-9][0-9]*/0/; }' "$header"
      ''}
    '';
  });
  releaseRevision = 2;
  releaseVersion = "${xvfbPatched.version}-r${toString releaseRevision}";
  nativeBuildInputs = [ gnutar gzip jq stdenv.cc.bintools ];
  strip = "${stdenv.cc.targetPrefix}strip";
in runCommand "xvfb-static-${releaseVersion}" {
  inherit nativeBuildInputs;
  passthru = {
    inherit releaseRevision releaseVersion;
    upstreamVersion = xvfbPatched.version;
  };
} ''
  set -euo pipefail
  mkdir -p $out/bin $out/share/xvfb-static/licenses
  cp ${xvfbPatched}/bin/Xvfb $out/bin/Xvfb
  chmod u+w $out/bin/Xvfb
  ${strip} --strip-all $out/bin/Xvfb
  extract_license() {
    src="$1"; rel="$2"; dest="$3"
    if [ -d "$src" ]; then
      test -s "$src/$rel"
      cp "$src/$rel" "$dest"
    else
      matches="$(tar -tf "$src" --wildcards "*/$rel")"
      test "$(printf '%s\n' "$matches" | grep -c .)" -eq 1
      tar -xf "$src" -O "$matches" > "$dest"
      test -s "$dest"
    fi
  }
  L=$out/share/xvfb-static/licenses
  extract_license ${xorg-server.src} COPYING $L/xorg-server.COPYING
  extract_license ${xkbcomp.src} COPYING $L/xkbcomp.COPYING
  extract_license ${xkeyboard_config.src} COPYING $L/xkeyboard-config.COPYING
  extract_license ${libx11.src} COPYING $L/libX11.COPYING
  extract_license ${libxext.src} COPYING $L/libXext.COPYING
  extract_license ${libxfont_2.src} COPYING $L/libXfont2.COPYING
  extract_license ${libxcvt.src} COPYING $L/libxcvt.COPYING
  extract_license ${pixman.src} COPYING $L/pixman.COPYING
  extract_license ${zlib.src} LICENSE $L/zlib.COPYING
  extract_license ${libmd.src} COPYING $L/libmd.COPYING
  files=$(cd $out && find . -type f | cut -c3- | { cat; echo share/xvfb-static/manifest.json; } | LC_ALL=C sort -u | jq -R -s 'split("\n") | map(select(length > 0))')
  jq -n --arg arch "${stdenv.hostPlatform.parsed.cpu.name}" \
    --arg version "${releaseVersion}" --argjson revision ${toString releaseRevision} \
    --arg xorg_version "${xvfbPatched.version}" --argjson files "$files" \
    --argjson keyboard_profiles '${builtins.toJSON profiles}' \
    '{name:"xvfb-static",version:$version,revision:$revision,schema_version:2,arch:$arch,components:{"xorg-server":$xorg_version},keyboard:{default:"us",profiles:$keyboard_profiles},files:$files}' \
    > $out/share/xvfb-static/manifest.json
''
