# Bounded GCC Compiler Stage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` to implement this plan task by
> task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild GCC 14.3.0's C++ target runtime against the extracted
manylinux 2.28 sysroot by using a transient, strictly bounded GCC compiler
stage, then prove the C++ probe runs on Debian 11.

**Architecture:** The existing runtime derivation creates `xgcc` only in its
private build directory via `all-gcc`. It then builds only libgcc and
libstdc++ target runtimes and installs exactly six archive/startfile outputs.
The compatibility compiler wrapper, not individual probes, directs
`-static-libgcc -static-libstdc++` to those rebuilt outputs.

**Tech Stack:** locked Nixpkgs GCC 14.3.0, Nix derivations, GNU make,
manylinux_2_28 sysroot, GCC/binutils ELF audits, Bash, Docker, Debian 11.

## Global Constraints

- Work on branch `glx-vulkan-manylinux-2-28`; preserve all existing uncommitted files, particularly `docs/` and Task 3 files.
- Use only locked GCC 14.3.0 source and the Task 2 manylinux 2.28 sysroot for target libc interfaces.
- Host GCC/GMP/MPFR/MPC and build tools are build-host-only; never import Nix glibc into target header or linker searches.
- The allowed compiler-stage make target is exactly `all-gcc`; reject bootstrap, `stage[0-9]+`, every `install-*`, and compiler executables in `$out`.
- The only target runtime make targets are exactly `all-target-libgcc all-target-libstdc++-v3`.
- `$out/lib` contains exactly `libgcc.a`, `libstdc++.a`, `libsupc++.a`, `crtbeginS.o`, and `crtendS.o`; target artifacts are selected only from the configured target subtree. GCC's `--disable-shared` configuration folds EH objects into `libgcc.a`, so no separate `libgcc_eh.a` is installed. No compiler, headers, libraries, or binaries beyond the declared provenance files may be installed.
- Adapter-wide wrapper configuration is allowed; per-probe/package raw `-B`, `-L`, sysroot, or RPATH workarounds are forbidden.
- C and C++ final probes must import `GLIBC_2.28` or older, use only the normal deployment loader/permitted glibc dependencies, and contain no RPATH/RUNPATH or `/nix/store` string.
- Native Debian 11 and Ubuntu 24.04 execution of both probes is mandatory.  Do not begin Mesa/Xvfb or delete Docker/Nix caches.
- Do not commit: this branch deliberately contains user-owned uncommitted Task 3 work.  Leave a reviewable diff and durable reports.

---

## File Structure

- `nix/manylinux-2-28-gcc-runtime.nix`: owns GCC configuration, private compiler stage, target runtime build, output allowlist, and provenance.
- `nix/manylinux-2-28-stdenv.nix`: owns the one compatibility-wrapper selection of the rebuilt GCC runtime files.
- `test/manylinux-2-28-toolchain.nix`: proves the Nix output interface and compiles C/C++ probes through the adapter.
- `test/manylinux-2-28-toolchain.sh`: continues to audit and execute the resulting probes in Debian 11 and Ubuntu 24.04.
- `.superpowers/sdd/task-3f-*.md`: ignored durable task briefs, reports, review packages, and progress ledger.

### Task 3F: Make the Compiler Stage Explicit and Non-shippable

**Files:**
- Modify: `test/manylinux-2-28-toolchain.nix`
- Modify: `nix/manylinux-2-28-gcc-runtime.nix`
- Test: `test/manylinux-2-28-toolchain.nix`

**Consumes:** `runtimeSysroot`, `target`, and the exact five-archive/startfile output contract from `nix/manylinux-2-28-gcc-runtime.nix`.

**Produces:** `gccRuntime.runtime` with private `all-gcc` provenance and an output inventory that proves no compiler is shipped.

- [ ] **Step 1: Write the failing runtime-stage contract**

Before changing the runtime derivation, add an assertion to
`test/manylinux-2-28-toolchain.nix` that requires a `compiler-stage-targets`
provenance file and validates its sole line:

```nix
assert builtins.readFile
  "${gccRuntime.runtime}/nix-support/compiler-stage-targets" == "all-gcc\\n";
```

Also require the existing runtime target file to remain exactly:

```nix
assert builtins.readFile
  "${gccRuntime.runtime}/nix-support/runtime-targets" ==
  "all-target-libgcc all-target-libstdc++-v3\\n";
```

- [ ] **Step 2: Run RED**

Run the native Docker/Nix build of `test/manylinux-2-28-toolchain.nix` with
`--option log-lines 200` and the dedicated manylinux runtime Nix volume.

Expected: failure before a runtime build begins because
`compiler-stage-targets` is absent, or the existing runtime-only guard rejects
the required compiler stage. Save the complete relevant failure in
`.superpowers/sdd/task-3f-runtime-report.md`.

- [ ] **Step 3: Replace the disproved runtime-only guard with a bounded stage**

In `nix/manylinux-2-28-gcc-runtime.nix` keep the current configure arguments,
including `--disable-bootstrap`, the Task 2 sysroot, and build-host-only
GMP/MPFR/MPC paths. Change the build sequence to exactly:

```bash
compiler_stage_targets='all-gcc'
runtime_targets='all-target-libgcc all-target-libstdc++-v3'

make $compiler_stage_targets > "$NIX_BUILD_TOP/compiler-stage.log" 2>&1
test -x "$build_dir/gcc/xgcc"
make $runtime_targets > "$NIX_BUILD_TOP/runtime-build.log" 2>&1
```

Before each make invocation, reject make-target strings `bootstrap`,
`stage[0-9]+`, `install-`, and any compiler-stage target other than the exact
`all-gcc` variable. Do not use `make -k`, a recursive broad target, or an
install target. After the compiler-stage make, retain `xgcc` only as a
build-tree assertion; never copy it.

Update the installed provenance and exact expected inventory with:

```bash
printf '%s\\n' "$compiler_stage_targets" \\
  > "$out/nix-support/compiler-stage-targets"
```

The existing compiler-name rejection in `$out` stays mandatory.

- [ ] **Step 4: Run GREEN and record bounded evidence**

Run the same Nix build.  Capture: configure source/version/target; the exact
compiler and runtime target provenance; first/last 100 log lines for each
make phase; the size of the Nix volume before/after; and the final output
inventory.  The build may take a long time.  Report only checkpoint/outcome
messages, not periodic polling noise.

Expected: compiler stage completes, target archives/startfiles are uniquely
found and installed, and the output inventory contains the six runtime files
plus provenance only.  If `all-gcc` needs a forbidden make target, fails to
produce `gcc/xgcc`, or the final output contains a compiler, stop and report
the exact make rule/log evidence rather than broadening the target.

### Task 3G: Route the Adapter Through the Rebuilt Runtime and Prove Deployment

**Files:**
- Modify: `test/manylinux-2-28-toolchain.nix`
- Modify: `nix/manylinux-2-28-stdenv.nix`
- Test: `test/manylinux-2-28-toolchain.nix`
- Test: `test/manylinux-2-28-toolchain.sh`

**Consumes:** `gccRuntime.runtime/lib` from Task 3F and the existing
`libcFacade`, wrapped bintools, deployment loader, C/C++ probe sources, and
ELF audit contract.

**Produces:** an adapter whose C++ driver resolves static libgcc/libstdc++ and
start/end objects from the rebuilt target runtime without per-probe flags.

- [ ] **Step 1: Write the failing wrapper-selection contract**

In the Nix probe derivation, before compiling `manylinux-2-28-probe.cc`, add
an adapter-level diagnostic assertion that its wrapped compiler verbose link
line contains the rebuilt runtime directory and does not contain a Nix GCC
runtime archive path.  Persist the verbose line in
`$out/nix-support/cxx-link-command` only after installation.

Run the focused derivation before changing `manylinux-2-28-stdenv.nix`.

Expected: the assertion fails because the adapter currently selects Nix's
GCC runtime rather than `gccRuntime.runtime/lib`.

- [ ] **Step 2: Add one adapter-wide GCC runtime search prefix**

Extend `nix/manylinux-2-28-stdenv.nix` to import
`manylinux-2-28-gcc-runtime.nix` and add a single wrapper linker configuration
that makes GCC search `${gccRuntime.runtime}/lib` before its own target
runtime directory.  Use `nixSupport` on `wrapCCWith`; do not alter the C/C++
probe commands beyond their existing `-static-libgcc -static-libstdc++`.
The exact flag must be a GCC driver `-B${gccRuntime.runtime}/lib` prefix,
which is adapter-wide and applies to GCC's startfile/runtime lookup.

Keep `cc-cflags = "--sysroot=${libcFacade}"` and the existing deployment-loader
and RPATH protections unchanged.  Expose `gccRuntime` in the returned adapter
attribute set for test provenance only.

- [ ] **Step 3: Run GREEN Nix-level ABI proof**

Build `test/manylinux-2-28-toolchain.nix`.  Confirm all existing install
checks pass for both ELF files: maximum imported `GLIBC_*` is at most 2.28,
there is no RPATH/RUNPATH or `/nix/store` string, and only permitted glibc
dependencies/normal loader appear.  Confirm the persisted verbose C++ link
line names the rebuilt runtime directory and no Nix GCC runtime archive.

- [ ] **Step 4: Run the runtime proof**

Run:

```bash
bash -n test/manylinux-2-28-toolchain.sh
./test/manylinux-2-28-toolchain.sh
```

Expected output includes each of:

```text
manylinux_2_28 C probe passed on Debian 11
manylinux_2_28 C++ probe passed on Debian 11
manylinux_2_28 C probe passed on Ubuntu 24.04
manylinux_2_28 C++ probe passed on Ubuntu 24.04
maximum imported glibc symbol: GLIBC_2.28 or older
```

If the C++ ELF exceeds the floor or fails on Debian 11, stop.  Save readelf
symbol evidence and the exact verbose link line; do not downgrade the probe,
extract image runtime archives, or patch unrelated packages.

### Task 3H: Audit the Bounded Stage and Prepare Review Handoff

**Files:**
- Modify: `.superpowers/sdd/progress.md`
- Create: `.superpowers/sdd/task-3f-runtime-report.md`
- Create: `.superpowers/sdd/task-3g-wrapper-report.md`

**Consumes:** Task 3F/3G derivation outputs and log evidence.

**Produces:** durable evidence sufficient for an independent reviewer and the
next Mesa task; no production source change.

- [ ] **Step 1: Perform the required output audit**

For the realized runtime output, list every file, verify the exact six
`lib/` files, verify the compiler-name rejection, and compare the installed
provenance to the target strings in this plan.  For the realized probe output,
record `readelf --version-info`, program-interpreter, dynamic section, and
`strings` audit results for both C and C++ binaries.

- [ ] **Step 2: State the precise result**

Append one durable progress-ledger line with the tested architecture, commits
(if any), Nix output paths, and outcome.  State either `Task 3F/3G complete`
only when every global constraint has passed, or `blocked` with the first
failing criterion and exact evidence path.  Do not claim any Mesa/Xvfb or
external-Vulkan artifact result.

- [ ] **Step 3: Independent task review**

Create a review package from the branch base to current worktree diff and ask
a fresh reviewer to inspect only these criteria: target/build-host separation,
make-target bounding, `$out` inventory, wrapper-only runtime selection, and
the C++ ELF/deployment evidence.  Resolve every Critical or Important finding
with a fresh fix subagent and re-run the covering Nix and shell tests.

## Plan Self-Review

- Scope is confined to GCC runtime staging and the toolchain proof; Mesa/Xvfb,
  release claims, and image-runtime extraction are excluded.
- Every success criterion in the design maps to Task 3F, 3G, or 3H.
- The plan deliberately uses a one-derivation transient compiler stage so no
  compiler can cross the runtime-output boundary.
- No target-package raw flags, cache deletion, unstated fallback, or automatic
  commit is permitted.
