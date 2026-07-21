{ runCommand, xkbcomp, xkeyboard_config, diffutils, xvfbStatic, corruptXvfb }:
let
  profiles = import ./keyboard-profiles.nix;
  profileIds = map (profile: profile.id) profiles;
  expectedSources = builtins.concatStringsSep "\n" (map (profile:
    let symbols = profile.layout + (if profile.variant == "" then "" else "(${profile.variant})");
    in ''
      cat > expected-${profile.id}.xkb <<'EOF'
      xkb_keymap "${profile.id}" {
        xkb_keycodes { include "evdev+aliases(qwerty)" };
        xkb_types { include "complete" };
        xkb_compatibility { include "complete" };
        xkb_symbols { include "pc+${symbols}+inet(evdev)" };
        xkb_geometry { include "pc(pc105)" };
      };
      EOF
    '') profiles);
in runCommand "xvfb-static-keyboard-profiles" {
  nativeBuildInputs = [ xkbcomp diffutils ];
} ''
  set -euo pipefail
  export HOME="$TMPDIR/home"
  mkdir -p "$HOME" "$TMPDIR/.X11-unix"
  export XVFB_STATIC_XKM_OUTPUT_DIR="$TMPDIR"
  ${expectedSources}

  normalize() { sed '1s/xkb_keymap ".*"/xkb_keymap "normalized"/' "$1" > "$2"; }
  display=120
  for profile in ${builtins.concatStringsSep " " profileIds}; do
    ${xvfbStatic}/bin/Xvfb :$display -keyboard "$profile" -nolisten tcp >server.log 2>&1 &
    pid=$!
    for attempt in $(seq 1 50); do
      ${xkbcomp}/bin/xkbcomp -xkb :$display actual.xkb 2>/dev/null && break
      sleep 0.1
    done
    kill -0 "$pid"
    grep -q "selected keyboard profile: $profile" server.log
    ${xkbcomp}/bin/xkbcomp -I${xkeyboard_config}/share/X11/xkb -xkm expected-$profile.xkb expected.xkm
    ${xkbcomp}/bin/xkbcomp -xkb expected.xkm expected.xkb
    normalize actual.xkb actual.normalized
    normalize expected.xkb expected.normalized
    diff -u expected.normalized actual.normalized
    kill "$pid"
    wait "$pid" || true
    display=$((display + 1))
  done

  ${xvfbStatic}/bin/Xvfb :198 -nolisten tcp >/dev/null 2>&1 & default_pid=$!
  ${xvfbStatic}/bin/Xvfb :199 -keyboard us -nolisten tcp >/dev/null 2>&1 & us_pid=$!
  for attempt in $(seq 1 50); do
    ${xkbcomp}/bin/xkbcomp -xkb :198 default.xkb 2>/dev/null &&
      ${xkbcomp}/bin/xkbcomp -xkb :199 explicit-us.xkb 2>/dev/null && break
    sleep 0.1
  done
  normalize default.xkb default.normalized
  normalize explicit-us.xkb explicit-us.normalized
  diff -u default.normalized explicit-us.normalized
  kill "$default_pid" "$us_pid"
  wait "$default_pid" || true
  wait "$us_pid" || true

  ! ${xvfbStatic}/bin/Xvfb :200 -keyboard >missing.log 2>&1
  grep -q -- '-keyboard requires a profile' missing.log
  grep -q 'us-intl.*rs-latin' missing.log
  ! ${xvfbStatic}/bin/Xvfb :201 -keyboard unknown >unknown.log 2>&1
  grep -q "unknown keyboard profile 'unknown'" unknown.log
  grep -q 'us-intl.*rs-latin' unknown.log
  ${xvfbStatic}/bin/Xvfb -help >help.log 2>&1 || true
  grep -q -- '-keyboard PROFILE' help.log
  grep -q 'default: us' help.log
  grep -q 'us-intl.*rs-latin' help.log
  ! ${corruptXvfb}/bin/Xvfb :202 -keyboard de >corrupt.log 2>&1
  grep -q "^\[xvfb-static:xkb\] embedded keyboard profile 'de' failed to load$" corrupt.log
  touch $out
''
