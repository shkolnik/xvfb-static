{ system ? builtins.currentSystem }:
let
  flake = builtins.getFlake "path:/src";
  pkgs = import flake.inputs.nixpkgs { inherit system; };
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
  mesa = static.mesa.override {
    galliumDrivers = [ "llvmpipe" ];
    vulkanDrivers = [ ];
    vulkanLayers = [ ];
    eglPlatforms = [ "x11" ];
    enablePatentEncumberedCodecs = false;
    withValgrind = false;
    llvmPackages = minimalLLVM;
    directx-headers = disabled;
    elfutils = disabled;
    glslang = disabled;
    spirv-tools = disabled;
    spirv-llvm-translator = disabled;
    libglvnd = disabled;
    libgbm = disabled;
    vulkan-loader = disabled;
    libva-minimal = disabled;
    libdisplay-info = disabled;
    lm_sensors = disabled;
    udev = disabled;
    wayland = disabled;
    wayland-protocols = disabled;
    wayland-scanner = disabled;
    rustc = disabled;
    rust-bindgen = disabled;
    rust-cbindgen = disabled;
  };
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
    substituteInPlace src/meson.build \
      --replace-fail "    subdir('gallium/targets/dril')" \
      "    message('Skipping unused dynamic dril loader')"
    substituteInPlace src/glx/meson.build \
      --replace-fail 'libgl = shared_library(' 'libgl = library('
  '';
  mesonFlags = (old.mesonFlags or [ ]) ++ [
    "-Dauto_features=disabled"
    "-Ddefault_library=static"
    "-Ddefault_both_libraries=static"
    "-Dplatforms=x11"
    "-Dglx=dri"
    "-Dglvnd=disabled"
    "-Degl=disabled"
    "-Dgbm=disabled"
    "-Dshared-glapi=enabled"
    "-Dgallium-rusticl=false"
    "-Dgallium-extra-hud=false"
    "-Dgallium-va=disabled"
    "-Dteflon=false"
    "-Dinstall-mesa-clc=false"
    "-Dinstall-precomp-compiler=false"
    "-Dllvm=enabled"
    "-Dvideo-codecs="
    "-Dtools="
  ];
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
