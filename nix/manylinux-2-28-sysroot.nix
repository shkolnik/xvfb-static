{ system ? builtins.currentSystem
, hostPkgs ?
    let
      flake = builtins.getFlake (toString ../.);
    in
    import flake.inputs.nixpkgs { inherit system; }
}:

let
  lock = import ./manylinux-2-28-images.nix { inherit system; };
  outputs = [ "out" "dev" "static" ];
  expectedLoader =
    if system == "x86_64-linux" then "ld-linux-x86-64.so.2"
    else if system == "aarch64-linux" then "ld-linux-aarch64.so.1"
    else throw "manylinux-2-28-sysroot: unsupported system ${system}";
  image = hostPkgs.dockerTools.pullImage {
    imageName = lock.imageName;
    imageDigest = lock.imageDigest;
    sha256 = lock.sha256;
    finalImageName = lock.imageName;
    finalImageTag = "locked";
  };
  patchedUmoci = hostPkgs.umoci.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      ../patches/umoci-0001-rootless-mask-privileged-mode-bits.patch
    ];
    doCheck = true;
    checkPhase = ''
      runHook preCheck
      go test ./oci/layer -run '^TestModeForUnpack$'
      runHook postCheck
    '';
  });
  sysroot = hostPkgs.runCommand "manylinux-2-28-glibc-sysroot-${system}" {
    inherit outputs;
    nativeBuildInputs = [
      hostPkgs.coreutils
      hostPkgs.findutils
      hostPkgs.gnugrep
      hostPkgs.gnused
      hostPkgs.gnutar
      hostPkgs.skopeo
      patchedUmoci
    ];
    passthru = {
      imageDigest = lock.imageDigest;
      policy = lock.policy;
      glibcFloor = lock.glibcFloor;
    };
  } ''
    set -euo pipefail

    phase=setup
    trap 'status=$?; echo "manylinux-2-28-sysroot: phase=$phase status=$status" >&2' EXIT

    oci="$TMPDIR/image"
    bundle="$TMPDIR/unpacked"
    root="$bundle/rootfs"
    umoci_log="$TMPDIR/umoci.log"

    phase=skopeo-copy
    skopeo --insecure-policy copy \
      docker-archive:${image} "oci:$oci:locked"
    phase=umoci-unpack
    if ! umoci unpack --rootless --image "$oci:locked" "$bundle" \
      >"$umoci_log" 2>&1; then
      echo 'manylinux-2-28-sysroot: umoci unpack failed:' >&2
      tail -n 100 "$umoci_log" >&2
      exit 1
    fi

    phase=validate-unpacked-root
    test -d "$root/lib64"
    test -d "$root/usr/lib64"
    test -d "$root/usr/include"

    phase=create-outputs
    mkdir -p "$out/lib64" "$dev/include" "$dev/lib64" \
      "$static/lib64" "$dev/nix-support"

    copy_matches() {
      source_dir="$1"
      destination_dir="$2"
      shift 2
      for pattern in "$@"; do
        for source_path in "$source_dir"/$pattern; do
          if test -e "$source_path" || test -L "$source_path"; then
            cp -a "$source_path" "$destination_dir/"
          fi
        done
      done
    }

    # Runtime files are deliberately limited to the loader and libraries that
    # form the external-Vulkan artifact's glibc ABI.
    phase=copy-runtime
    copy_matches "$root/lib64" "$out/lib64" \
      'ld-*.so' 'ld-linux-*.so.*' \
      'libc-*.so' 'libc.so.*' \
      'libm-*.so' 'libm.so.*' \
      'libmvec-*.so' 'libmvec.so.*' \
      'libpthread-*.so' 'libpthread.so.*' \
      'libdl-*.so' 'libdl.so.*' \
      'librt-*.so' 'librt.so.*'

    phase=copy-development
    copy_matches "$root/usr/lib64" "$dev/lib64" \
      'crt*.o' 'libc.so' 'libm.so' 'libmvec.so' \
      'libpthread.so' 'libdl.so' 'librt.so'

    phase=copy-static
    copy_matches "$root/usr/lib64" "$static/lib64" \
      'libc.a' 'libc_nonshared.a' \
      'libm.a' 'libmvec.a' 'libmvec_nonshared.a' \
      'libpthread.a' 'libpthread_nonshared.a' \
      'libdl.a' 'librt.a'

    phase=copy-headers
    # This allowlist is the byte-sorted set of /usr/include top-level paths
    # owned by glibc-devel, glibc-headers, and kernel-headers in the pinned
    # manylinux image. Keeping it explicit prevents unrelated development
    # packages in the image from silently broadening the target interface.
    copy_matches "$root/usr/include" "$dev/include" \
      'a.out.h' 'aio.h' 'aliases.h' 'alloca.h' 'ar.h' 'argp.h' 'argz.h' \
      'arpa' 'asm' 'asm-generic' 'assert.h' 'bits' 'byteswap.h' \
      'complex.h' 'cpio.h' 'cpuidle.h' 'ctype.h' 'dirent.h' 'dlfcn.h' \
      'drm' 'elf.h' 'endian.h' 'envz.h' 'err.h' 'errno.h' 'error.h' \
      'execinfo.h' 'fcntl.h' 'features.h' 'fenv.h' 'finclude' 'fmtmsg.h' \
      'fnmatch.h' 'fpu_control.h' 'fstab.h' 'fts.h' 'ftw.h' 'gconv.h' \
      'getopt.h' 'glob.h' 'gnu' 'gnu-versions.h' 'grp.h' 'gshadow.h' \
      'iconv.h' 'ieee754.h' 'ifaddrs.h' 'inttypes.h' 'langinfo.h' \
      'lastlog.h' 'libgen.h' 'libintl.h' 'limits.h' 'link.h' 'linux' \
      'locale.h' 'malloc.h' 'math.h' 'mcheck.h' 'memory.h' 'misc' \
      'mntent.h' 'monetary.h' 'mqueue.h' 'mtd' 'net' 'netash' 'netatalk' \
      'netax25' 'netdb.h' 'neteconet' 'netinet' 'netipx' 'netiucv' \
      'netpacket' 'netrom' 'netrose' 'nfs' 'nl_types.h' 'nss.h' \
      'obstack.h' 'paths.h' 'perf' 'poll.h' 'printf.h' 'proc_service.h' \
      'protocols' 'pthread.h' 'pty.h' 'pwd.h' 'rdma' 're_comp.h' \
      'regex.h' 'regexp.h' 'resolv.h' 'rpc' 'sched.h' 'scsi' 'search.h' \
      'semaphore.h' 'setjmp.h' 'sgtty.h' 'shadow.h' 'signal.h' 'sound' \
      'spawn.h' 'stab.h' 'stdc-predef.h' 'stdint.h' 'stdio.h' \
      'stdio_ext.h' 'stdlib.h' 'string.h' 'strings.h' 'sys' 'syscall.h' \
      'sysexits.h' 'syslog.h' 'tar.h' 'termio.h' 'termios.h' 'tgmath.h' \
      'thread_db.h' 'threads.h' 'time.h' 'ttyent.h' 'uchar.h' \
      'ucontext.h' 'ulimit.h' 'unistd.h' 'utime.h' 'utmp.h' 'utmpx.h' \
      'values.h' 'video' 'wait.h' 'wchar.h' 'wctype.h' 'wordexp.h' 'xen'

    map_source_target() {
      source_target="$1"
      case "$source_target" in
        "$root/lib64/"*)
          printf '%s\n' "$out/lib64/''${source_target#"$root/lib64/"}"
          ;;
        "$root/usr/lib64/"*)
          target_name="''${source_target#"$root/usr/lib64/"}"
          if test -e "$static/lib64/$target_name" || test -L "$static/lib64/$target_name"; then
            printf '%s\n' "$static/lib64/$target_name"
          elif test -e "$dev/lib64/$target_name" || test -L "$dev/lib64/$target_name"; then
            printf '%s\n' "$dev/lib64/$target_name"
          elif test -e "$out/lib64/$target_name" || test -L "$out/lib64/$target_name"; then
            printf '%s\n' "$out/lib64/$target_name"
          else
            echo "manylinux-2-28-sysroot: symlink target was not selected: $source_target" >&2
            return 1
          fi
          ;;
        "$root/usr/include/"*)
          printf '%s\n' "$dev/include/''${source_target#"$root/usr/include/"}"
          ;;
        *)
          echo "manylinux-2-28-sysroot: symlink escapes libc interface: $source_target" >&2
          return 1
          ;;
      esac
    }

    normalize_symlinks() {
      output_root="$1"
      source_root="$2"
      while IFS= read -r -d $'\0' output_link; do
        relative_path="''${output_link#"$output_root/"}"
        source_link="$source_root/$relative_path"
        test -L "$source_link"
        source_target="$(realpath -m "$(dirname "$source_link")/$(readlink "$source_link")")"
        mapped_target="$(map_source_target "$source_target")"
        test -e "$mapped_target" || test -L "$mapped_target"
        rm "$output_link"
        ln -s "$mapped_target" "$output_link"
      done < <(find "$output_root" -type l -print0)
    }

    phase=normalize-runtime-symlinks
    normalize_symlinks "$out/lib64" "$root/lib64"
    phase=normalize-development-symlinks
    normalize_symlinks "$dev/lib64" "$root/usr/lib64"
    phase=normalize-static-symlinks
    normalize_symlinks "$static/lib64" "$root/usr/lib64"
    phase=normalize-header-symlinks
    normalize_symlinks "$dev/include" "$root/usr/include"

    # Make the target files named by GNU ld scripts available through the
    # development search directory. The scripts can then contain relocatable
    # basenames rather than image-root or Nix-store absolute paths.
    phase=link-development-targets
    for target in "$out/lib64"/* "$static/lib64"/*; do
      test -e "$target" || test -L "$target" || continue
      target_name="''${target##*/}"
      if ! test -e "$dev/lib64/$target_name" && ! test -L "$dev/lib64/$target_name"; then
        ln -s "$target" "$dev/lib64/$target_name"
      fi
    done

    # Development .so files are GNU ld scripts. Redirect their target-runtime
    # and nonshared/static members to the safe symlinks above.
    phase=rewrite-linker-scripts
    for script in "$dev/lib64"/*.so; do
      test -e "$script" || test -L "$script" || continue
      test -L "$script" && continue
      grep -Eq '(^|[[:space:]])(GROUP|INPUT)[[:space:]]*\(' "$script" || {
        echo "manylinux-2-28-sysroot: unexpected non-script development file: $script" >&2
        exit 1
      }
      sed -i \
        -e 's#/usr/lib64/##g' \
        -e 's#/lib64/##g' \
        -e 's#/lib/##g' \
        "$script"
    done

    phase=assert-features-header
    test -s "$dev/include/features.h"
    phase=assert-glibc-major
    grep -Eq '^#[[:space:]]*define[[:space:]]+__GLIBC__[[:space:]]+2([[:space:]]|$)' \
      "$dev/include/features.h"
    phase=assert-glibc-minor
    grep -Eq '^#[[:space:]]*define[[:space:]]+__GLIBC_MINOR__[[:space:]]+28([[:space:]]|$)' \
      "$dev/include/features.h"
    phase=assert-crt1
    test -s "$dev/lib64/crt1.o"
    phase=assert-crti
    test -s "$dev/lib64/crti.o"
    phase=assert-crtn
    test -s "$dev/lib64/crtn.o"
    phase=assert-libc-nonshared
    test -s "$static/lib64/libc_nonshared.a"
    phase=assert-loader
    test -e "$out/lib64/${expectedLoader}"

    phase=audit-linker-script-host-paths
    for script in "$dev/lib64"/*.so; do
      test -f "$script" || continue
      test -L "$script" && continue
      if grep -H '/usr/lib64\|/lib64\|/lib/' "$script"; then
        echo 'manylinux-2-28-sysroot: development linker script retains an image-root path' >&2
        exit 1
      fi
    done

    phase=audit-linker-script-targets
    for script in "$dev/lib64"/*.so; do
      test -f "$script" || continue
      test -L "$script" && continue
      script_targets="$(grep -Eo '[[:alnum:]_+.-]+\.(so(\.[0-9.]+)?|a)' "$script" || true)"
      while IFS= read -r target; do
        test -n "$target" || continue
        test -e "$dev/lib64/$target" || {
          echo "manylinux-2-28-sysroot: linker script target is absent: $target" >&2
          exit 1
        }
      done <<< "$script_targets"
    done

    phase=audit-output-symlinks
    for output_root in "$out" "$dev" "$static"; do
      while IFS= read -r -d $'\0' link; do
        target="$(readlink "$link")"
        case "$target" in
          /*) resolved="$target" ;;
          *) resolved="$(realpath -m "$(dirname "$link")/$target")" ;;
        esac
        case "$resolved" in
          "$out"/*|"$dev"/*|"$static"/*) ;;
          *)
            echo "manylinux-2-28-sysroot: output symlink escapes: $link -> $target" >&2
            exit 1
            ;;
        esac
        test -e "$resolved" || {
          echo "manylinux-2-28-sysroot: output symlink is dangling: $link -> $target" >&2
          exit 1
        }
      done < <(find "$output_root" -type l -print0)
    done

    phase=audit-excluded-content
    for excluded_header in \
      X11 EGL GL GLES GLES2 GLES3 KHR c++ glib-2.0 gio-unix-2.0 \
      openssl python3 valgrind xcb zlib.h; do
      test ! -e "$dev/include/$excluded_header"
    done
    test -z "$(find "$out" "$dev" "$static" \
      \( -path '*/var/lib/rpm' -o -path '*/usr/share/locale' \) -print -quit)"

    phase=write-provenance
    printf '%s\n' '${lock.imageDigest}' > "$dev/nix-support/image-digest"
    : > "$dev/nix-support/sysroot-files"
    {
      for output_name in out dev static; do
        case "$output_name" in
          out) output_root="$out" ;;
          dev) output_root="$dev" ;;
          static) output_root="$static" ;;
        esac
        find "$output_root" -mindepth 1 -printf "$output_name/%P\n"
      done
    } | LC_ALL=C sort > "$TMPDIR/sysroot-files"
    mv "$TMPDIR/sysroot-files" "$dev/nix-support/sysroot-files"
    phase=complete
  '';
in
assert expectedLoader != "";
assert sysroot.outputs == outputs;
assert sysroot.imageDigest == lock.imageDigest;
assert sysroot.policy == "manylinux_2_28";
assert sysroot.glibcFloor == "2.28";
sysroot
