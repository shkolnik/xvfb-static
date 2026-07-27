# pkgs is supplied by flake.nix. The default exists only so this file can also
# be built directly with `nix build --file`, and is never forced when the flake
# passes a package set in -- which is what keeps the flake from re-entering
# itself through getFlake.
{ system ? builtins.currentSystem
, pkgs ? import (builtins.getFlake (toString ./.)).inputs.nixpkgs { inherit system; }
}:
let
  mesaCommon = import ./nix/mesa-common.nix;
  static = pkgs.pkgsStatic;
  disabled = static.emptyDirectory;
  targetLLVM = static.llvmPackages.llvm.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./patches/llvm-0001-allow-static-execution-engine.patch ];
    cmakeFlags = (old.cmakeFlags or [ ]) ++ [
      "-DLLVM_TARGETS_TO_BUILD=${if static.stdenv.hostPlatform.isAarch64 then "AArch64" else "X86"}"
    ];
  });
  minimalLLVM = static.llvmPackages // {
    llvm = targetLLVM;
    libllvm = targetLLVM;
    clang = disabled;
    clang-unwrapped = disabled;
    libclc = disabled;
  };
  mesa = static.mesa.override (mesaCommon.mkMesaOverrideArgs {
    galliumDrivers = [ "llvmpipe" ];
    llvmPackages = minimalLLVM;
    inherit disabled;
  });
in
mesa.overrideAttrs (old: {
  passthru = (old.passthru or { }) // { inherit targetLLVM; };
  patches = (old.patches or [ ]) ++ [
    ./patches/mesa-0001-check-jit-before-use.patch
    ./patches/mesa-0002-linked-swrast-entrypoint.patch
  ];
  outputs = [ "out" ];
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ targetLLVM.dev ];
  preConfigure = (old.preConfigure or "") + ''
    substituteInPlace src/gallium/targets/dri/meson.build \
      --replace-fail 'libgallium_dri = shared_library(' 'libgallium_dri = library('
  '' + mesaCommon.skipDrilSubdirPatch + ''
    substituteInPlace src/glx/meson.build \
      --replace-fail 'libgl = shared_library(' 'libgl = library('
  '';
  mesonFlags = (old.mesonFlags or [ ])
    ++ mesaCommon.mesonFlagsHead
    ++ [ "-Dllvm=enabled" ]
    ++ mesaCommon.mesonFlagsTail;
  postInstall = ''
    llvm_static_libs="$(${targetLLVM.dev}/bin/llvm-config --link-static --libs --system-libs | tr '\n' ' ')"
    gallium_archive="$(echo "$out"/lib/libgallium-*.so)"
    test -f "$gallium_archive"
    substituteInPlace "$out/lib/pkgconfig/gl.pc" \
      --replace-fail 'Libs.private: -lpthread' \
      "Libs.private: -lpthread $gallium_archive -L${targetLLVM.lib}/lib $llvm_static_libs -L${static.ncurses.out}/lib -ltinfo -lstdc++"
    substituteInPlace "$out/lib/pkgconfig/glx.pc" \
      --replace-fail '-lgallium-${mesa.version}' "$gallium_archive" \
      --replace-fail 'Libs.private: -lpthread' \
      "Libs.private: -lpthread -L${static.stdenv.cc.cc.lib}/lib -lstdc++"
  '';
  postFixup = "";
})
