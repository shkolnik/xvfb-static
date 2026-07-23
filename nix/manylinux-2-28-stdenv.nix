{ system ? builtins.currentSystem
, hostPkgs ?
    let
      flake = builtins.getFlake (toString ../.);
    in
    import flake.inputs.nixpkgs { inherit system; }
}:

let
  sysroot = import ./manylinux-2-28-sysroot.nix {
    inherit system hostPkgs;
  };
  gccRuntime = import ./manylinux-2-28-gcc-runtime.nix {
    inherit system hostPkgs;
  };
  deploymentLoader =
    if system == "x86_64-linux" then "/lib64/ld-linux-x86-64.so.2"
    else if system == "aarch64-linux" then "/lib/ld-linux-aarch64.so.1"
    else throw "manylinux-2-28-stdenv: unsupported system ${system}";
  # Target-built helper programs (for example tzdata's zic) execute during
  # the Nix build. They cannot use the deployment path because that loader is
  # intentionally absent from the build sandbox. Final artifacts are rewritten
  # to deploymentLoader at their package boundary.
  buildLoader =
    if system == "x86_64-linux" then "${sysroot.out}/lib64/ld-linux-x86-64.so.2"
    else "${sysroot.out}/lib64/ld-linux-aarch64.so.1";
  targetTriplet =
    if system == "x86_64-linux" then "x86_64-unknown-linux-gnu"
    else "aarch64-unknown-linux-gnu";
  # The host GCC is intentionally retained as the modern compiler, but its
  # stock libstdc++ headers describe the host glibc and enable pthread APIs
  # newer than the manylinux sysroot.  Keep the complete header set while
  # correcting only those generated feature switches; the static libstdc++
  # archive itself comes from gccRuntime and is built against the sysroot.
  gccCxxHeaders = hostPkgs.runCommand "manylinux-2-28-gcc-cxx-headers-${system}" { } ''
    mkdir -p "$out/include/c++"
    cp -a ${hostPkgs.gcc14.cc}/include/c++/${hostPkgs.gcc14.version} "$out/include/c++/"
    chmod -R u+w "$out/include/c++/${hostPkgs.gcc14.version}"
    config="$out/include/c++/${hostPkgs.gcc14.version}/${targetTriplet}/bits/c++config.h"
    test -f "$config"
    sed -i \
      -e '/#define _GLIBCXX_USE_PTHREAD_COND_CLOCKWAIT/d' \
      -e '/#define _GLIBCXX_USE_PTHREAD_MUTEX_CLOCKLOCK/d' \
      -e '/#define _GLIBCXX_USE_PTHREAD_RWLOCK_CLOCKLOCK/d' \
      "$config"
    ! grep -q '_GLIBCXX_USE_PTHREAD_COND_CLOCKWAIT' "$config"
    ! grep -q '_GLIBCXX_USE_PTHREAD_MUTEX_CLOCKLOCK' "$config"
    ! grep -q '_GLIBCXX_USE_PTHREAD_RWLOCK_CLOCKLOCK' "$config"
  '';
  gccAtomicHeader = hostPkgs.runCommand "manylinux-2-28-gcc-atomic-header-${system}" { } ''
    mkdir -p "$out/include"
    atomic_header=$(find ${hostPkgs.gcc14.cc}/lib/gcc -type f -path '*/include/stdatomic.h' -print -quit)
    test -n "$atomic_header"
    cp "$atomic_header" "$out/include/manylinux-stdatomic.h"
    test -s "$out/include/manylinux-stdatomic.h"
  '';
  libcFacade = hostPkgs.runCommand "manylinux-2-28-libc-facade-${system}" {
    outputs = [ "out" "dev" ];
  } ''
    mkdir -p "$out" "$dev"
    ln -s ${sysroot.dev}/lib64 "$out/lib"
    ln -s ${sysroot.dev}/include "$dev/include"
  '';
  wrappedBintools = hostPkgs.wrapBintoolsWith {
    bintools = hostPkgs.binutils;
    libc = libcFacade;
    sharedLibraryLoader = null;
    extraBuildCommands = ''
      printf '%s\n' '${buildLoader}' > "$out/nix-support/dynamic-linker"
      touch "$out/nix-support/ld-set-dynamic-linker"
      # Build-time target helpers use the manylinux loader above. Give that
      # loader its matching libc search path; package boundaries remove this
      # build-only RPATH before auditing or distribution.
      printf '%s\n' '-rpath ${sysroot.out}/lib64' > "$out/nix-support/libc-ldflags"
      printf '%s\n' 'export NIX_NO_SELF_RPATH=1' >> "$out/nix-support/setup-hook"
    '';
  };
  wrappedCC = hostPkgs.wrapCCWith {
    cc = hostPkgs.gcc14.cc;
    bintools = wrappedBintools;
    libc = libcFacade;
    nixSupport = {
      # Use the host compiler's modern C++ implementation with a patched
      # feature header; the static libstdc++ archive itself comes from the
      # sysroot-built GCC runtime.
      "cc-cflags" = "--sysroot=${libcFacade} -B${gccRuntime.runtime}/lib -isystem ${gccCxxHeaders}/include/c++/${hostPkgs.gcc14.version} -isystem ${gccCxxHeaders}/include/c++/${hostPkgs.gcc14.version}/${targetTriplet}";
    };
  };
  compatBaseStdenv = hostPkgs.stdenv.override (old: {
    preHook = (old.preHook or "") + ''
      export NIX_NO_SELF_RPATH=1
      export NIX_CFLAGS_LINK="''${NIX_CFLAGS_LINK-} -static-libgcc -static-libstdc++"
    '';
  });
  compatStdenv = hostPkgs.overrideCC compatBaseStdenv wrappedCC;
in
assert sysroot.glibcFloor == "2.28";
{
  stdenv = compatStdenv;
  cc = wrappedCC;
  libc = libcFacade;
  inherit gccRuntime sysroot;
  inherit buildLoader deploymentLoader;
  inherit gccCxxHeaders;
  inherit gccAtomicHeader;
  glibcFloor = "2.28";
}
