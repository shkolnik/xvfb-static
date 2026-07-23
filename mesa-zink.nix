{ system ? builtins.currentSystem
, targetPkgs ? null
, hostPkgs ? null
}:
let
  providedTargetPkgs = targetPkgs;
  providedHostPkgs = hostPkgs;
  packageSets =
    if providedTargetPkgs == null && providedHostPkgs == null then
      import /src/nix/manylinux-2-28-packages.nix { inherit system; }
    else if providedTargetPkgs != null && providedHostPkgs != null then
      { targetPkgs = providedTargetPkgs; hostPkgs = providedHostPkgs; }
    else
      throw "mesa-zink: targetPkgs and hostPkgs must be supplied together";
  target = packageSets.targetPkgs;
  host = packageSets.hostPkgs;
  toolchain = import /src/nix/manylinux-2-28-stdenv.nix {
    inherit system;
    hostPkgs = host;
  };
  targetOverrides = [
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
        # Build-only consumers here need the CMake generator, not CTest/CPack
        # or full CMake's static libarchive dependency closure.
        cmake = previous.cmakeMinimal.overrideAttrs (old: {
          dontAddStaticConfigureFlags = true;
          configureFlags = builtins.filter
            (flag: flag != "--enable-static" && flag != "--disable-shared")
            (old.configureFlags or [ ]);
        });
        libdrm = previous.libdrm.override {
          withIntel = false;
          withValgrind = false;
        };
        # Pixman's test executables are not incorporated into Xvfb and their
        # static libpng link omits libz. The packaged GLX render test exercises
        # the incorporated pixman library at the product boundary.
        pixman = previous.pixman.overrideAttrs (old: {
          mesonFlags = (old.mesonFlags or [ ]) ++ [ "-Dtests=disabled" ];
          # Some nixpkgs pixman revisions still enter the test subdirectory
          # despite the option above when cross-building.  Those test
          # executables are build-only and pull in host OpenMP/zlib details;
          # remove the subdirectory explicitly for this static target.
          postPatch = (old.postPatch or "") + ''
            sed -i \
              -e "s/if not get_option('tests').disabled()/if false/" \
              -e "s/if not get_option('tests').disabled() or not get_option('demos').disabled()/if not get_option('demos').disabled()/" \
              meson.build
          '';
        });
        # libXfont2 unconditionally builds an uninstalled lsfontdir test
        # utility. Its static FreeType/Brotli link is incomplete, while the
        # library itself is incorporated into and exercised through Xvfb.
        libXfont2 = previous.libXfont2.overrideAttrs (old: {
          postPatch = (old.postPatch or "") + ''
            substituteInPlace Makefile.in \
              --replace-fail 'noinst_PROGRAMS = lsfontdir' 'noinst_PROGRAMS ='
          '';
          postConfigure = (old.postConfigure or "") + ''
            # configure regenerates Makefile from Makefile.am, so enforce the
            # same omission on the generated files before the static build.
            find . -name Makefile -type f -exec sed -i \
              's/noinst_PROGRAMS = lsfontdir/noinst_PROGRAMS =/' {} +
          '';
        });
        # Keep the lowercase nixpkgs compatibility alias on the same patched
        # derivation; some X.Org packages refer to one spelling or the other.
        libxfont_2 = previous.libXfont2.overrideAttrs (old: {
          postPatch = (old.postPatch or "") + ''
            substituteInPlace Makefile.in \
              --replace-fail 'noinst_PROGRAMS = lsfontdir' 'noinst_PROGRAMS ='
          '';
          postConfigure = (old.postConfigure or "") + ''
            find . -name Makefile -type f -exec sed -i \
              's/noinst_PROGRAMS = lsfontdir/noinst_PROGRAMS =/' {} +
          '';
        });
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
        # GDBM is consumed by the Python build toolchain, not incorporated
        # into Mesa or the final Xvfb binary. Its upstream test executables
        # assume a conventional host runtime and do not validate this target
        # library build.
        gdbm = previous.gdbm.overrideAttrs (_old: {
          doCheck = false;
        });
        # libcap-ng's change_id_test assumes the builder has a conventional
        # supplementary-group database.  It is a build-time capability test;
        # libcap-ng is not incorporated into the Mesa/Zink runtime closure.
        libcap_ng = previous.libcap_ng.overrideAttrs (_old: {
          doCheck = false;
        });
        openssl = previous.openssl.overrideAttrs (_old: {
          doCheck = false;
        });
        # Mesa consumes zstd as a compression library. Do not build zstd's
        # optional C++ pzstd/contrib program or upstream tests against the
        # manylinux 2.28 headers; those targets require newer pthread APIs.
        zstd = (previous.zstd.override {
          buildContrib = false;
        }).overrideAttrs (old: {
          outputs = builtins.filter (output: output != "man") (old.outputs or [ ]);
          cmakeFlags = (old.cmakeFlags or [ ]) ++ [
            "-DZSTD_BUILD_CONTRIB=OFF"
            "-DZSTD_BUILD_PROGRAMS=OFF"
            "-DZSTD_BUILD_TESTS=OFF"
          ];
        });
        pythonPackagesExtensions = previous.pythonPackagesExtensions ++ [
          (_pythonFinal: pythonPrevious:
            previous.lib.mapAttrs (_name: package:
              if previous.lib.isDerivation package && package ? overridePythonAttrs
              then package.overridePythonAttrs (_old: {
                # These packages are build tooling for Mesa, not runtime
                # contents. Their upstream suites assume optional dynamic
                # Python extensions that this static-library environment may
                # omit. Mesa configuration/compilation and the packaged GLX
                # render test exercise the relevant behavior instead.
                doCheck = false;
                doInstallCheck = false;
              })
              else package
            ) pythonPrevious)
        ];
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
  pkgs = target.extend (builtins.head targetOverrides);
  disabled = pkgs.emptyDirectory;
  noLLVM = pkgs.llvmPackages // {
    llvm = disabled;
    libllvm = disabled;
    clang = disabled;
    clang-unwrapped = disabled;
    libclc = disabled;
  };
  mesa = (pkgs.mesa.override {
    galliumDrivers = [ "zink" ];
    vulkanDrivers = [ ];
    vulkanLayers = [ ];
    eglPlatforms = [ "x11" ];
    enablePatentEncumberedCodecs = false;
    withValgrind = false;
    llvmPackages = noLLVM;
    directx-headers = disabled;
    elfutils = disabled;
    libunwind = disabled;
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
  }).overrideAttrs (old: {
    # The manylinux target headers expose C11 atomics, but Mesa's portability
    # include path does not include the standard header before using
    # atomic_bool. Keep this source adjustment local to the Mesa build.
    postPatch = (old.postPatch or "") + ''
      sed -i '1i#include <${toolchain.gccAtomicHeader}/include/manylinux-stdatomic.h>' src/util/os_file_notify.c
    '';
  });
  nativeToolPnames = [
    "meson" "pkg-config-wrapper" "ninja" "intltool" "bison" "flex"
    "file" "python3" "packaging" "pycparser" "mako" "ply" "pyyaml"
  ];
  hostNativeTools = [
    host.meson
    host.pkg-config
    host.ninja
    host.intltool
    host.bison
    host.flex
    host.file
    host.python3
    host.python3Packages.packaging
    host.python3Packages.pycparser
    host.python3Packages.mako
    host.python3Packages.ply
    host.python3Packages.pyyaml
  ];
in
mesa.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [
    ./patches/mesa-0002-linked-swrast-entrypoint.patch
    ./patches/mesa-0003-force-linked-zink.patch
  ];
  outputs = [ "out" ];
  nativeBuildInputs =
    (builtins.filter
      (input: !(builtins.elem (input.pname or "") nativeToolPnames))
      (old.nativeBuildInputs or [ ]))
    ++ hostNativeTools;
  buildInputs = builtins.filter
    (input: (input.pname or "") != "python3")
    (old.buildInputs or [ ]);
  preConfigure = (old.preConfigure or "") + ''
    substituteInPlace src/gallium/targets/dri/meson.build \
      --replace-fail 'libgallium_dri = shared_library(' 'libgallium_dri = static_library('
    substituteInPlace src/gallium/targets/dri/meson.build \
      --replace-fail 'name_suffix : libname_suffix,' ""
    substituteInPlace src/meson.build \
      --replace-fail "    subdir('gallium/targets/dril')" \
      "    message('Skipping unused dynamic dril loader')"
    substituteInPlace src/glx/meson.build \
      --replace-fail 'libgl = shared_library(' 'libgl = static_library('
    substituteInPlace src/glx/meson.build \
      --replace-fail 'version : gl_lib_version,' "" \
      --replace-fail "darwin_versions : '4.0.0'," ""
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
    gallium_archive="$(echo "$out"/lib/libgallium-*.a)"
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
