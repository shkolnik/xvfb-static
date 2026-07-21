{ xorg, runCommand, xkeyboard_config, stdenv, gnutar, gzip, jq, pixman, zlib, libmd }:
let
  libxcvtStatic = xorg.libxcvt.overrideAttrs (old: {
    meta = old.meta // { badPlatforms = [ ]; };
    postPatch = (old.postPatch or "") + ''
      substituteInPlace lib/meson.build --replace-fail 'shared_library(' 'library('
    '';
  });
  keymapSource = builtins.toFile "static-xvfb-keymap.xkb" ''
    xkb_keymap "default" {
      xkb_keycodes { include "evdev+aliases(qwerty)" };
      xkb_types { include "complete" };
      xkb_compatibility { include "complete" };
      xkb_symbols { include "pc+us+inet(evdev)" };
      xkb_geometry { include "pc(pc105)" };
    };
  '';
  keymapBlob = runCommand "static-xvfb-keymap.xkm" {
    nativeBuildInputs = [ xorg.xkbcomp ];
  } ''
    xkbcomp -I${xkeyboard_config}/share/X11/xkb -xkm ${keymapSource} $out
    test -s $out
  '';
  xvfb = xorg.xvfb.overrideAttrs (old: {
    pname = "static-xvfb";
    buildInputs = (builtins.filter (d: (d.pname or "") != "libxcvt") old.buildInputs) ++ [ libxcvtStatic ];
    patches = (old.patches or [ ]) ++ [
      ./patches/xserver-0001-xkb-env-overrides.patch
      ./patches/xserver-0002-embedded-keymap.patch
    ];
    postPatch = (old.postPatch or "") + ''
      {
        echo 'static const unsigned char static_xvfb_keymap_xkm[] = {'
        od -An -v -tu1 ${keymapBlob} | tr -s ' ' | sed 's/ /,/g; s/^,//; s/$/,/'
        echo '};'
      } > xkb/static_xvfb_keymap_blob.h
    '';
  });
  nativeBuildInputs = [ gnutar gzip jq stdenv.cc.bintools ];
  strip = "${stdenv.cc.targetPrefix}strip";
in runCommand "static-xvfb-${xvfb.version}" { inherit nativeBuildInputs; } ''
  set -euo pipefail
  mkdir -p $out/bin $out/share/static-xvfb/licenses
  cp ${xvfb}/bin/Xvfb $out/bin/Xvfb
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
  L=$out/share/static-xvfb/licenses
  extract_license ${xorg.xorgserver.src} COPYING $L/xorg-server.COPYING
  extract_license ${xorg.xkbcomp.src} COPYING $L/xkbcomp.COPYING
  extract_license ${xkeyboard_config.src} COPYING $L/xkeyboard-config.COPYING
  extract_license ${xorg.libX11.src} COPYING $L/libX11.COPYING
  extract_license ${xorg.libXext.src} COPYING $L/libXext.COPYING
  extract_license ${xorg.libXfont2.src} COPYING $L/libXfont2.COPYING
  extract_license ${xorg.libxcvt.src} COPYING $L/libxcvt.COPYING
  extract_license ${pixman.src} COPYING $L/pixman.COPYING
  extract_license ${zlib.src} LICENSE $L/zlib.COPYING
  extract_license ${libmd.src} COPYING $L/libmd.COPYING
  files=$(cd $out && find . -type f | cut -c3- | { cat; echo share/static-xvfb/manifest.json; } | LC_ALL=C sort -u | jq -R -s 'split("\n") | map(select(length > 0))')
  jq -n --arg arch "${stdenv.hostPlatform.parsed.cpu.name}" --arg version "${xvfb.version}" --argjson files "$files" \
    '{name:"static-xvfb",schema_version:1,arch:$arch,components:{"xorg-server":$version},files:$files}' \
    > $out/share/static-xvfb/manifest.json
''
