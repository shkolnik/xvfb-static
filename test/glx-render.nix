# The GLX render/readback client used by the two GLX alpha smoke tests. It
# talks to the packaged Xvfb only over the X11/GLX wire protocol (indirect
# rendering; see glx-render.c), so the client's own Mesa build never decides
# what the server renders with -- but it does decide which libraries, and
# which licensing obligations, end up baked into the test binary itself.
#
# Build it against the same backend as the archive under test:
# mesa-llvmpipe.nix (LLVM plus llvmpipe, fully static pkgsStatic build) for
# the llvmpipe alpha, mesa-zink.nix built with the manylinux_2_28 toolchain
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
      # gl.pc's own Requires chain pulls in the same packages the shipped
      # Xvfb links against to satisfy the identical `dependency('gl', ...,
      # static: true)` request in package-glx-external-vulkan.nix -- mirror
      # that buildInputs list here rather than rediscovering it by trial.
      libdrmStatic = staticOverrides.noIntelNoValgrindLibdrm target.libdrm;
      bzip2Static = target.bzip2.override { enableStatic = true; };
      opensslStatic = (target.openssl.override { static = true; }).overrideAttrs (old: {
        configureFlags = (old.configureFlags or [ ]) ++ [ "no-tests" ];
        doCheck = false;
      });
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
        target.libxau
        target.libxdmcp
        target.brotli
        bzip2Static
        target.freetype
        target.libfontenc
        target.libpng
        opensslStatic
      ];
      buildPhase = ''
        runHook preBuild
        $CC -O2 -Wl,--allow-multiple-definition ${./glx-render.c} \
          $(pkg-config --static --cflags --libs gl) \
          ${target.libxau}/lib/libXau.a ${target.libxdmcp}/lib/libXdmcp.a \
          -static-libgcc -static-libstdc++ \
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
