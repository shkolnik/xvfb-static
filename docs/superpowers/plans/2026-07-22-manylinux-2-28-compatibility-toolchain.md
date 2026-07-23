# manylinux_2_28 Compatibility Toolchain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the external-Vulkan Xvfb alpha with current pinned Xserver and Mesa sources while limiting its imported glibc symbols to `GLIBC_2.28` or older through an explicitly pinned manylinux_2_28 target sysroot.

**Architecture:** Nix remains the source selector, build orchestrator, cache boundary, and package assembler. Native tools continue to come from the current locked Nixpkgs; target C and C++ compilation uses a dedicated Nix `stdenv` composed from Nixpkgs GCC 14/binutils and glibc headers, startup objects, linker scripts, and libraries extracted from digest-pinned official manylinux_2_28 images. The adapter is proved with C/C++ probes and one small static dependency before it is allowed to rebuild Mesa or Xvfb.

**Tech Stack:** Nix flakes and `stdenv`, `dockerTools.pullImage`, Skopeo/umoci, GCC 14, binutils/readelf, official PyPA manylinux_2_28 images, Bash, Docker, Debian 11, Mesa Zink, X.Org Xserver.

## Global Constraints

- Preserve the project name `xvfb-static-glx-external-vulkan-alpha` and the one-executable archive shape.
- Continue selecting Xserver, Mesa, and all application dependency sources from the repository's current `flake.lock` input.
- Use manylinux only as the target libc/sysroot foundation; do not move source builds into ad-hoc shell scripts inside the manylinux container.
- Pin both architecture-specific manylinux images by immutable manifest digest and Nix fixed-output hash.
- Use current locked Nixpkgs packages for native build tools; no manylinux Python, Meson, Ninja, shell, or package manager may enter the target closure.
- Statically incorporate Mesa Zink and ordinary non-glibc dependencies; do not introduce LLVM, llvmpipe, softpipe, or lavapipe into the Xvfb artifact.
- Keep the runtime graphics ABI `libvulkan.so.1`; ordinary host glibc libraries and the ELF loader remain permitted and explicitly audited.
- The toolchain probe must import no symbol newer than `GLIBC_2.28`.
- The production artifact must import no symbol newer than `GLIBC_2.31`, declare Debian 11/glibc 2.31 only after the runtime smoke passes, and record its actual maximum `GLIBC_*` symbol.
- Do not publish the external-Vulkan variant as a release asset; actual-GPU tests on native x86_64 and aarch64 remain a separate release gate.
- Preserve deterministic archive assembly and fail on Nix-store references, RPATH/RUNPATH, LLVM markers, unexpected `DT_NEEDED` entries, missing licenses, or manifest drift.
- Stop the experiment before Mesa if either the C/C++ probe cannot be made clean within the toolchain adapter or the zlib proof requires a package-specific source patch.
- Stop and reconsider option 3 if more than three target-package compatibility patches are needed solely because of the imported sysroot.

---

## File Structure

- `nix/manylinux-2-28-images.json`: reviewed architecture-to-image locks, including repository, immutable manifest digest, and Nix fixed-output hash.
- `nix/manylinux-2-28-images.nix`: validates and exposes one locked image record for a Nix `system`.
- `nix/manylinux-2-28-sysroot.nix`: pulls one locked image, unpacks it reproducibly, and emits glibc `out`, `dev`, and `static` outputs suitable for compiler wrapping.
- `nix/manylinux-2-28-stdenv.nix`: constructs the GCC 14/binutils wrapper and compatibility `stdenv`; it is the only interface target packages consume.
- `nix/manylinux-2-28-packages.nix`: imports the current locked Nixpkgs with the compatibility `stdenv` for target libraries while preserving a normal native package set.
- `scripts/update-manylinux-2-28-lock.sh`: resolves reviewed upstream tags to immutable digests and fixed-output hashes; it never changes locks implicitly during a build.
- `test/manylinux-2-28-probe.c`: exercises libc, libm, libdl, pthreads, and stat-family interfaces.
- `test/manylinux-2-28-probe.cc`: exercises the statically incorporated C++ runtime and exceptions.
- `test/manylinux-2-28-toolchain.nix`: builds and audits the fast C/C++ probe and the zlib closure proof.
- `test/manylinux-2-28-toolchain.sh`: runs both probes on Debian 11 and Ubuntu 24.04 after Nix-level ELF audits pass.
- `mesa-zink.nix`: accepts the prepared target/native package sets instead of independently importing a second current-glibc target set.
- `package-glx-external-vulkan.nix`: consumes the compatibility package set and strengthens the production ABI/provenance gates.
- `test/glx-external-vulkan-smoke.sh`: enforces the supported glibc floor on Debian 11 and executes loader, ICD, and render/readback cases with a newer Mesa runtime.
- `flake.nix`: exposes the fast compatibility-toolchain checks and the existing two production packages.
- `.github/workflows/ci.yml`: runs the fast toolchain proof before the expensive external-Vulkan archive build.
- `.github/dependabot.yml`: remains the weekly Nix-input updater; no unsupported claim that it supplies manylinux security alerts is added.
- `README.md`, `AGENTS.md`, and `THIRD-PARTY-NOTICES.md`: document the build/runtime distinction, locks, update procedure, and toolchain attribution.

### Task 1: Lock and Validate the Official Images

**Files:**
- Create: `nix/manylinux-2-28-images.json`
- Create: `nix/manylinux-2-28-images.nix`
- Create: `scripts/update-manylinux-2-28-lock.sh`
- Test: `nix/manylinux-2-28-images.nix`

**Interfaces:**
- Consumes: official tags `quay.io/pypa/manylinux_2_28_x86_64:latest` and `quay.io/pypa/manylinux_2_28_aarch64:latest` during an explicit maintainer update only.
- Produces: `import ./manylinux-2-28-images.nix { inherit system; }`, returning `{ imageName, imageDigest, sha256, policy, glibcFloor }`.

- [ ] **Step 1: Write the failing lock evaluator**

Create `nix/manylinux-2-28-images.nix` with validation that deliberately fails until the JSON lock exists:

```nix
{ system }:
let
  locks = builtins.fromJSON (builtins.readFile ./manylinux-2-28-images.json);
  lock = locks.${system} or (throw "manylinux_2_28: unsupported system ${system}");
  digestPattern = "sha256:[0-9a-f]{64}";
in
assert lock.policy == "manylinux_2_28";
assert lock.glibcFloor == "2.28";
assert builtins.match digestPattern lock.imageDigest != null;
assert builtins.match "sha256-[A-Za-z0-9+/]{43}=" lock.sha256 != null;
assert builtins.match ".*:latest" lock.imageName == null;
lock
```

- [ ] **Step 2: Run the evaluator to verify it fails**

Run:

```bash
docker run --rm --platform linux/arm64 \
  -v "$PWD":/src -v xvfb-static-nix:/nix -w /src \
  -e NIX_CONFIG='experimental-features = nix-command flakes' \
  nixos/nix@sha256:22c0a3a816eb3d315eb6720d2a58a3c3b622c9717c578f3c80b687668c6da277 \
  nix eval --impure --json --expr \
  'import /src/nix/manylinux-2-28-images.nix { system = "aarch64-linux"; }'
```

Expected: evaluation fails because `nix/manylinux-2-28-images.json` does not exist.

- [ ] **Step 3: Add the explicit lock updater**

Create `scripts/update-manylinux-2-28-lock.sh`. It must use `docker buildx imagetools inspect` to resolve the current manifest digest, then run the locked Nixpkgs `nix-prefetch-docker` for each architecture and emit the complete JSON document to standard output. It must not overwrite the lock automatically. The architecture table is:

```bash
case "$arch" in
  x86_64-linux) image=quay.io/pypa/manylinux_2_28_x86_64 ;;
  aarch64-linux) image=quay.io/pypa/manylinux_2_28_aarch64 ;;
  *) echo "unsupported system: $arch" >&2; exit 2 ;;
esac
```

The emitted records must store the repository-only `imageName`, for example `quay.io/pypa/manylinux_2_28_aarch64`, and retain the immutable `imageDigest` as a separate required field. Builds always pass both values to `dockerTools.pullImage`; they never resolve `latest`. Use `jq -n` to generate JSON rather than string interpolation.

- [ ] **Step 4: Generate and review the initial fixed-output hashes**

Run:

```bash
./scripts/update-manylinux-2-28-lock.sh > /tmp/manylinux-2-28-images.json
jq . /tmp/manylinux-2-28-images.json
```

Confirm the resolved immutable manifest digests begin as follows before accepting any newer reviewed upstream rebuild:

```text
x86_64-linux: sha256:a61875a2f84cab7df8de222ff12cabc08ff86eb4ad402ac90ba7bdaed9600cca
aarch64-linux: sha256:162c81dfd3efc710732a571717d3c916a6945ebf279e879ddee3243af96fe46f
```

Copy the reviewed JSON to `nix/manylinux-2-28-images.json` with `apply_patch`.

- [ ] **Step 5: Verify both locks evaluate**

Run the Step 2 command once for `aarch64-linux` and once for `x86_64-linux`.

Expected: each emits one record with `policy = "manylinux_2_28"`, `glibcFloor = "2.28"`, an immutable image name, and valid hashes.

- [ ] **Step 6: Commit the image locks**

```bash
git add nix/manylinux-2-28-images.json nix/manylinux-2-28-images.nix scripts/update-manylinux-2-28-lock.sh
git commit -m "Pin manylinux 2.28 compatibility images"
```

### Task 2: Extract a Minimal, Auditable glibc Sysroot

**Files:**
- Create: `nix/manylinux-2-28-sysroot.nix`
- Create: `patches/umoci-0001-rootless-mask-privileged-mode-bits.patch`
- Create: `test/manylinux-2-28-umoci-fixture.nix`
- Test: `nix/manylinux-2-28-sysroot.nix`

**Interfaces:**
- Consumes: the validated image record from Task 1 and `hostPkgs` from current locked Nixpkgs.
- Produces: a derivation with `out`, `dev`, and `static` outputs containing target shared objects/loader, headers/startup objects/linker scripts, and static/nonshared archives respectively; exposes `passthru.imageDigest`, `passthru.policy`, and `passthru.glibcFloor`.

- [ ] **Step 1: Write an evaluation test for the output contract**

Add an `assert` block at the bottom of the new expression so evaluation requires all three output names and the `2.28` policy metadata. Initially return `throw "sysroot not implemented"` after the assertions are declared.

- [ ] **Step 2: Verify the expression fails before implementation**

Run:

```bash
nix build --impure --no-link --file nix/manylinux-2-28-sysroot.nix \
  --argstr system aarch64-linux
```

Expected: failure containing `sysroot not implemented`.

- [ ] **Step 3: Pull and unpack the pinned image inside Nix**

Implement the fixed input with:

```nix
image = hostPkgs.dockerTools.pullImage {
  imageName = lock.imageName;
  imageDigest = lock.imageDigest;
  sha256 = lock.sha256;
  finalImageName = lock.imageName;
  finalImageTag = "locked";
};
```

Use `hostPkgs.runCommand` with `hostPkgs.skopeo`, `hostPkgs.umoci`, `hostPkgs.gnutar`, and `hostPkgs.patchelf` as native inputs. Convert the Docker archive to an OCI layout with `skopeo copy docker-archive:${image} oci:$TMPDIR/image:locked`, then unpack it with `umoci unpack --image $TMPDIR/image:locked $TMPDIR/unpacked`.

**Approved implementation deviation (2026-07-22):** pinned umoci 0.6.0
unconditionally replays setuid/setgid bits even in rootless mode, while Nix's
builder syscall filter correctly rejects those `chmod` operations. Override
only the native umoci build with a reviewable patch that masks
`os.ModeSetuid | os.ModeSetgid` immediately before `fsEval.Chmod` and only
when `te.onDiskFmt.Map().Rootless` is true. Non-rootless behavior, ordinary
permission bits, sticky bits, symlink handling, whiteout handling, layer
verification, and target-package provenance must remain unchanged. Run umoci
with `--rootless`; do not disable the Nix syscall filter or use fakeroot,
ptrace-based wrappers, privileged extraction, or custom layer application.

Before the complete image extraction, build a small two-layer OCI fixture that
contains ordinary `0755`, setuid `04755`, setgid `02755`, a relative symlink,
a plain whiteout, and an opaque whiteout. Prove the patched rootless unpack
produces `0755` for all three regular modes, preserves the symlink, and applies
both whiteout forms correctly. Also prove the mode-selection unit leaves
non-rootless `04755`/`02755` unchanged. If another privileged metadata operation
requires a second umoci behavior patch, stop and reassess instead of extending
the workaround.

- [ ] **Step 4: Split only the target libc interface into Nix outputs**

Copy from `$TMPDIR/unpacked/rootfs` while preserving modes and symlinks:

```text
$out/lib64/                 loader and glibc shared objects
$dev/include/               /usr/include
$dev/lib64/                 crt*.o and development linker scripts/symlinks
$static/lib64/              libc_nonshared.a and available libc/libm/pthread/dl/rt archives
```

Reject absolute symlinks that resolve outside these outputs. Rewrite GNU ld scripts such as `libc.so` and `libpthread.so` so their `GROUP()`/`INPUT()` entries point to the corresponding `$out`, `$dev`, and `$static` files instead of `/lib64` or `/usr/lib64`. Do not copy Python, OpenSSL, RPM databases, locale trees, package-manager state, or unrelated shared libraries.

- [ ] **Step 5: Add build-time sysroot assertions**

The derivation must fail unless all of these hold:

```bash
test -s "$dev/include/features.h"
grep -q 'define __GLIBC__ 2' "$dev/include/features.h"
grep -q 'define __GLIBC_MINOR__ 28' "$dev/include/features.h"
test -s "$dev/lib64/crt1.o"
test -s "$dev/lib64/crti.o"
test -s "$dev/lib64/crtn.o"
test -s "$static/lib64/libc_nonshared.a"
test -e "$out/lib64/ld-linux-x86-64.so.2" -o \
     -e "$out/lib64/ld-linux-aarch64.so.1"
! grep -R '/usr/lib64\|/lib64' "$dev/lib64" --include='*.so'
```

Write an inventory to `$dev/nix-support/sysroot-files` using `LC_ALL=C find ... | sort` and include the originating image digest in `$dev/nix-support/image-digest`.

- [ ] **Step 6: Build and inspect the sysroot for both architectures**

Run natively on each matching runner/container:

```bash
nix build --impure --no-link --print-out-paths \
  --file nix/manylinux-2-28-sysroot.nix --argstr system "$(uname -m | sed 's/arm64/aarch64/; s/$/-linux/')"
```

Expected: three output paths and no copied file outside the declared libc interface.

- [ ] **Step 7: Commit the sysroot extractor**

```bash
git add nix/manylinux-2-28-sysroot.nix \
  patches/umoci-0001-rootless-mask-privileged-mode-bits.patch \
  test/manylinux-2-28-umoci-fixture.nix
git commit -m "Extract manylinux 2.28 target sysroot"
```

### Task 3: Prove the Compatibility stdenv with C and C++

**Files:**
- Create: `nix/manylinux-2-28-stdenv.nix`
- Create: `test/manylinux-2-28-probe.c`
- Create: `test/manylinux-2-28-probe.cc`
- Create: `test/manylinux-2-28-toolchain.nix`
- Create: `test/manylinux-2-28-toolchain.sh`

**Interfaces:**
- Consumes: `{ system, hostPkgs }` and the sysroot outputs from Task 2.
- Produces: `{ stdenv, cc, libc, sysroot, glibcFloor = "2.28"; }`; the shell test accepts an optional Nix output path and otherwise builds `test/manylinux-2-28-toolchain.nix`.

- [ ] **Step 1: Write C and C++ probes**

The C probe must call `dlopen`, `pthread_create`/`pthread_join`, `stat`, and `hypot`, print `gnu_get_libc_version()`, and return nonzero if the thread result is wrong. The C++ probe must construct a `std::vector<std::string>`, throw and catch `std::runtime_error`, and print `c++ probe passed`. Keep both programs filesystem- and network-independent.

- [ ] **Step 2: Write the failing shell test**

`test/manylinux-2-28-toolchain.sh` must:

1. Build `test/manylinux-2-28-toolchain.nix`.
2. Use `readelf --version-info` to compute the maximum `GLIBC_*` version of each executable.
3. Fail if either maximum exceeds `2.28`.
4. Fail on RPATH/RUNPATH, a `/nix/store` string, or `DT_NEEDED` outside `libc.so.6`, `libdl.so.2`, `libm.so.6`, `libpthread.so.0`, `librt.so.1`, and the architecture loader after static libgcc/libstdc++ linking.
5. Run both probes in `debian:11-slim` and `ubuntu:24.04` without installing runtime packages.

- [ ] **Step 3: Run the test to verify it fails**

Run:

```bash
./test/manylinux-2-28-toolchain.sh
```

Expected: failure because `nix/manylinux-2-28-stdenv.nix` or the probe derivation is not implemented.

- [ ] **Step 4: Construct the wrapped compiler**

In `nix/manylinux-2-28-stdenv.nix`, use current locked Nixpkgs GCC 14 as a native compiler executable but replace its target libc and bintools search configuration:

```nix
wrappedBintools = hostPkgs.wrapBintoolsWith {
  bintools = hostPkgs.binutils;
  libc = sysroot;
};
wrappedCC = hostPkgs.wrapCCWith {
  cc = hostPkgs.gcc14.cc;
  bintools = wrappedBintools;
  libc = sysroot;
};
compatStdenv = hostPkgs.overrideCC hostPkgs.stdenv wrappedCC;
```

If `wrapCCWith` requires separate output paths, pass the Task 2 derivation as one multi-output libc package rather than adding raw `-I`/`-L` flags in individual packages. Do not set ambient `LD_LIBRARY_PATH`.

- [ ] **Step 5: Build and audit both probes in Nix**

Compile C with `-pthread -ldl -lm` and C++ with `-static-libgcc -static-libstdc++`. In the derivation's install check, compute the maximum version and use `sort -V -C` against `2.28`; print every offending dynamic symbol before failing.

- [ ] **Step 6: Run the complete probe test**

Run:

```bash
bash -n test/manylinux-2-28-toolchain.sh
./test/manylinux-2-28-toolchain.sh
```

Expected output includes:

```text
manylinux_2_28 C probe passed on Debian 11
manylinux_2_28 C++ probe passed on Debian 11
manylinux_2_28 C probe passed on Ubuntu 24.04
manylinux_2_28 C++ probe passed on Ubuntu 24.04
maximum imported glibc symbol: GLIBC_2.28 or older
```

**Mandatory stop condition:** if this requires modifying probe source to avoid ordinary supported libc interfaces, globally disabling Nix hardening, retaining Nix glibc in the linker search path, or patching files outside the adapter, stop the experiment and report the exact failure.

- [ ] **Step 7: Commit the proved toolchain adapter**

```bash
git add nix/manylinux-2-28-stdenv.nix test/manylinux-2-28-probe.c \
  test/manylinux-2-28-probe.cc test/manylinux-2-28-toolchain.nix \
  test/manylinux-2-28-toolchain.sh
git commit -m "Prove manylinux 2.28 Nix toolchain"
```

### Task 4: Prove a Rebuilt Static Dependency

**Files:**
- Create: `nix/manylinux-2-28-packages.nix`
- Modify: `test/manylinux-2-28-toolchain.nix`
- Modify: `test/manylinux-2-28-toolchain.sh`

**Interfaces:**
- Consumes: the compatibility stdenv from Task 3 and the repository's current `flake.lock` Nixpkgs source.
- Produces: `{ targetPkgs, hostPkgs, toolchain }`; a zlib-linked probe proves target dependencies are rebuilt rather than borrowed from the glibc-2.42 package set.

- [ ] **Step 1: Add a failing zlib closure test**

Extend the C probe with a separately built executable that calls `zlibVersion()` and performs a `compress2`/`uncompress` round trip. The test must import `nix/manylinux-2-28-packages.nix`, link `${targetPkgs.zlib.static}/lib/libz.a` explicitly, retain only glibc-related `DT_NEEDED` entries, and inspect the zlib build log to confirm that the compatibility compiler wrapper supplied its libc search paths.

- [ ] **Step 2: Verify the test fails before the compatibility package set exists**

Run `./test/manylinux-2-28-toolchain.sh` before creating `nix/manylinux-2-28-packages.nix`.

Expected: evaluation fails because the required `targetPkgs` interface does not exist. Do not manufacture a red test by assuming a static archive must retain a glibc reference: symbol versions are normally assigned when the final executable is linked.

- [ ] **Step 3: Import the compatibility target package set**

Implement `nix/manylinux-2-28-packages.nix` so `hostPkgs` is the ordinary current package set and `targetPkgs` is imported from the same locked Nixpkgs source with `config.replaceStdenv = _pkgs: toolchain.stdenv`. Keep native build tools explicit through `hostPkgs` and do not recursively rebuild Meson/Python under the target stdenv.

- [ ] **Step 4: Run the zlib proof**

Run:

```bash
./test/manylinux-2-28-toolchain.sh
```

Expected: C, C++, and zlib probes pass on Debian 11 and Ubuntu 24.04 with maximum imported symbol at or below 2.28.

**Mandatory stop condition:** if unmodified zlib cannot build with the compatibility package set or needs a source/build-system patch specific to the sysroot, stop before Mesa and compare option 3 using the collected compiler/linker evidence.

- [ ] **Step 5: Commit the package-set proof**

```bash
git add nix/manylinux-2-28-packages.nix test/manylinux-2-28-toolchain.nix \
  test/manylinux-2-28-toolchain.sh test/manylinux-2-28-probe.c
git commit -m "Rebuild target libraries with manylinux sysroot"
```

### Task 5: Move Mesa Zink onto the Compatibility Package Set

**Files:**
- Modify: `mesa-zink.nix`
- Modify: `package-glx-external-vulkan.nix`
- Test: `mesa-zink.nix`

**Interfaces:**
- Consumes: `targetPkgs`, `hostPkgs`, and `toolchain` from `nix/manylinux-2-28-packages.nix`.
- Produces: the existing static Mesa/Zink outputs compiled against the manylinux target sysroot, still with LLVM and all software renderers disabled.

- [ ] **Step 1: Add a failing Mesa ABI/provenance assertion**

Add a small link-only probe to `test/manylinux-2-28-toolchain.nix` that links the installed static GL/GLX and Gallium archives through the compatibility stdenv. Inspect that resulting ELF for `GLIBC_2.29` or newer. Separately scan the installed Mesa output for `/nix/store/...glibc-2.42`, `libLLVM`, `LLVM_[0-9]`, `llvmpipe`, or `softpipe`, printing the matching file and string before failing. Do not claim that unlinked archive members carry final glibc symbol versions.

- [ ] **Step 2: Verify current Mesa fails the new assertion**

Run:

```bash
nix build --impure --no-link --file mesa-zink.nix
```

Expected: evaluation or linking fails because Mesa has not yet been parameterized to consume the compatibility target package set, or the linked probe exposes a post-2.28 dependency.

- [ ] **Step 3: Parameterize Mesa's package sets**

Change the expression interface to:

```nix
{ system ? builtins.currentSystem
, targetPkgs ? null
, hostPkgs ? null
}:
```

When either is null, obtain both through `nix/manylinux-2-28-packages.nix`. Replace target references from the locally imported `pkgs` with `targetPkgs`; resolve Meson, Ninja, Python, pkg-config, CMake, and patch utilities from `hostPkgs` through `nativeBuildInputs` or Nixpkgs' dependency splicing. Preserve the existing Zink-only, LLVM-disabled Mesa overrides and patches exactly.

- [ ] **Step 4: Build Mesa natively on aarch64**

Run:

```bash
nix build --impure --no-link --print-out-paths --max-jobs 1 --cores 8 \
  --file mesa-zink.nix --argstr system aarch64-linux
```

Expected: the static Mesa outputs build, the new ABI/provenance assertions pass, and the log contains no target build of Python, Meson, Ninja, or CMake.

- [ ] **Step 5: Inspect Mesa's closure**

Run `nix-store --query --requisites` on the output and classify each path as native-build-only, target static input, or output. Fail the task if LLVM appears anywhere in the target/output references; a native-only LLVM path is also unexpected and must be traced before proceeding.

**Mandatory stop condition:** count compatibility-only patches outside `nix/manylinux-2-28-*.nix`. If the count exceeds three, stop and present option 3 rather than continuing incremental package patches.

- [ ] **Step 6: Commit the Mesa migration**

```bash
git add mesa-zink.nix package-glx-external-vulkan.nix
git commit -m "Build Zink with manylinux compatibility toolchain"
```

### Task 6: Build and Audit Xvfb at the Product Boundary

**Files:**
- Modify: `package-glx-external-vulkan.nix`
- Modify: `flake.nix`
- Modify: `test/glx-external-vulkan-smoke.sh`

**Interfaces:**
- Consumes: compatibility-built Mesa and target libraries plus current native keymap/build tools.
- Produces: the existing external-Vulkan archive contract with actual `glibc_symbol_floor`, supported `minimum_host_glibc = "2.31"`, and manylinux image/toolchain provenance.

- [ ] **Step 1: Make release-floor mode fail against the current artifact**

Run:

```bash
XVFB_STATIC_REQUIRE_GLIBC_231=1 \
  ./test/glx-external-vulkan-smoke.sh \
  out/glx-external-vulkan-alpha/aarch64/xvfb-static-glx-external-vulkan-alpha-linux-aarch64.tar.gz
```

Expected: failure reporting the current maximum `GLIBC_2.38` symbol.

- [ ] **Step 2: Move all target dependencies to `targetPkgs`**

Import `nix/manylinux-2-28-packages.nix` once in `package-glx-external-vulkan.nix`. Use `targetPkgs` for Xserver and every library incorporated into Xvfb; use `hostPkgs` for `xkbcomp`, XKB data generation, archive/license tooling, strip/readelf, Meson, Python, and other executables run during the build. Preserve the static-library adapter and all existing external-Vulkan patches.

- [ ] **Step 3: Strengthen the final ELF gate**

After stripping, interpreter normalization, RPATH removal, and `nuke-refs`, collect offending imports with:

```bash
newer_symbols="$(readelf --dyn-syms -W "$out/bin/Xvfb" |
  awk '/@GLIBC_/ { print $8 }' |
  sed -n 's/.*@GLIBC_\([0-9][0-9.]*\).*/\1 &/p' |
  while read -r version symbol; do
    newest="$(printf '%s\n' "$version" 2.31 | sort -V | tail -n 1)"
    test "$newest" = 2.31 || printf '%s\n' "$symbol"
  done)"
test -z "$newer_symbols" || {
  echo 'xvfb-static: external Vulkan binary exceeds GLIBC_2.31:' >&2
  printf '%s\n' "$newer_symbols" >&2
  exit 1
}
```

Retain the actual maximum symbol calculation independently; do not hard-code `glibc_symbol_floor` to 2.28 or 2.31.

- [ ] **Step 4: Record support and build provenance**

Add these manifest fields only after the final gate passes:

```json
{
  "minimum_host_glibc": "2.31",
  "target_abi_policy": "manylinux_2_28",
  "toolchain": {
    "manylinux_image_digest": "architecture-specific locked digest",
    "glibc_headers": "2.28",
    "compiler": "gcc-14"
  }
}
```

Continue recording `glibc_symbol_floor` from the produced ELF. Update the smoke-test schema checks to require these fields and compare the manifest digest to the architecture's source lock.

- [ ] **Step 5: Build the complete aarch64 package and archive**

Run:

```bash
./build-glx-external-vulkan.sh aarch64
```

Expected: archive creation succeeds, manifest reports `minimum_host_glibc: 2.31`, actual symbol floor is at most 2.31, and the artifact contains no LLVM or Nix-store references.

- [ ] **Step 6: Run structural and Debian 11 runtime smoke tests**

Build `test/glx-render.nix`, then run:

```bash
XVFB_STATIC_REQUIRE_GLIBC_231=1 \
  ./test/glx-external-vulkan-smoke.sh \
  out/glx-external-vulkan-alpha/aarch64/xvfb-static-glx-external-vulkan-alpha-linux-aarch64.tar.gz \
  result-glx-render-test/bin/glx-render-test
```

Expected: missing-loader and missing-ICD cases fail with clear Vulkan/Zink diagnostics on Debian 11; a newer lavapipe runtime completes pixel render/readback; the test explicitly states that this software ICD is integration coverage and not the actual-GPU release gate.

- [ ] **Step 7: Commit the product integration**

```bash
git add package-glx-external-vulkan.nix flake.nix test/glx-external-vulkan-smoke.sh
git commit -m "Target Debian 11 ABI for external Vulkan Xvfb"
```

### Task 7: Put the Fast Gate Before the Expensive CI Build

**Files:**
- Modify: `flake.nix`
- Modify: `.github/workflows/ci.yml`
- Test: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `test/manylinux-2-28-toolchain.nix` and both architecture locks.
- Produces: per-architecture CI ordering in which the fast ABI probe must pass before Mesa compilation starts.

- [ ] **Step 1: Expose the toolchain proof as flake checks**

Add `checks.x86_64-linux.manylinux-2-28-toolchain` and `checks.aarch64-linux.manylinux-2-28-toolchain`, each importing `test/manylinux-2-28-toolchain.nix` with the matching system.

- [ ] **Step 2: Verify both check names evaluate**

Run:

```bash
nix flake show --impure
```

Expected: both new checks are visible alongside the keyboard-profile checks.

- [ ] **Step 3: Add an early CI step**

In each `glx-external-vulkan` matrix job, run the matching flake check and `test/manylinux-2-28-toolchain.sh` before `Build GLX external Vulkan alpha archive`. Retain `--option log-lines 200`; do not enable full Nix trace logging.

- [ ] **Step 4: Validate workflow and shell syntax**

Run:

```bash
bash -n scripts/update-manylinux-2-28-lock.sh \
  test/manylinux-2-28-toolchain.sh \
  test/glx-external-vulkan-smoke.sh
git diff --check
```

Expected: all commands exit zero.

- [ ] **Step 5: Commit the early CI gate**

```bash
git add flake.nix .github/workflows/ci.yml
git commit -m "Gate Vulkan build on compatibility toolchain"
```

### Task 8: Document Ownership, Updates, and Attribution

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `THIRD-PARTY-NOTICES.md`
- Modify: `package-glx-external-vulkan.nix`

**Interfaces:**
- Consumes: proved image digests, actual symbol floor, and final license closure.
- Produces: accurate user contract and maintainer update procedure; package licenses include any startup/nonshared objects incorporated from the manylinux/Alma glibc toolchain.

- [ ] **Step 1: Audit incorporated toolchain bytes**

Generate a linker map for the final Xvfb link in a diagnostic build and identify objects selected from `crt*.o`, `libc_nonshared.a`, libgcc, and libstdc++. Map each selected object to its manylinux/Alma or Nix source package and license. Do not infer this solely from `DT_NEEDED`.

- [ ] **Step 2: Extend license extraction where the audit requires it**

Extract the corresponding glibc/GCC license and notice texts from exact pinned source packages. Keep host Vulkan loader and ICD licenses documented as runtime-only and not redistributed. Make missing or ambiguous texts fail the package build.

- [ ] **Step 3: Update public compatibility language**

Document that the artifact is built to a manylinux_2_28 ABI foundation but officially supports glibc 2.31 and newer after Debian 11 runtime verification. State that it uses the host's patched glibc and does not bundle a private glibc runtime.

- [ ] **Step 4: Correct the Dependabot guidance**

Update `AGENTS.md` to state that `.github/dependabot.yml` checks Nix flake inputs weekly, but GitHub's Nix support supplies version updates rather than vulnerability alerts and does not automatically maintain the OCI digest stored in the manylinux lock. Document `scripts/update-manylinux-2-28-lock.sh` as a review tool, not an auto-merge path.

- [ ] **Step 5: Document the update checklist**

Require maintainers updating either image digest to rerun both architecture probes, both full builds, symbol audits, Debian 11 smoke tests, closure/license review, and reproducibility comparison. Never update only one architecture silently.

- [ ] **Step 6: Commit documentation and attribution**

```bash
git add README.md AGENTS.md THIRD-PARTY-NOTICES.md package-glx-external-vulkan.nix
git commit -m "Document manylinux Vulkan compatibility policy"
```

### Task 9: Two-Architecture Verification and Experiment Decision

**Files:**
- Modify only if evidence requires corrections: files introduced or changed in Tasks 1-8.
- Record build evidence in the pull request description, not as generated repository files.

**Interfaces:**
- Consumes: completed source branch and native x86_64/aarch64 runners.
- Produces: evidence to retain option 2 or an explicit stop report recommending option 3.

- [ ] **Step 1: Run all fast checks on both architectures**

For each native architecture:

```bash
nix flake check --impure --print-build-logs
./test/manylinux-2-28-toolchain.sh
```

Expected: all probes pass and report maximum `GLIBC_2.28` or older.

- [ ] **Step 2: Build each archive from the pinned environment**

Run on matching native runners:

```bash
./build-glx-external-vulkan.sh x86_64
./build-glx-external-vulkan.sh aarch64
```

Expected: both archives build; do not describe either architecture as runtime-verified on the other architecture.

- [ ] **Step 3: Run the full smoke test natively**

For each archive, build the matching render client and run `test/glx-external-vulkan-smoke.sh` with `XVFB_STATIC_REQUIRE_GLIBC_231=1`.

Expected: Debian 11 structural ABI and failure checks pass, and the newer-Mesa Zink/lavapipe readback passes separately.

- [ ] **Step 4: Compare artifact and closure properties**

Record for each architecture:

- archive and binary byte size;
- maximum `GLIBC_*` import;
- exact `DT_NEEDED` set;
- absence of LLVM/software-renderer markers;
- manylinux image digest;
- Xserver and Mesa versions;
- complete license inventory.

Compare binary size to the llvmpipe artifact and confirm the external-Vulkan variant remains substantially smaller without claiming a fixed ratio.

- [ ] **Step 5: Prove archive reproducibility**

Build each architecture twice from clean output directories with the same source commit and locked inputs, then run `sha256sum` and `cmp` on matching archives.

Expected: byte-identical archives for each architecture. If not, identify the first differing packaged file before changing source.

- [ ] **Step 6: Apply the experiment decision rule**

Retain option 2 only if:

- the compatibility logic remains confined to the four `nix/manylinux-2-28-*` files plus package-set plumbing;
- zlib required no source patch;
- no more than three target-package patches were introduced solely for sysroot compatibility;
- both native builds and Debian 11 tests pass;
- provenance and license mapping covers every incorporated toolchain object.

Otherwise stop the branch and write a concise option-3 proposal using the exact failures collected here. Do not weaken the ABI audit or silently raise the floor to make option 2 pass.

- [ ] **Step 7: Run final source checks**

```bash
bash -n build-glx-external-vulkan.sh \
  scripts/update-manylinux-2-28-lock.sh \
  test/manylinux-2-28-toolchain.sh \
  test/glx-external-vulkan-smoke.sh
git diff --check
git status --short
```

Expected: syntax and whitespace checks pass; status contains only intentionally uncommitted evidence, if any.
