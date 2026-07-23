{ system ? builtins.currentSystem
, hostPkgs ?
    let
      flake = builtins.getFlake (toString ../.);
    in
    import flake.inputs.nixpkgs { inherit system; }
}:

let
  packages = import ../nix/manylinux-2-28-packages.nix {
    inherit system hostPkgs;
  };
  inherit (packages) targetPkgs toolchain;
  gccRuntime = toolchain.gccRuntime;
  expectedTarget =
    if system == "aarch64-linux" then "aarch64-pc-linux-gnu"
    else if system == "x86_64-linux" then "x86_64-pc-linux-gnu"
    else throw "manylinux-2-28-toolchain: unsupported system ${system}";
  expectedLoader =
    if system == "aarch64-linux" then "ld-linux-aarch64.so.1"
    else "ld-linux-x86-64.so.2";
  auditPath = hostPkgs.lib.makeBinPath [
    hostPkgs.binutils
    hostPkgs.coreutils
    hostPkgs.gnugrep
    hostPkgs.gnused
  ];
in
assert toolchain.glibcFloor == "2.28";
assert gccRuntime.interface == "manylinux-2-28-gcc-runtime";
assert gccRuntime.build == hostPkgs.stdenv.buildPlatform.config;
assert gccRuntime.host == hostPkgs.stdenv.hostPlatform.config;
assert gccRuntime.target == expectedTarget;
assert gccRuntime.targetTools == "${hostPkgs.binutils}/bin";
assert toolchain.gccRuntime.interface == "manylinux-2-28-gcc-runtime";
assert toolchain.gccRuntime.runtime == gccRuntime.runtime;
assert builtins.readFile
  "${gccRuntime.runtime}/nix-support/gcc-build" ==
  "${hostPkgs.stdenv.buildPlatform.config}\n";
assert builtins.readFile
  "${gccRuntime.runtime}/nix-support/gcc-host" ==
  "${hostPkgs.stdenv.hostPlatform.config}\n";
assert builtins.readFile
  "${gccRuntime.runtime}/nix-support/gcc-target" == "${expectedTarget}\n";
assert builtins.readFile
  "${gccRuntime.runtime}/nix-support/gcc-build-time-tools" ==
  "${hostPkgs.binutils}/bin\n";
assert builtins.readFile
  "${gccRuntime.runtime}/nix-support/compiler-stage-targets" == "all-gcc\n";
assert builtins.readFile
  "${gccRuntime.runtime}/nix-support/compiler-stage-host-hardening-disabled" ==
  "format\n";
assert builtins.readFile
  "${gccRuntime.runtime}/nix-support/make-jobs-source" ==
  "NIX_BUILD_CORES\n";
assert builtins.readFile
  "${gccRuntime.runtime}/nix-support/runtime-targets" ==
  "all-target-libgcc all-target-libstdc++-v3\n";
toolchain.stdenv.mkDerivation {
  pname = "manylinux-2-28-toolchain-probes";
  version = "1";

  dontUnpack = true;
  buildInputs = [ targetPkgs.zlib ];
  nativeBuildInputs = [ hostPkgs.binutils hostPkgs.patchelf ];

  buildPhase = ''
    runHook preBuild
    cc ${./manylinux-2-28-probe.c} \
      -o manylinux-2-28-probe-c -pthread -ldl -lm 2> c.err || { cat c.err >&2; exit 1; }
    cc -v ${./manylinux-2-28-zlib-probe.c} \
      -o manylinux-2-28-probe-zlib \
      '${targetPkgs.zlib.static}/lib/libz.a' -pthread -ldl -lm \
      2> manylinux-2-28-probe-zlib.verbose || { cat manylinux-2-28-probe-zlib.verbose >&2; exit 1; }
    grep -F -- '--sysroot=${toolchain.libc}' manylinux-2-28-probe-zlib.verbose || {
      echo 'manylinux-2-28-toolchain: zlib probe did not use the compatibility sysroot' >&2
      sed -n '1,240p' manylinux-2-28-probe-zlib.verbose >&2
      exit 1
    }
    if ! c++ -v ${./manylinux-2-28-probe.cc} \
      -o manylinux-2-28-probe-cxx -static-libgcc -static-libstdc++ \
      2> manylinux-2-28-probe-cxx.verbose; then
      echo 'manylinux-2-28-toolchain: C++ probe link failed' >&2
      sed -n '1,260p' manylinux-2-28-probe-cxx.verbose >&2
      exit 1
    fi
    grep -F '${gccRuntime.runtime}/lib' manylinux-2-28-probe-cxx.verbose || {
      echo 'manylinux-2-28-toolchain: rebuilt runtime prefix missing from verbose C++ link command' >&2
      sed -n '1,240p' manylinux-2-28-probe-cxx.verbose >&2
      exit 1
    }
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -D -m 0755 manylinux-2-28-probe-c \
      "$out/bin/manylinux-2-28-probe-c"
    install -D -m 0755 manylinux-2-28-probe-cxx \
      "$out/bin/manylinux-2-28-probe-cxx"
    install -D -m 0755 manylinux-2-28-probe-zlib \
      "$out/bin/manylinux-2-28-probe-zlib"
    for binary in "$out"/bin/manylinux-2-28-probe-*; do
      patchelf --set-interpreter '${toolchain.deploymentLoader}' "$binary"
      patchelf --remove-rpath "$binary"
    done
    mkdir -p "$out/nix-support"
    install -D -m 0644 manylinux-2-28-probe-cxx.verbose \
      "$out/nix-support/cxx-link-command"
    install -D -m 0644 manylinux-2-28-probe-zlib.verbose \
      "$out/nix-support/zlib-link-command"
    printf '%s\n' '${auditPath}' > "$out/nix-support/audit-path"
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    audit_glibc_versions() {
      binary=$1
      versions="$TMPDIR/$(basename "$binary").glibc-versions"
      ${hostPkgs.binutils}/bin/readelf --version-info -W "$binary" |
        sed -n 's/.*Name: GLIBC_\([0-9][0-9.]*\).*/\1/p' |
        sort -Vu > "$versions"
      test -s "$versions" || {
        echo "$binary has no imported GLIBC symbol versions" >&2
        return 1
      }

      maximum=$(tail -n 1 "$versions")
      if ! { cat "$versions"; printf '%s\n' '${toolchain.glibcFloor}'; } |
        sort -V -C; then
        echo "$binary imports GLIBC_$maximum, newer than GLIBC_${toolchain.glibcFloor}" >&2
        while IFS= read -r version; do
          if ! printf '%s\n%s\n' "$version" '${toolchain.glibcFloor}' |
            sort -V -C; then
            ${hostPkgs.binutils}/bin/readelf --dyn-syms -W "$binary" |
              grep -F "@GLIBC_$version" >&2 || true
          fi
        done < "$versions"
        return 1
      fi
      printf '%s\n' "$maximum" > "$out/nix-support/$(basename "$binary").maximum-glibc"
    }

    audit_glibc_versions "$out/bin/manylinux-2-28-probe-c"
    audit_glibc_versions "$out/bin/manylinux-2-28-probe-cxx"
    audit_glibc_versions "$out/bin/manylinux-2-28-probe-zlib"
    readelf -dW "$out/bin/manylinux-2-28-probe-zlib" |
      sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' |
      while IFS= read -r library; do
        case "$library" in
          libc.so.6|libdl.so.2|libm.so.6|libpthread.so.0|librt.so.1|"${expectedLoader}") ;;
          *) echo "zlib probe has unexpected dynamic dependency: $library" >&2; exit 1 ;;
        esac
      done
    runHook postInstallCheck
  '';
}
