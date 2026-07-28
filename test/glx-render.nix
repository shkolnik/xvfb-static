# The GLX render/readback client used by the two GLX alpha smoke tests. It
# talks to the packaged Xvfb only over the X11/GLX wire protocol (indirect
# rendering; see glx-render.c), so the client's own Mesa build never decides
# what the server renders with -- but it does decide which libraries, and
# which licensing obligations, end up baked into the test binary itself.
#
# Build it against the same backend as the archive under test:
# mesa-llvmpipe.nix (LLVM plus llvmpipe, fully static pkgsStatic build) for
# the llvmpipe, mesa-zink.nix built with the manylinux_2_28 toolchain
# (no LLVM at all, static libraries over a dynamic host glibc) for the
# external Vulkan alpha. Building the external-Vulkan client against
# mesa-llvmpipe.nix would link the one binary that is supposed to exercise
# the no-LLVM artifact against the two things that artifact exists to
# exclude; see AGENTS.md section 11 ("test-coverage asymmetries").
{ system ? builtins.currentSystem
, pkgs ? import (builtins.getFlake (toString ../.)).inputs.nixpkgs { inherit system; }
, backend ? "llvmpipe"
}:
let
  llvmpipeRenderTest =
    let
      static = pkgs.pkgsStatic;
      mesa = import ../mesa-llvmpipe.nix { inherit system pkgs; };
    in
    static.stdenv.mkDerivation {
      pname = "xvfb-static-glx-render-test";
      version = "1";
      dontUnpack = true;
      nativeBuildInputs = [ pkgs.pkg-config ];
      buildInputs = [
        mesa
        static.libx11
        static.libxext
        static.libxau
        static.libxdmcp
      ];
      buildPhase = ''
        runHook preBuild
        $CC -O2 -static -Wl,--allow-multiple-definition ${./glx-render.c} \
          $(pkg-config --cflags --libs gl) \
          ${static.libxau}/lib/libXau.a ${static.libxdmcp}/lib/libXdmcp.a \
          -L${static.stdenv.cc.cc.lib}/lib -lstdc++ \
          -o glx-render-test
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin
        cp glx-render-test $out/bin/
        runHook postInstall
      '';
    };

  # Static libraries over a dynamic host glibc, exactly like the packaged
  # external-Vulkan Xvfb itself (package-glx-external-vulkan.nix): the target
  # package set forces makeStaticLibraries, so `-static` is neither available
  # nor needed, but the compat stdenv does not default pkg-config lookups to
  # static resolution the way pkgsStatic's wrapper does -- Xvfb's own meson
  # build has to ask for `static: true` explicitly, and so does this raw
  # pkg-config invocation. The finished binary's interpreter is rewritten to
  # the deployment loader the same way package-glx-external-vulkan.nix
  # rewrites Xvfb's, so it runs on the same host-assisted glibc floor.
  zinkRenderTest =
    let
      packageSets = import ../nix/manylinux-2-28-packages.nix { inherit system; };
      target = packageSets.targetPkgs;
      host = packageSets.hostPkgs;
      toolchain = packageSets.toolchain;
      mesa = import ../mesa-zink.nix {
        inherit system;
        targetPkgs = target;
        hostPkgs = host;
      };
      staticOverrides = import ../nix/manylinux-2-28-static-overrides.nix;
      libdrmStatic = staticOverrides.noIntelNoValgrindLibdrm target.libdrm;
      # gl.pc's own "Requires: glx" pulls in glx.pc's full Requires/
      # Requires.private chain; confirmed by reading the built gl.pc/glx.pc
      # from the mesa-zink derivation directly rather than guessing:
      # zlib, libdrm, xcb (+ xcb-randr/dri3/present/sync/xfixes/shm/glx/dri2,
      # all provided by the one libxcb package), xshmfence, x11 (+ x11-xcb),
      # xcb-keysyms, glproto (from xorgproto), xext, xxf86vm.
    in
    target.stdenv.mkDerivation {
      pname = "xvfb-static-glx-render-test";
      version = "1";
      dontUnpack = true;
      nativeBuildInputs = [ host.pkg-config host.patchelf ];
      buildInputs = [
        mesa
        libdrmStatic
        target.zlib
        target.libx11
        target.libxcb
        target.libxext
        target.libxfixes
        target.libxxf86vm
        target.libxshmfence
        target.xcbutilkeysyms
        target.xorgproto
        target.libxau
        target.libxdmcp
      ];
      buildPhase = ''
        runHook preBuild
        # gl.pc/glx.pc's Libs.private carry a bare -lstdc++. Resolved with
        # the ordinary dynamic-preferring linker search, that picks up the
        # *host* toolchain's libstdc++.so (from the unrelated gcc-14.3.0-lib
        # closure the compiler itself depends on, found via its own built-in
        # search path) ahead of this sysroot's static archive; that host .so
        # references glibc symbol versions above this project's floor, so the
        # link fails outright rather than merely producing an unwanted
        # dynamic dependency. Bracketing the whole --libs output in
        # -Bstatic/-Bdynamic is not an option either: this manylinux sysroot
        # intentionally ships no static libpthread.a/libm.a/libdl.a (those
        # stay dynamic, matching the artifact's host-assisted contract), so a
        # blanket -Bstatic makes the linker fail looking for archives that
        # were never meant to exist. Strip the bare -lstdc++ token and link
        # the sysroot's own static libstdc++/libsupc++/libgcc archives (built
        # by manylinux-2-28-gcc-runtime.nix, the same ones the compat
        # stdenv's NIX_CFLAGS_LINK "-static-libgcc -static-libstdc++" targets
        # for a C++-frontend link) by absolute path instead, so -l resolution
        # mode never enters into it for these three.
        gl_cflags="$(pkg-config --static --cflags gl)"
        gl_libs="$(pkg-config --static --libs gl | tr ' ' '\n' | grep -v '^-lstdc++$' | tr '\n' ' ')"
        $CC -O2 $gl_cflags -Wl,--allow-multiple-definition ${./glx-render.c} \
          $gl_libs \
          ${target.libxau}/lib/libXau.a ${target.libxdmcp}/lib/libXdmcp.a \
          -Wl,--start-group \
          ${toolchain.gccRuntime.runtime}/lib/libstdc++.a \
          ${toolchain.gccRuntime.runtime}/lib/libsupc++.a \
          ${toolchain.gccRuntime.runtime}/lib/libgcc.a \
          -Wl,--end-group \
          -o glx-render-test
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin
        cp glx-render-test $out/bin/
        chmod u+w $out/bin/glx-render-test
        patchelf --set-interpreter ${toolchain.deploymentLoader} --remove-rpath \
          $out/bin/glx-render-test
        runHook postInstall
      '';
    };
in
if backend == "llvmpipe" then llvmpipeRenderTest
else if backend == "zink" then zinkRenderTest
else throw ''
  test/glx-render.nix: unknown backend "${backend}" (expected "llvmpipe" or "zink")
''
