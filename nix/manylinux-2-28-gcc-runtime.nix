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
  runtimeSysroot = hostPkgs.runCommand "manylinux-2-28-gcc-runtime-sysroot-${system}" { } ''
    mkdir -p "$out/usr"
    ln -s ${sysroot.dev}/include "$out/include"
    ln -s ${sysroot.dev}/include "$out/usr/include"
    ln -s ${sysroot.dev}/lib64 "$out/lib"
    ln -s ${sysroot.dev}/lib64 "$out/lib64"
    ln -s ${sysroot.dev}/lib64 "$out/usr/lib"
    ln -s ${sysroot.dev}/lib64 "$out/usr/lib64"
  '';
  source = hostPkgs.gcc14.cc.src;
  gccVersion = hostPkgs.gcc14.version;
  build = hostPkgs.stdenv.buildPlatform.config;
  host = hostPkgs.stdenv.hostPlatform.config;
  target =
    if system == "aarch64-linux" then "aarch64-pc-linux-gnu"
    else if system == "x86_64-linux" then "x86_64-pc-linux-gnu"
    else throw "manylinux-2-28-gcc-runtime: unsupported system ${system}";
  targetTools = "${hostPkgs.binutils}/bin";
  nativeGmpInclude = "${hostPkgs.gmp.dev}/include";
  nativeGmpLib = "${hostPkgs.gmp}/lib";
  nativeMpfrInclude = "${hostPkgs.mpfr.dev}/include";
  nativeMpfrLib = "${hostPkgs.mpfr}/lib";
  nativeMpcInclude = "${hostPkgs.libmpc}/include";
  nativeMpcLib = "${hostPkgs.libmpc}/lib";
  buildHardeningEnableVar =
    "NIX_HARDENING_ENABLE_${hostPkgs.lib.replaceStrings [ "-" ] [ "_" ]
      hostPkgs.stdenv.buildPlatform.config}";
  runtimeBuildDirHelper = ''
    resolve_runtime_build_dir() {
      case "$1" in
        /*) printf '%s/runtime-build\n' "$1" ;;
        *) printf '%s/%s/runtime-build\n' "$NIX_BUILD_TOP" "$1" ;;
      esac
    }
  '';
  runtime = hostPkgs.stdenv.mkDerivation {
    pname = "manylinux-2-28-gcc-runtime";
    version = gccVersion;
    src = source;

    strictDeps = true;
    nativeBuildInputs = [
      hostPkgs.bison
      hostPkgs.flex
      hostPkgs.gawk
      hostPkgs.gmp
      hostPkgs.gnugrep
      hostPkgs.gnused
      hostPkgs.makeWrapper
      hostPkgs.libmpc
      hostPkgs.mpfr
      hostPkgs.perl
      hostPkgs.which
    ];

    dontConfigure = true;

    buildPhase = ''
      runHook preBuild

      ${runtimeBuildDirHelper}
      assert_runtime_build_dir_resolution() (
        NIX_BUILD_TOP=/build
        test "$(resolve_runtime_build_dir gcc-14.3.0)" = \
          "/build/gcc-14.3.0/runtime-build"
        test "$(resolve_runtime_build_dir /build/gcc-14.3.0)" = \
          "/build/gcc-14.3.0/runtime-build"
      )
      assert_runtime_build_dir_resolution

      build_dir=$(resolve_runtime_build_dir "$sourceRoot")
      source_dir="''${build_dir%/runtime-build}"
      configure_path="$source_dir/configure"
      compiler_stage_targets='all-gcc'
      runtime_targets='all-target-libgcc all-target-libstdc++-v3'
      make_jobs="''${NIX_BUILD_CORES:-1}"
      case "$make_jobs" in
        '''|*[!0-9]*|0)
          echo "manylinux-2-28-gcc-runtime: NIX_BUILD_CORES must be a positive integer, got: $make_jobs" >&2
          exit 1
          ;;
      esac
      test -f "$configure_path" || {
        echo "manylinux-2-28-gcc-runtime: locked GCC configure script is missing: $configure_path" >&2
        exit 1
      }
      case "$build_dir" in
        "$source_dir"/*) ;;
        *)
          echo "manylinux-2-28-gcc-runtime: runtime build directory must be inside GCC sourceRoot" >&2
          exit 1
          ;;
      esac
      mkdir -p "$build_dir"
      cd "$build_dir"

      assert_bounded_make_targets() {
        phase=$1
        targets=$2
        if printf '%s\n' "$targets" | grep -Eq \
          '(^|[[:space:]])(bootstrap|stage[0-9]+|install-[^[:space:]]*)([[:space:]]|$)'; then
          echo "manylinux-2-28-gcc-runtime: $phase make targets are forbidden: $targets" >&2
          exit 1
        fi
        case "$phase" in
          compiler-stage)
            test "$targets" = "$compiler_stage_targets" && test "$targets" = all-gcc || {
              echo "manylinux-2-28-gcc-runtime: compiler stage must be exactly all-gcc, got: $targets" >&2
              exit 1
            }
            ;;
          runtime)
            test "$targets" = "$runtime_targets" || {
              echo "manylinux-2-28-gcc-runtime: runtime targets changed: $targets" >&2
              exit 1
            }
            ;;
          *)
            echo "manylinux-2-28-gcc-runtime: unknown make-target phase: $phase" >&2
            exit 1
            ;;
        esac
      }

      emit_make_log_excerpt() {
        label=$1
        log=$2
        echo "manylinux-2-28-gcc-runtime: $label log first 100 lines"
        sed -n '1,100p' "$log"
        echo "manylinux-2-28-gcc-runtime: $label log last 100 lines"
        tail -n 100 "$log"
      }

      printf 'manylinux-2-28-gcc-runtime: configure source=%s version=%s target=%s\n' \
        '${source}' '${gccVersion}' '${target}'

      "$configure_path" \
        --build=${build} \
        --host=${host} \
        --target=${target} \
        --with-build-time-tools=${targetTools} \
        --with-sysroot=${runtimeSysroot} \
        --with-native-system-header-dir=/include \
        --with-gmp-include=${nativeGmpInclude} \
        --with-gmp-lib=${nativeGmpLib} \
        --with-mpfr-include=${nativeMpfrInclude} \
        --with-mpfr-lib=${nativeMpfrLib} \
        --with-mpc-include=${nativeMpcInclude} \
        --with-mpc-lib=${nativeMpcLib} \
        --disable-bootstrap \
        --disable-multilib \
        --disable-nls \
        --disable-shared \
        --disable-libatomic \
        --disable-libcc1 \
        --disable-libgomp \
        --disable-libquadmath \
        --disable-libsanitizer \
        --disable-libssp \
        --disable-libstdcxx-pch \
        --disable-libvtv \
        --enable-languages=c,c++ \
        --enable-static

      assert_bounded_make_targets compiler-stage "$compiler_stage_targets"
      build_hardening_enable_var='${buildHardeningEnableVar}'
      build_hardening_namespace_before=''${!build_hardening_enable_var-}
      build_hardening_default_before=''${NIX_HARDENING_ENABLE-}
      (
        if test -z "''${!build_hardening_enable_var-}"; then
          printf -v "$build_hardening_enable_var" '%s' \
            "$build_hardening_default_before"
          export "$build_hardening_enable_var"
        fi
        host_hardening_before=''${!build_hardening_enable_var-}
        host_hardening_without_format=""
        case " $host_hardening_before " in
          *' format '*) ;;
          *)
            echo 'manylinux-2-28-gcc-runtime: expected host format hardening policy is absent' >&2
            exit 1
            ;;
        esac
        for hardening_feature in $host_hardening_before; do
          if test "$hardening_feature" != format; then
            host_hardening_without_format="''${host_hardening_without_format:+$host_hardening_without_format }$hardening_feature"
          fi
        done
        printf 'manylinux-2-28-gcc-runtime: compiler-stage host hardening namespace before=%s\n' \
          "$build_hardening_namespace_before"
        printf 'manylinux-2-28-gcc-runtime: compiler-stage host hardening before=%s\n' \
          "$host_hardening_before"
        printf 'manylinux-2-28-gcc-runtime: compiler-stage host hardening after=%s\n' \
          "$host_hardening_without_format"
        printf -v "$build_hardening_enable_var" '%s' "$host_hardening_without_format"
        export "$build_hardening_enable_var"
        NIX_HARDENING_ENABLE="$host_hardening_without_format"
        export NIX_HARDENING_ENABLE
        make -j "$make_jobs" $compiler_stage_targets
      ) > "$NIX_BUILD_TOP/compiler-stage.log" 2>&1 || {
        cat "$NIX_BUILD_TOP/compiler-stage.log" >&2
        exit 1
      }
      emit_make_log_excerpt compiler-stage "$NIX_BUILD_TOP/compiler-stage.log"
      test -x "$build_dir/gcc/xgcc"

      assert_bounded_make_targets runtime "$runtime_targets"
      runtime_hardening_namespace_begin=''${!build_hardening_enable_var-}
      runtime_hardening_default_begin=''${NIX_HARDENING_ENABLE-}
      test "$runtime_hardening_namespace_begin" = "$build_hardening_namespace_before" || {
        echo 'manylinux-2-28-gcc-runtime: runtime host hardening namespace changed after compiler stage' >&2
        exit 1
      }
      test "$runtime_hardening_default_begin" = "$build_hardening_default_before" || {
        echo 'manylinux-2-28-gcc-runtime: runtime host hardening policy changed after compiler stage' >&2
        exit 1
      }
      {
        printf 'manylinux-2-28-gcc-runtime: runtime host hardening namespace begin=%s\n' \
          "$runtime_hardening_namespace_begin"
        printf 'manylinux-2-28-gcc-runtime: runtime host hardening begin=%s\n' \
          "$runtime_hardening_default_begin"
        make -j "$make_jobs" \
          CFLAGS_FOR_TARGET='--sysroot=${runtimeSysroot} -fPIC' \
          CXXFLAGS_FOR_TARGET='--sysroot=${runtimeSysroot} -fPIC' \
          $runtime_targets
      } > "$NIX_BUILD_TOP/runtime-build.log" 2>&1 || {
        cat "$NIX_BUILD_TOP/runtime-build.log" >&2
        exit 1
      }
      emit_make_log_excerpt runtime "$NIX_BUILD_TOP/runtime-build.log"

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      ${runtimeBuildDirHelper}
      build_dir=$(resolve_runtime_build_dir "$sourceRoot")
      target_runtime_dir="$build_dir/${target}"
      test -d "$target_runtime_dir" || {
        echo "manylinux-2-28-gcc-runtime: target runtime subtree is missing: $target_runtime_dir" >&2
        exit 1
      }
      mkdir -p "$out/lib" "$out/nix-support"
      copy_target_runtime_file() {
        name=$1
        destination=$2
        matches=$(find "$target_runtime_dir" -type f -name "$name" -print)
        count=$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l)
        test "$count" -eq 1 || {
          echo "manylinux-2-28-gcc-runtime: expected one $name, found $count" >&2
          printf '%s\n' "$matches" >&2
          exit 1
        }
        cp "$matches" "$destination"
      }

      copy_target_runtime_file libgcc.a "$out/lib/libgcc.a"
      copy_target_runtime_file libstdc++.a "$out/lib/libstdc++.a"
      copy_target_runtime_file libsupc++.a "$out/lib/libsupc++.a"
      copy_target_runtime_file crtbeginS.o "$out/lib/crtbeginS.o"
      copy_target_runtime_file crtendS.o "$out/lib/crtendS.o"

      printf '%s\n' '${source}' > "$out/nix-support/gcc-source"
      printf '%s\n' '${gccVersion}' > "$out/nix-support/gcc-version"
      printf '%s\n' '${build}' > "$out/nix-support/gcc-build"
      printf '%s\n' '${host}' > "$out/nix-support/gcc-host"
      printf '%s\n' '${target}' > "$out/nix-support/gcc-target"
      printf '%s\n' '${targetTools}' > "$out/nix-support/gcc-build-time-tools"
      printf '%s\n' "$compiler_stage_targets" \
        > "$out/nix-support/compiler-stage-targets"
      printf '%s\n' 'format' \
        > "$out/nix-support/compiler-stage-host-hardening-disabled"
      printf '%s\n' 'NIX_BUILD_CORES' \
        > "$out/nix-support/make-jobs-source"
      printf '%s\n' "$runtime_targets" \
        > "$out/nix-support/runtime-targets"

      expected_inventory="$NIX_BUILD_TOP/expected-runtime-inventory"
      cat > "$expected_inventory" <<'EOF'
lib/crtbeginS.o
lib/crtendS.o
lib/libgcc.a
lib/libstdc++.a
lib/libsupc++.a
nix-support/compiler-stage-targets
nix-support/compiler-stage-host-hardening-disabled
nix-support/gcc-build
nix-support/gcc-build-time-tools
nix-support/gcc-host
nix-support/gcc-source
nix-support/gcc-target
nix-support/gcc-version
nix-support/make-jobs-source
nix-support/runtime-targets
EOF
      find "$out" -type f -printf '%P\n' | LC_ALL=C sort > "$NIX_BUILD_TOP/runtime-inventory"
      LC_ALL=C sort "$expected_inventory" | diff -u - "$NIX_BUILD_TOP/runtime-inventory"
      if find "$out" -type f \( -name gcc -o -name g++ -o -name cc1 -o -name cc1plus \) -print -quit | grep -q .; then
        echo 'manylinux-2-28-gcc-runtime: installed compiler executable is forbidden' >&2
        exit 1
      fi

      runHook postInstall
    '';

    passthru = {
      interface = "manylinux-2-28-gcc-runtime";
      inherit build gccVersion host runtimeSysroot source sysroot target targetTools;
    };
  };
in
assert gccVersion == "14.3.0";
{
  interface = "manylinux-2-28-gcc-runtime";
  inherit build gccVersion host runtime runtimeSysroot source sysroot target targetTools;
}
