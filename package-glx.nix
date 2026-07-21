let
  flake = builtins.getFlake "path:/src";
  pkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; };
  static = pkgs.pkgsStatic;
  mesaLLVMpipe = import /src/mesa-llvmpipe.nix;
  libxcvtStatic = static.libxcvt.overrideAttrs (old: {
    meta = old.meta // { badPlatforms = [ ]; };
    postPatch = (old.postPatch or "") + ''
      substituteInPlace lib/meson.build --replace-fail 'shared_library(' 'library('
    '';
  });
  prepareDependencies = dependencies:
    builtins.filter (dependency: (dependency.pname or "") != "libglvnd")
      (map (dependency:
        if (dependency.pname or "") == "libxcvt" then libxcvtStatic else dependency
      ) dependencies);
  keymapSource = builtins.toFile "xvfb-static-glx-keymap.xkb" ''
    xkb_keymap "default" {
      xkb_keycodes { include "evdev+aliases(qwerty)" };
      xkb_types { include "complete" };
      xkb_compatibility { include "complete" };
      xkb_symbols { include "pc+us+inet(evdev)" };
      xkb_geometry { include "pc(pc105)" };
    };
  '';
  keymapBlob = static.runCommand "xvfb-static-glx-keymap.xkm" {
    nativeBuildInputs = [ static.xkbcomp ];
  } ''
    xkbcomp -I${static.xkeyboard_config}/share/X11/xkb -xkm ${keymapSource} $out
    test -s $out
  '';
in
static.xvfb.overrideAttrs (old: {
  pname = "xvfb-static-glx-prototype";
  NIX_LDFLAGS = (old.NIX_LDFLAGS or "") + " -lstdc++";
  buildInputs = prepareDependencies (old.buildInputs or [ ]) ++ [
    mesaLLVMpipe
    static.ncurses
    static.stdenv.cc.cc.lib
  ];
  propagatedBuildInputs =
    prepareDependencies (old.propagatedBuildInputs or [ ]) ++ [ mesaLLVMpipe ];
  mesonFlags = (old.mesonFlags or [ ]) ++ [
    "-Dglx=true"
    "-Dc_link_args=-Wl,--allow-multiple-definition"
  ];
  patches = (old.patches or [ ]) ++ [
    /src/patches/xserver-0001-xkb-env-overrides.patch
    /src/patches/xserver-0002-embedded-keymap.patch
    /src/patches/xserver-0003-linked-swrast.patch
  ];
  postPatch = (old.postPatch or "") + ''
    {
      echo 'static const unsigned char xvfb_static_keymap_xkm[] = {'
      od -An -v -tu1 ${keymapBlob} | tr -s ' ' | sed 's/ /,/g; s/^,//; s/$/,/'
      echo '};'
    } > xkb/xvfb_static_keymap_blob.h
  '';
})
