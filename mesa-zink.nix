{ system ? builtins.currentSystem }:
let
  flake = builtins.getFlake "path:/src";
  pkgs = import flake.inputs.nixpkgs {
    inherit system;
    config.replaceStdenv = { pkgs }:
      pkgs.stdenvAdapters.makeStaticLibraries pkgs.stdenv;
    overlays = [
      (_final: previous: {
        # makeStaticLibraries does not mark the platform as isStatic, so
        # curl's default feature detection otherwise enables GSS/Kerberos.
        # Curl is build infrastructure here; the artifact neither links nor
        # needs its Kerberos integration.
        curlMinimal = previous.curlMinimal.override { gssSupport = false; };
        curl = previous.curl.override { gssSupport = false; };
        # CMake's bootstrap script rejects Autoconf's --disable-shared flag.
        cmakeMinimal = previous.cmakeMinimal.overrideAttrs (old: {
          dontAddStaticConfigureFlags = true;
          configureFlags = builtins.filter
            (flag: flag != "--enable-static" && flag != "--disable-shared")
            (old.configureFlags or [ ]);
        });
        libdrm = previous.libdrm.override {
          withIntel = false;
          withValgrind = false;
        };
        # libffi's checks add DejaGNU/Expect and a build-platform Tcl whose
        # shared-library assumptions are incompatible with this static stdenv.
        # The final Xvfb render/readback test exercises the incorporated FFI
        # path at the product boundary.
        libffi = previous.libffi.overrideAttrs (_old: {
          doCheck = false;
        });
        # SQLite is pulled in by the Python/Meson build toolchain, not linked
        # into Xvfb.  Its multi-minute upstream suite does not validate the
        # external-Vulkan artifact.
        sqlite = previous.sqlite.overrideAttrs (_old: {
          doCheck = false;
        });
        # The static build cannot dlopen libxml2's shared test module.  The
        # library and command-line tools still build normally; only that
        # shared-module-dependent check phase is incompatible with this
        # package set.
        libxml2 = previous.libxml2.overrideAttrs (_old: {
          doCheck = false;
        });
        tcl = previous.tcl.overrideAttrs (old: {
          preFixup = (old.preFixup or "") + ''
            if [ -f "$out/lib/libtcl8.6.a" ]; then
              ln -sfn libtcl8.6.a "$out/lib/libtcl.so"
            fi
          '';
        });
      })
    ];
  };
  disabled = pkgs.emptyDirectory;
  noLLVM = pkgs.llvmPackages // {
    llvm = disabled;
    libllvm = disabled;
    clang = disabled;
    clang-unwrapped = disabled;
    libclc = disabled;
  };
  mesa = pkgs.mesa.override {
    galliumDrivers = [ "zink" ];
    vulkanDrivers = [ ];
    vulkanLayers = [ ];
    eglPlatforms = [ "x11" ];
    enablePatentEncumberedCodecs = false;
    withValgrind = false;
    llvmPackages = noLLVM;
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
  patches = (old.patches or [ ]) ++ [
    ./patches/mesa-0002-linked-swrast-entrypoint.patch
    ./patches/mesa-0003-force-linked-zink.patch
  ];
  outputs = [ "out" ];
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
    "-Dllvm=disabled"
    "-Dshared-llvm=disabled"
    "-Dspirv-tools=disabled"
    "-Dshader-cache=disabled"
    "-Dzstd=disabled"
    "-Dvideo-codecs="
    "-Dtools="
    "-Dc_args=-DXVFB_STATIC_EXTERNAL_VULKAN=1"
  ];
  postInstall = ''
    gallium_archive="$(echo "$out"/lib/libgallium-*.so)"
    test -f "$gallium_archive"
    substituteInPlace "$out/lib/pkgconfig/gl.pc" \
      --replace-fail 'Libs.private: -lpthread' \
      "Libs.private: -lpthread $gallium_archive -lstdc++"
    substituteInPlace "$out/lib/pkgconfig/glx.pc" \
      --replace-fail '-lgallium-${mesa.version}' "$gallium_archive" \
      --replace-fail 'Libs.private: -lpthread' \
      'Libs.private: -lpthread -lstdc++'
  '';
  postFixup = "";
})
