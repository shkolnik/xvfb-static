# External Vulkan GLX: architecture, ABI, and release gates

This document describes the `xvfb-static-glx-external-vulkan-alpha` artifact:
what it is, what it guarantees, what enforces each guarantee, and what is still
unproven.

It is written to be checkable. Every claim below names the file that enforces
it, so a reader can verify the claim rather than trust it. If you change one of
those files, change this document in the same commit.

## Why this variant exists

The project ships three variants, and they are three different answers to the
same question — where does OpenGL come from?

| Variant | GL implementation | Dynamic deps | Size | Uses the GPU |
|---|---|---|---|---|
| `no-glx` | none; GLX disabled | none | smallest | no |
| `glx-llvmpipe-alpha` | Mesa llvmpipe + LLVM, statically linked | none | largest | no |
| `glx-external-vulkan-alpha` | Mesa Zink, statically linked, over the host's Vulkan | `libvulkan.so.1` + libc | middle | yes, if the host has a driver |

llvmpipe answers it by carrying a complete software renderer, which costs an
LLVM-sized amount of binary and can never touch a GPU. This variant answers it
by carrying only the Zink translation layer — Mesa's OpenGL-on-Vulkan driver —
and reaching out to whatever Vulkan the host already has.

The tradeoff is explicit and asymmetric: it gives up full static linkage, which
is the project's headline property, in exchange for actual GPU access. That is
why it is a separate, alpha-labelled artifact rather than a replacement for
either of the others.

## Architecture

```
   ┌──────────────────────────────── the archive ────────────────────────────┐
   │  bin/Xvfb                                                               │
   │    ├── X.Org Xvfb DDX  (+ xserver-0001..0005)                           │
   │    ├── GLX                                                              │
   │    ├── Mesa Zink       (+ mesa-0002, mesa-0003)   ── statically linked  │
   │    └── embedded XKM keyboard catalog                                    │
   └──────────────────────────────┬──────────────────────────────────────────┘
                                  │ dlopen-free, ordinary DT_NEEDED
                                  ▼
                          host libvulkan.so.1              ← not redistributed
                                  │
                                  ▼
                          host vendor ICD                  ← not redistributed
                                  │
                                  ▼
                              GPU driver
```

"One dynamic dependency" is a claim about **graphics ABIs**, not about the
total dynamic symbol count. The binary also links the ordinary libc family. The
complete allowlist, enforced in two places
(`package-glx-external-vulkan.nix`, at packaging time, and
`test/glx-external-vulkan-smoke.sh`, against the finished archive), is:

```text
libc.so.6   libdl.so.2   libm.so.6   libpthread.so.0   librt.so.1
libvulkan.so.1
ld-linux-x86-64.so.2   |   ld-linux-aarch64.so.1
```

Anything outside that list fails the build. The check is a `case` over
`readelf -d`, so a new dependency cannot arrive unnoticed.

### No LLVM, no software fallback

Mesa can fall back to llvmpipe, softpipe, or lavapipe when a real device is
unavailable. For this artifact that would be a silent correctness failure: the
user asked for GPU rendering, and a fallback would give them CPU rendering with
no signal. `patches/mesa-0003-force-linked-zink.patch` forces Zink selection,
and `mesa-zink.nix` builds Mesa with LLVM disabled outright, so there is no
fallback to fall back *to*.

Three independent checks keep it that way:

1. **Binary strings.** The packaged binary must contain no `libLLVM`, no
   `LLVM_[0-9]`, no `swrast_dri`, no `libGL.so`, and no `libgallium*.so`
   reference (`package-glx-external-vulkan.nix`).
2. **Packaged licenses.** `share/xvfb-static/licenses/` must contain no LLVM,
   Polly, or BLAKE3 notice. Incorporating LLVM is forbidden, so shipping its
   notice would mean the ban had already been breached — and adding an
   `extract_license` line for LLVM would otherwise produce an
   LLVM-notice-bearing archive with a green build.
3. **Manifest.** `components` must have `mesa` and must *not* have `llvm`
   (`test/glx-external-vulkan-smoke.sh`).

Check 1 previously had a defect worth recording, because it is the kind that
survives review: the regex was written in a Nix indented string as
`libGL\\.so|libgallium[^ ]*\\.so`. In an indented string `\\` is a literal
two-character sequence, so the shell received `libGL\\.so`, and in an extended
regex `\\` matches a literal backslash. Those two alternatives could never
match anything. The first four worked, so the guard looked functional.

## ABI floor: glibc 2.28

A host-assisted binary is only as portable as the oldest glibc it can run
against. This one targets **glibc 2.28** — AlmaLinux 8, RHEL 8, Debian 10, and
newer.

The floor is declared in exactly one place, `nix/manylinux-2-28-images.json`,
alongside the digest-pinned manylinux_2_28 images it is derived from. Nothing
else may restate the number; `nix/manylinux-2-28-images.nix` asserts the lock
encodes the policy and floor it claims, and `test/repo-checks.sh` fails if any
document mentions a different glibc version.

The toolchain that achieves it lives under `nix/`:

| File | Role |
|---|---|
| `manylinux-2-28-images.json` | Digest-pinned image references and the declared floor |
| `manylinux-2-28-images.nix` | Reads the lock; asserts policy name and floor |
| `manylinux-2-28-sysroot.nix` | Unpacks images into a sysroot, with symlink-escape and linker-script audits |
| `manylinux-2-28-stdenv.nix` | The stdenv targeting that sysroot, including build and deployment loader paths |
| `manylinux-2-28-gcc-runtime.nix` | GCC runtime pieces the sysroot does not carry |
| `manylinux-2-28-packages.nix` | The package set built against that stdenv |

Enforcement happens three times, deliberately:

1. **`test/manylinux-2-28-toolchain.sh`** compiles C, C++, and zlib probes with
   the toolchain and fails on any imported symbol newer than the floor. This
   catches a broken toolchain before anything expensive is built.
2. **The package derivation** computes `glibc_symbol_floor` from the finished
   ELF with `readelf --version-info` and records it in the manifest. This is
   measured, not declared.
3. **`test/glx-external-vulkan-smoke.sh`** re-reads the lock and compares the
   binary's newest required `GLIBC_*` symbol against it, failing if it is
   higher.

Layer 3 is the one that matters most, and it is worth stating why it exists in
that form. It previously did the opposite: on discovering the binary needed a
newer glibc than the floor, it printed `structural ABI checks passed` and
exited 0 — skipping every runtime, ICD, loader-failure, and render check below
it. That is, it turned the single condition the artifact's contract forbids
into a green result, and the release workflow treated that green as a
publication gate. Two fallback guards that were supposed to catch this were
both inert: one keyed on a manifest field, `minimum_host_glibc`, that no
derivation has ever emitted, and the other on an environment variable set
nowhere in the repository. The lesson generalizes past this file: **a check
that skips on the failure condition is worse than no check**, because it reads
as coverage.

The binary is also `patchelf`ed to the deployment loader path, has its rpath
removed, and has every `/nix/store` reference scrubbed — a static library
carries build-time resource defaults into its string table, and those paths
cannot resolve on a target host. The scrub rewrites the uniform dead prefix to
an equally sized `/nonexistent/...` path so the replacement cannot change
offsets.

## Manifest

Beyond the fields every variant carries, this one declares:

```json
{
  "variant": "glx",
  "maturity": "alpha",
  "renderer": "zink",
  "graphics_backend": "external-vulkan",
  "runtime_model": "host-assisted",
  "glibc_symbol_floor": "2.28",
  "required_graphics_library": "libvulkan.so.1",
  "components": { "xorg-server": "…", "mesa": "…" }
}
```

These survive renaming or extraction of the archive, which is the point: a
consumer that finds a loose `Xvfb` can still discover it is an alpha,
host-assisted, Zink-backed build with a 2.28 floor.

## Test coverage

`test/glx-external-vulkan-smoke.sh` runs, in order:

1. **Manifest shape** — the fields above, including the absence of `llvm`.
2. **ELF interpreter** — matches the architecture's deployment loader exactly.
3. **glibc floor** — as described above.
4. **Dependency allowlist** — as described above.
5. **Missing loader** on Debian 11: the host `libvulkan.so.1` is moved aside,
   and the artifact must fail with a clear Vulkan/GLX diagnostic rather than
   render anything.
6. **Missing ICD** on Debian 11: `VK_ICD_FILENAMES` points at a nonexistent
   file, same requirement.
7. **Zink render/readback** on Debian trixie, over lavapipe.

Cases 5 and 6 are the ones that prove the no-fallback property behaviorally
rather than structurally. A build that silently fell back to a software
renderer would *pass* the string scan if the fallback were compiled in under a
different name; it cannot pass a test that removes the loader and demands a
failure.

Debian 11 is used for 5 and 6 because it supplies exactly the advertised
loader/glibc baseline. It cannot be used for 7: its Mesa 22 lavapipe predates
the `nullDescriptor` feature Zink requires. Case 7 therefore runs on Debian
trixie with a newer lavapipe, and needs `LIBGL_ALWAYS_SOFTWARE=1` because Zink
otherwise refuses CPU Vulkan devices.

`test/archive-checks.sh` additionally runs against this artifact, covering
archive shape, manifest inventory, license presence, and the absence of XKB
runtime data — the variant-agnostic checks. It was split out of
`test/smoke.sh` precisely so this variant could take them: `smoke.sh` asserts
static linkage and boots in Alpine, neither of which applies here, so the
release workflow used to skip the whole script and this artifact got no archive
checks at all.

## Compatibility policy

**What the project guarantees.** The binary runs on a glibc host at or above
the declared floor, with a working Vulkan 1.x loader at `libvulkan.so.1` and an
ICD exposing a device Zink accepts. It will not silently substitute a software
renderer.

**What the host must supply, and the project does not redistribute.** The
Vulkan loader, the vendor ICD, and their transitive dependencies. These are
runtime requirements, not archive contents, and their licenses are the host's
concern — `THIRD-PARTY-NOTICES.md` keeps that distinction explicit. Do not
list host-side components among the archive's notices, and do not omit a
statically incorporated component because a host also happens to have it.

**What is out of scope.** Vulkan portability layers, driver bug workarounds,
and per-vendor quirk handling. If a vendor's ICD misbehaves, that is a bug to
report to the vendor.

## Release gate

This artifact **is published**, as an alpha, on every release. The gate is
mechanical and complete — every item is enforced by a check that fails the
build or the workflow, and none may be skipped:

1. manifest declares `variant`, `maturity`, and `renderer` (`release.yml`);
2. no LLVM or software-renderer references in the binary;
3. no LLVM notice among the packaged licenses;
4. measured `glibc_symbol_floor` at or below the declared floor;
5. dynamic dependencies within the allowlist;
6. loud failure on missing loader and on missing ICD;
7. Zink render/readback succeeds.

### What the gate does not cover

**Actual-GPU render/readback has not been performed on either architecture.**
CI runs Zink over lavapipe, a software Vulkan implementation. That is genuine
integration coverage for the Zink code path — it proves GL calls reach Vulkan
and pixels come back — but it is not evidence that any real driver works.

This is stated as a published limitation of the alpha rather than treated as a
publication blocker. The artifact is labelled `alpha` in its filename, its
manifest, and its release notes, and both `README.md` and this document say
plainly that GPU support is untested. Users can validate on their own hardware;
what they cannot do is discover the limitation by surprise.

### Promoting out of alpha

Dropping the `alpha` label requires, in addition to the gate above:

- native actual-GPU render/readback on x86_64 **and** aarch64;
- renderer evidence positively excluding every software device;
- each result recording the GPU model, kernel version, Vulkan loader version,
  ICD, Mesa version, and architecture;
- a documented decision about which vendors and driver generations are
  considered supported.

A Zink-over-lavapipe result does not satisfy any of these. Neither does a
single successful run on one developer's machine — the point of recording the
environment is that "works on a 2024 NVIDIA proprietary driver" and "works" are
different claims.

## See also

- [AGENTS.md](../AGENTS.md) — sections 3, 5, 9, and 10 for the product
  contract, build layers, compliance rules, and CI/release expectations.
- [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md) — what is redistributed
  and what is merely required at runtime.
- `package-glx-external-vulkan.nix`, `mesa-zink.nix` — the build.
- `test/glx-external-vulkan-smoke.sh` — the runtime gate.
