# AGENTS.md — xvfb-static project guide

This file is the cold-start guide for humans and coding agents working on this
repository. Read it completely before changing build inputs, patches, artifact
contents, tests, licensing material, or release automation.

## 1. Project in one paragraph

`xvfb-static` builds reproducible, fully statically linked Xvfb executables for
Linux. A release archive should run without a host dynamic linker, X11
packages, `xkbcomp`, or an XKB data tree. The build is driven by Nix
`pkgsStatic` inside a digest-pinned Docker image. The X.Org source and all
dependencies are pinned through `flake.lock`. A curated keyboard-map catalog is
compiled during the build and embedded into Xvfb, allowing the runtime package
to contain one executable plus metadata and license texts.

The project deliberately optimizes for a small, portable server-side artifact,
not for feature parity with a distribution Xvfb package.

## 2. Current status and provenance

The project builds, tests, and publishes end to end. Both CI and the release
workflow run a 3-variant × 2-architecture matrix (standard, GLX llvmpipe alpha,
GLX external Vulkan alpha; x86_64 and aarch64) on matching native
GitHub-hosted runners.

- Tags `v21.1.23-r1` through `v21.1.23-r4` exist, and `-r2`, `-r3`, and `-r4`
  are published GitHub Releases carrying all six archives plus one combined
  `SHA256SUMS`. Publication is gated on the full build-and-test matrix, so
  those releases are evidence of clean-checkout builds and passing Alpine
  smoke tests on both native architectures.
- Five X.Org patches are applied (see section 7), plus three Mesa patches, one
  LLVM patch, and one umoci patch used by the GLX and manylinux toolchains.
- The GLX llvmpipe and external Vulkan variants are alpha-stage and are
  labelled as such in their names, manifests, and release notes. The external
  Vulkan variant is host-assisted and **is published**; what remains unproven
  is actual-GPU render/readback, which no test in this repository performs.
  See the release gate in section 10 for exactly what is and is not enforced.

Still genuinely open, and not to be erased without evidence: a full
closure-versus-licence audit (section 9), an SBOM, actual-GPU validation of the
external Vulkan variant, and two test-coverage asymmetries. Section 11 tracks
these.

This repository must stay understandable, buildable, testable, and legally
distributable on its own.

## 3. Product contract

### What the artifact promises

A release archive contains:

- `bin/Xvfb` — a stripped, fully static Linux executable;
- `share/xvfb-static/manifest.json` — architecture, component version,
  xvfb-static release version and revision, schema version, and an exact file
  inventory;
- `share/xvfb-static/licenses/` — third-party license texts extracted from
  the exact pinned sources used by the build.

The archive itself is deterministic given the same declared inputs:

- Nix inputs are locked;
- the build container is pinned by digest;
- tar entries use byte-order sorting;
- owner and group are fixed to numeric zero;
- timestamps are fixed by `tar --mtime`, from `XVFB_STATIC_MTIME` in
  `build-common.sh` — one definition shared by all three entry points (there is
  no `SOURCE_DATE_EPOCH` variable in this repository; if you add one, update
  this line rather than assuming it already works);
- file modes are set explicitly with `install -m`, never inherited through
  `cp -L`, so the archive depends on neither the store's modes nor the caller's
  umask;
- no `/nix/store` path survives into a shipped binary; `nix/scrub-store-references.sh`
  rewrites them and `test/archive-checks.sh` re-checks the finished archive;
- the resulting archive receives a SHA-256 checksum.

The GLX variants preserve the one-executable package shape but have distinct
runtime contracts:

- `xvfb-static-glx-llvmpipe-alpha` statically incorporates Mesa llvmpipe and
  LLVM and remains fully static;
- `xvfb-static-glx-external-vulkan-alpha` statically incorporates Mesa Zink
  but opens the host's `libvulkan.so.1`. It is host-assisted, contains no LLVM
  or software-renderer fallback, and requires a compatible glibc host, Vulkan
  loader, and ICD.

The external-Vulkan host floor is **glibc 2.28**, established by the
manylinux_2_28 compatibility toolchain under `nix/` and enforced in three
places: `nix/manylinux-2-28-images.nix` asserts the locked policy and floor,
`test/manylinux-2-28-toolchain.sh` fails on any imported symbol newer than
`GLIBC_2.28`, and the build records the value it measured from the finished
ELF in the manifest as `glibc_symbol_floor`. `test/glx-external-vulkan-smoke.sh`
re-reads that lock and rejects any binary that exceeds it.

Take the floor from `nix/manylinux-2-28-images.json`; never restate the number
in a new file. Earlier revisions of this document named 2.31 as an aspiration —
that predates the manylinux work and is wrong.

Keep `alpha` synchronized across names, manifests, documentation, CI, and
release metadata.

### Intentional capability reduction

The binary supports exactly the embedded catalog below. It defaults to `us` and
accepts `-keyboard PROFILE` at startup. The artifact does not
ship `xkbcomp` or `share/X11/xkb`. Requests that would require compiling
another keymap must fail rather than silently booting with another profile.

This limitation is central to the single-file runtime design. Do not broaden,
hide, or remove it casually. If general keyboard-layout support becomes a
goal, treat that as a product-design change and compare at least:

1. shipping `xkbcomp` plus an XKB data tree;
2. embedding several named precompiled layouts with an explicit selector;
3. publishing separate layout-specific artifacts;
4. abandoning the single-file promise and using a conventional Xvfb package.

### Curated keyboard profiles

The runtime retains a single executable and embeds these named, precompiled profiles:

```text
us          us-intl     gb          de          fr          es
latam       it          pt          br          pl          cz
tr          se          ru          ua          gr          il
ara         vn          be          ch          nl          dk
no          fi          rs          rs-latin
```

A profile is a versioned rules/model/layout/variant/options tuple, not merely
a layout name. Most initial profiles are expected to use `evdev` and `pc105`,
but the representation must not make those fields implicit.

The catalog favors scripts XKB can produce directly or
through dead-key sequences. Japanese, Korean, Chinese, and Indic input are
deferred because their normal paths require an IME or other composition layer.

Implementation must preserve these invariants:

- selection is limited to the embedded catalog and unknown profiles fail;
- no runtime `xkbcomp`, XKB tree, or loose XKM data is added;
- the active profile is discoverable;
- every profile is compiled from the pinned `xkeyboard-config` input;
- tests cover representative base, Shift, AltGr, and dead-key sequences.

See `docs/KEYBOARD-INPUT-ARCHITECTURE.md` for portable consumer-side
architecture recommendations.

### Non-goals

- Building Xorg, Xwayland, XQuartz, or a physical-display X server.
- Shipping a VNC server, window manager, fonts, browser, or supervisor.
- Pretending the binary is a drop-in replacement for every distribution
  Xvfb configuration.
- Supporting arbitrary XKB layouts without explicitly changing the contract.
- Hiding automation, virtualization, or other environmental characteristics.

## 4. Repository map

Every tracked file appears below. If you add one, add a row.

### Documentation

| Path | Purpose |
|---|---|
| `README.md` | Public user-facing overview, installation/build instructions, limitations, and licensing summary. |
| `AGENTS.md` | Maintainer and agent cold-start guide; operational truth and maintenance invariants. |
| `CLAUDE.md` | Tracked symlink to `AGENTS.md`, so tools looking for either name find the same file. |
| `docs/KEYBOARD-INPUT-ARCHITECTURE.md` | General recommendations for profile-aware Unicode-to-physical-key input. |
| `docs/GLX-EXTERNAL-VULKAN-PLAN.md` | External Vulkan architecture, ABI, tests, compatibility policy, and release gates. |
| `THIRD-PARTY-NOTICES.md` | Explains artifact licensing and pinned-source provenance. |
| `LICENSE` / `NOTICE` | Apache-2.0 licensing for original project code and patches; not a blanket license for Xvfb. |
| `SECURITY.md` | Supported-version and private-reporting policy. |
| `CONTRIBUTING.md` | Public contribution expectations and minimum local gates. |
| `CODE_OF_CONDUCT.md` | Contributor Covenant, with the maintainer contact used for enforcement reports. |

### Build definition

| Path | Purpose |
|---|---|
| `flake.nix` | Defines symmetric native x86_64 and aarch64 outputs for all three variants, plus `checks`. |
| `flake.lock` | Exact nixpkgs revision and content hash. This transitively pins X.Org and linked dependencies. |
| `package.nix` | Core build: static-libxcvt workaround, embedded keymap, Xvfb override, stripping, license extraction, and manifest generation. |
| `keyboard-profiles.nix` | The curated profile catalog: the single source of the profile ids and their rules/model/layout/variant/options tuples. |
| `mesa-llvmpipe.nix` / `package-glx-llvmpipe.nix` | Fully static Mesa llvmpipe/LLVM and GLX Xvfb alpha build. |
| `mesa-zink.nix` / `package-glx-external-vulkan.nix` | Host-assisted external Vulkan/Zink alpha build. |
| `integration-test.nix` | Nix check that regenerates the XKB sources for every profile and diffs them against what the build embedded. |
| `cachix.nix` | Resolves the Cachix client from the exact nixpkgs revision in `flake.lock`. |
| `nix/extract-license.sh` | The one hardened license extractor, interpolated into all three package derivations. |
| `nix/keymap-catalog.nix` | The one keymap-catalog implementation: compiles every profile's XKM blob and generates the C arrays and lookup table embedded into Xvfb. |
| `nix/scrub-store-references.sh` | The one store-reference scrub, applied by every variant that ships a binary linked against store paths. |
| `build-image.txt` | The single source of truth for the digest-pinned `nixos/nix` build container. Every script and workflow reads it. |

### manylinux_2_28 compatibility toolchain

Used only by the external Vulkan variant, which must run against a host glibc
rather than its own.

| Path | Purpose |
|---|---|
| `nix/manylinux-2-28-images.json` | Digest-pinned manylinux image references and the declared `glibcFloor` per system. The authoritative floor. |
| `nix/manylinux-2-28-images.nix` | Reads that lock and asserts the policy name and floor it encodes. |
| `nix/manylinux-2-28-sysroot.nix` | Unpacks the pinned images into a sysroot, with symlink-escape and linker-script audits. |
| `nix/manylinux-2-28-stdenv.nix` | Builds the stdenv that targets the sysroot, including build and deployment loader paths. |
| `nix/manylinux-2-28-gcc-runtime.nix` | Supplies the GCC runtime pieces the sysroot does not carry. |
| `nix/manylinux-2-28-packages.nix` | The package set built against that stdenv. |
| `nix/manylinux-2-28-umoci.nix` | The one patched-umoci derivation, applied at build time to the sysroot unpacker and independently exercised by the fixture that proves the patch. |
| `nix/manylinux-2-28-static-overrides.nix` | Small package overrides needed at more than one call site in the external Vulkan build: dropping libXfont2's uninstalled lsfontdir helper, disabling pixman's tests, and libdrm without Intel/Valgrind support. |
| `scripts/update-manylinux-2-28-lock.sh` | Prints a refreshed lock to stdout for review; it does not write the file. |

### Patches

`xserver-*` patches apply to the pinned X.Org server; the other families apply
to their named upstreams. See section 7 for ordering rules.

| Path | Purpose |
|---|---|
| `patches/xserver-0001-xkb-env-overrides.patch` | Makes the legacy xkbcomp path shell-free and adds explicit path overrides. Retained even though the embedded-keymap path makes it normally unreachable. |
| `patches/xserver-0002-embedded-keymap.patch` | Selects and loads a compiled XKM blob from memory, bypasses runtime rules lookup/xkbcomp, and rejects unsupported string-keymap compilation. |
| `patches/xserver-0003-keyboard-profile-option.patch` | Adds the Xvfb-only `-keyboard PROFILE` startup selector. |
| `patches/xserver-0004-component-log-prefixes.patch` | Adds stable component labels to project-owned Xserver and XKB diagnostics. |
| `patches/xserver-0005-linked-swrast.patch` | GLX variants only: resolves the statically linked GL driver instead of dlopening a DRI module. |
| `patches/mesa-0001-check-jit-before-use.patch` | Prevents Mesa from assuming an LLVM JIT that the no-LLVM configuration does not provide. |
| `patches/mesa-0002-linked-swrast-entrypoint.patch` | Exposes the statically linked swrast entry point the xserver patch above expects. |
| `patches/mesa-0003-force-linked-zink.patch` | Forces Zink selection so no software renderer can be substituted silently. |
| `patches/llvm-0001-allow-static-execution-engine.patch` | llvmpipe variant only: lets the execution engine link statically. |
| `patches/umoci-0001-rootless-mask-privileged-mode-bits.patch` | Lets the sysroot unpack run rootless by masking privileged mode bits. |

### Scripts and automation

| Path | Purpose |
|---|---|
| `build-common.sh` | Sourced, not executed. The shared body of the three build entry points, and the one definition of the build image accessor, the `/nix` volume name, the archive mtime, and the architecture table. |
| `build.sh` | Docker-only entry point and reproducible archive/checksum assembly for the base variant. |
| `build-glx-llvmpipe.sh` | Deterministic llvmpipe GLX alpha archive entry point. |
| `build-glx-external-vulkan.sh` | Deterministic external Vulkan GLX alpha archive entry point. |
| `nix-build-cached.sh` | In-container build wrapper: configures public cache reads, asserts the substituter actually took effect, and pushes new paths when authenticated. |
| `release.sh` | Local maintainer helper that selects the next release revision, commits it when needed, creates a signed tag, and atomically pushes it to GitHub. |
| `scripts/release-tag.sh` | The one definition of the release tag grammar, sourced by both `release.sh` and the release workflow. |
| `.github/workflows/ci.yml` | Shell-syntax and lock checks, then builds and tests all three variants on both native architectures, uploading ephemeral artifacts. |
| `.github/workflows/release.yml` | Validates `v<upstream>-r<revision>` tags, builds and tests all six artifacts, attests them, and publishes them with combined checksums. |
| `.github/dependabot.yml` | GitHub Actions updates monthly and `nixpkgs` flake-input updates weekly. |
| `.github/ISSUE_TEMPLATE/bug_report.yml`, `.github/pull_request_template.md` | Contribution intake forms; the PR template states the real verification matrix. |
| `.gitignore` | Excludes `out/`, Nix result links, and release temporaries. |
| `out/` | Ignored local build products. Never treat these as source. |

### Tests

| Path | Purpose |
|---|---|
| `test/archive-checks.sh` | Variant-agnostic archive checks: shape, manifest inventory, licenses, absence of XKB runtime data, profile catalog. Runs against all six artifacts. |
| `test/smoke.sh` | Runs `archive-checks.sh`, asserts static linkage, then boots Xvfb and exercises `-keyboard` inside clean Alpine. |
| `test/glx-llvmpipe-smoke.sh` | Verifies indirect llvmpipe GLX render/readback without host graphics libraries. |
| `test/glx-external-vulkan-smoke.sh` | Verifies the host-assisted ABI against the declared glibc floor, the loud missing-loader failure, and Zink render/readback. Needs a glibc environment, not Alpine. |
| `test/glx-render.nix` / `test/glx-render.c` | The GLX client used for render/readback checks. |
| `test/integration.sh` | Runs the Nix `checks` in the pinned container. |
| `test/manylinux-2-28-lock.sh` | Asserts the image lock's shape and that a divergent lock is rejected. |
| `test/manylinux-2-28-toolchain.sh` / `test/manylinux-2-28-toolchain.nix` | The glibc symbol-version gate: compiles the probes below and fails on any import newer than the declared floor. |
| `test/manylinux-2-28-probe.c`, `test/manylinux-2-28-probe.cc`, `test/manylinux-2-28-zlib-probe.c` | C, C++, and zlib probes for that gate. |
| `test/repo-checks.sh` | Build-free source-tree checks: shell syntax, and consistency between the documentation and the files, counts, and floors it describes. |
| `test/images.sh` | Sourced, not executed. The single source of truth for the digest-pinned Alpine, Debian, and Ubuntu test containers. |
| `test/docker-image-pins.sh` | Fails if any tracked file other than `build-image.txt` or `test/images.sh` names a container image, by tag or by digest. |
| `test/manylinux-2-28-umoci-fixture.nix` | Fixture proving the umoci patch masks privileged mode bits. |

## 5. How the build works

### Layer 1: pinned environment

`build.sh` starts a digest-pinned `nixos/nix` container and mounts:

- the repository at `/src`;
- a named Docker volume, `xvfb-static-nix`, at `/nix` for build-cache
  reuse.

The host needs only Docker. Files created as root in the container are handed
back to the invoking host UID/GID before exit.

When `CACHIX_CACHE_NAME` is set, `build.sh` installs the Cachix client from
the locked nixpkgs input inside the container and configures that public
binary cache as a substituter. When `CACHIX_AUTH_TOKEN` and the self-managed
`CACHIX_SIGNING_KEY` are also set, the build runs under `cachix watch-exec`,
signs newly built store paths locally, and uploads them. CI pull requests
receive anonymous read access only; trusted branch and release builds receive
the repository secrets and may write. The cache is an optimization, not
reproducibility evidence; periodically test with it disabled.

All three flake variants evaluate **purely**: `build.sh`,
`build-glx-llvmpipe.sh`, `build-glx-external-vulkan.sh`, `release.sh`, and
`test/integration.sh` pass neither `--impure` nor
`NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1`. `--impure` was required until the GLX and
Mesa modules stopped re-entering the flake through
`builtins.getFlake (toString /src)`; they are now ordinary `callPackage`-style
modules taking `pkgs`. `NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1` was carried
alongside it and, once evaluation went pure, turned out to be unnecessary as
well — the `libxcvt` override replaces the blocked derivation before anything
evaluates its metadata. If you reintroduce either flag, say in the commit
message which evaluation actually requires it.

Three places still pass `--impure`, and all three are `--file` invocations that
read `builtins.currentSystem` or `getFlake` a path, outside the flake's own
evaluation: `nix-build-cached.sh` resolving `cachix.nix`,
`test/manylinux-2-28-toolchain.sh` resolving the toolchain files, and the
`glx-render` client step in both workflows resolving `test/glx-render.nix`.
Those two workflow steps also still set `NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1`;
whether they need it has not been re-derived since evaluation went pure, so do
not treat its presence there as evidence that it is required.

The `libxcvt` workaround itself is still needed: nixpkgs hard-codes Meson
`shared_library()`, which ignores the static toolchain, so the project replaces
it with `library()`.

### Layer 2: static Xvfb derivation

`package.nix` starts with nixpkgs' top-level Xvfb-only X.Org server variant rather
than re-creating the X server configuration flags. It:

1. makes `libxcvt` build as a static archive;
2. replaces the stock `libxcvt` input with that corrected derivation;
3. applies `xserver-0001` through `xserver-0004`, in that order;
4. generates an XKB source description for every profile;
5. compiles them with the build-platform `xkbcomp`;
6. converts the XKM bytes into generated C arrays and a lookup table;
7. compiles that catalog into Xvfb;
8. copies and strips only `bin/Xvfb` into the output.

The keymap compiler and XKB source data are build-time inputs only.

The llvmpipe GLX derivation links Mesa's Gallium swrast frontend and llvmpipe
into Xvfb, including LLVM. The external Vulkan derivation instead links Zink
with LLVM explicitly disabled and uses Mesa's Vulkan loader adapter to resolve
the host loader. It must force Zink and fail loudly if the loader, ICD, or
device is unavailable; never allow llvmpipe, softpipe, or lavapipe fallback.
“One dynamic dependency” means one external graphics ABI. Ordinary host glibc
runtime libraries and vendor ICD transitives must still be documented and
audited honestly.

### Layer 3: attribution and manifest

The package derivation extracts license files from pinned Nix source
derivations, not from mutable web URLs. Missing, ambiguous, or empty license
matches fail the build.

The manifest lists every packaged file including itself. If packaging changes,
the manifest and the smoke test should be updated together.

### Layer 4: deterministic release archive

`build.sh` dereferences the Nix result, creates
`xvfb-static-linux-<arch>.tar.gz`, and writes `SHA256SUMS`. Local
outputs live under `out/<arch>/` and are ignored by Git.

## 6. Normal development workflow

From a clean checkout:

```sh
./build.sh
./test/smoke.sh
```

Then inspect rather than trusting a green exit status alone:

```sh
tar -tzf out/x86_64/xvfb-static-linux-x86_64.tar.gz
file out/x86_64/package/bin/Xvfb
jq . out/x86_64/package/share/xvfb-static/manifest.json
find out/x86_64/package/share/xvfb-static/licenses -type f -maxdepth 1 -print
sha256sum --check out/x86_64/SHA256SUMS
```

Expected facts:

- `file` says the executable is statically linked;
- `bin/` contains exactly one file, `Xvfb`;
- there is no runtime `xkbcomp`, XKB tree, or loose XKM file;
- Xvfb stays alive after the smoke test's two-second boot window;
- a clean boot produces no diagnostics;
- manifest entries correspond to actual archive files;
- all bundled license files are non-empty.

If Docker is unavailable but Nix is installed, evaluation/build can be
attempted directly:

```sh
nix build .#xvfb-static-x86_64
```

That path does not exercise the pinned Docker environment or archive assembly,
so it is useful but not a replacement for `build.sh` plus the Alpine test.

### Verify test teeth

For load-bearing checks, prove the test detects the failure it claims to pin.
Examples:

- temporarily package an extra file and ensure the exact-bin-shape check fails;
- temporarily omit a license and ensure the build fails;
- temporarily stop embedding the keymap and ensure the clean Alpine boot fails;
- temporarily link dynamically and ensure the static-link assertion fails.

Do this even for checks that look too simple to be wrong. The shell-syntax gate
was one line, ran in CI and in `release.sh`, and had been checking exactly one
script for its whole life: `bash -n a.sh b.sh` parses only `a.sh` and turns the
remaining arguments into that script's positional parameters. It was found by
breaking the second file in the list and watching the gate pass.

Make temporary regressions surgically and revert only your own changes. Never
use broad destructive Git commands in a dirty working tree. In particular, do
not `git checkout --` a file to undo a temporary edit: if you have staged work,
that restores the staged copy and silently discards the real change you were
making.

## 7. Patch maintenance rules

The patches are the highest-risk part of this small repository because they
modify security- and correctness-sensitive X server startup code.

Before changing a patch:

1. Read the patch header completely. It records why the hook exists and which
   upstream call paths were inspected.
2. Inspect the exact pinned upstream source, not a current branch on the web.
3. Prefer an upstream configuration option when one genuinely satisfies the
   contract.
4. Keep changes narrowly scoped and explain why each source edit is needed.
5. Confirm every patch in the affected family still applies in its listed
   order.
6. Rebuild the production binary.
7. Run the clean-container boot test.
8. Exercise the failure path, not only the happy path.
9. Record any behavior change in `README.md` and this file.

### Patch families and ordering

`patches/` holds four independent families, distinguished by their filename
prefix. Ordinals are per-family and are only meaningful within a family.

**`xserver-*`** — applied to the pinned X.Org server. All three variants apply
`0001` through `0004`; the two GLX variants then apply `0005`.

Patch 0001 precedes patch 0002 because patch 0002 was authored against a tree
with patch 0001 already applied. Patch 0003 then connects the VFB-only parser
to the embedded loader. Patch 0004 labels the diagnostics introduced by the
preceding patches, so it must come after all of them. Patch 0005 resolves the
statically linked GL driver and is applied last in the GLX variants; it touches
only `glx/` and so does not interact with 0001–0004. Do not reorder them
casually.

`0005` was renumbered from `0004` in July 2026: two patches shared that ordinal,
which made "0004 must remain last" ambiguous and, taken literally, wrong. If you
add an `xserver-*` patch, give it the next free ordinal and state in its header
where in the chain it must sit and why.

**`mesa-*`** — applied to Mesa. Only `0002` is shared by both GLX variants;
`0001` is applied by `mesa-llvmpipe.nix` alone and `0003` by `mesa-zink.nix`
alone. **`llvm-0001`** — applied by `mesa-llvmpipe.nix` only; the external
Vulkan variant links no LLVM at all. **`umoci-0001`** — build tooling for the
manylinux sysroot; affects no shipped bytes.

Project-owned runtime diagnostics use complete-line prefixes of the form
`[xvfb-static:COMPONENT]`. Add labels at component call sites, not by wrapping
`ErrorF()`: upstream sometimes assembles one logical line through multiple
calls. Current stable components are `xserver` for the VFB integration and
`xkb` for the embedded-keymap loader. A future GLX build should label its Mesa
and Zink integration paths independently. This convention does not promise to
intercept or relabel upstream messages or arbitrary direct writes from linked
third-party code.

The embedded-keymap patch uses `fmemopen()`, available in musl, to feed the
XKM parser without a filesystem temporary. It intentionally makes every profile's
keymap requirement independent of the caller's requested mask so a partially
parsed corrupt blob cannot be accepted on a weaker retry.

The string-keymap rejection is partly a latent guard: standard Xvfb does not
accept a `-keymap` CLI option, and the relevant exported function is more
commonly used by other DDX variants. Retaining the explicit rejection keeps a
future caller from silently falling back to the embedded layout.

## 8. Dependency and security updates

Static linking is operationally convenient but transfers patch responsibility
from the user's distribution to this project. A published binary remains
vulnerable until this project rebuilds and republishes it.

For a routine dependency refresh:

1. Review upstream X.Org and relevant library security advisories.
2. Update `flake.lock` deliberately; do not accept an unexplained bulk
   refresh.
3. Inspect the nixpkgs diff/release changes affecting Xvfb, xorg-server,
   libxcvt, XKB, pixman, font libraries, compression libraries, and other
   static closure members.
4. Confirm local patches still apply and still target the intended functions.
5. Build x86_64 and run the smoke test.
6. Build aarch64.
7. Execute the aarch64 binary on real hardware or an explicitly documented
   emulation environment when available.
8. Inspect the package closure and audit whether the generated license set
   still covers every redistributed component.
9. Publish a new immutable release version and new checksums.

Do not replace already-published assets in place. Users may have pinned a
version and checksum; changing bytes under an existing tag defeats both
reproducibility and supply-chain auditability.

Dependabot covers two ecosystems: `github-actions` monthly, and `nix` weekly,
which bumps the `nixpkgs` flake input. The `nix` updater does work — PR #3
("Bump nixpkgs from nixos-25.05 to nixos-26.05") was opened by it and merged.
Earlier revisions of this document claimed Dependabot does not touch Nix
inputs; that has not been true since the `nix` entry was added.

What it still does not do is monitor the **static dependency closure**. A
nixpkgs bump is a bulk change to hundreds of statically linked components, and
Dependabot has no view of which of them ended up in the binary. Treat a
Dependabot nixpkgs PR as a prompt to run the section-8 checklist above, not as
a reviewed update. Never mistake a bot's green status for a closure audit.

## 9. Open-source compliance rules

This repository's Apache-2.0 license covers original build files,
documentation, automation, and project-authored patch content. It does **not**
relicense X.Org or statically linked dependencies.

For every distributed archive:

- ship the component license texts inside the archive;
- extract them from the exact pinned source used to build the bytes;
- fail if an expected text is missing, empty, or ambiguous;
- keep `THIRD-PARTY-NOTICES.md` accurate;
- review the complete static closure after dependency changes;
- distinguish build-only tools from code or data incorporated into the output;
- retain `xkeyboard-config` attribution because the embedded XKM derives
  from its data;
- retain `xkbcomp` attribution conservatively unless a deliberate legal
  review concludes it is unnecessary.

The current explicit license list covers the known Xvfb dependency set. It
still needs validation against the derivation's actual complete runtime/static
closure during the first successful build. Treat that as a release blocker:
the archive must not be published merely because the listed files exist.

The llvmpipe GLX archive includes LLVM and its applicable notices. The external
Vulkan archive must contain Mesa/Zink and other statically incorporated
notices, but no LLVM notices because LLVM incorporation is forbidden. The host
Vulkan loader, vendor ICD, and their dependencies are required at runtime but
are not redistributed; distinguish those host licenses from archive content.

Do not vendor or locally modify third-party source casually. The current model
is: exact upstream source from pinned nixpkgs plus clearly separated local
patches. If third-party source is vendored later, document its precise
upstream repository, tag, commit, hashes, license, and modification status.

This section is an engineering compliance policy, not legal advice. Escalate
uncertain licensing questions rather than silently optimizing notices away.

## 10. CI and release expectations

Both workflows run a **3-variant × 2-architecture matrix** — standard,
glx-llvmpipe, glx-external-vulkan, each on x86_64 and aarch64 native runners —
producing six artifacts. CI additionally runs three build-free jobs that gate
the build jobs: `test/repo-checks.sh`, which parses every tracked script and
checks this document against the files, counts, and floors it describes;
`test/docker-image-pins.sh`, which fails if any file other than the two pin
files names a container image; and the manylinux lock check.

Every artifact, including the two external-Vulkan ones, runs
`test/archive-checks.sh`. Only the four fully static artifacts run
`test/smoke.sh`, which adds the static-linkage assertion and the Alpine boot
matrix; the external-Vulkan artifact is host-assisted and cannot boot in Alpine,
so it runs `test/manylinux-2-28-toolchain.sh` and
`test/glx-external-vulkan-smoke.sh` instead. Do not describe CI as
"boot-tests both artifacts in Alpine"; that would describe four of six.

Tags matching `v<upstream-xorg-version>-r<positive-revision>` trigger the
release workflow. The grammar is defined once, in `scripts/release-tag.sh`, and
sourced by both `release.sh` and `release.yml` — previously the workflow's
trigger glob, the workflow's validation regex, and `release.sh`'s regex
disagreed, so a two-component upstream version such as `v22.0-r1` was taggable
and pushable but silently never built. If you change the grammar, change that
one file.

The upstream portion must match the X.Org Server version in every artifact
manifest, and the full tag must match the manifest's xvfb-static version. The
project revision is maintained as `releaseRevision` in `package.nix`, starts at
`r1`, increments whenever new bytes are released for the same upstream
version, and resets to `r1` when upstream changes.

Run `./release.sh` from a clean local `main` checkout to prepare and push a
release. It derives the upstream version through the same digest-pinned Nix
Docker image as `build.sh`, considers tags already present on GitHub, and
updates only `releaseRevision`. Interactive runs require confirmation;
`--dry-run` previews without changing source, commits, tags, or remote
branches. Changing the build environment means editing `build-image.txt`, the
only place the build container is named; `test/images.sh` does the same for the
test containers, and `test/docker-image-pins.sh` fails if any other tracked file
names an image or if either pin file falls back to a mutable tag. There is
nothing to keep synchronized by hand.

The release workflow:

- triggers from an intentional version tag;
- runs the same source-tree and image-pin checks CI does, and gates every build
  job on them, so a release cannot be cut from a tree that would fail CI;
- builds all three variants on both architectures from the tagged commit;
- runs the archive checks on all six artifacts and the variant-appropriate
  runtime test on each;
- uploads all six archives and one unambiguous checksum file;
- identifies the X.Org version, nixpkgs revision, architectures,
  embedded-layout limitation, and verification status;
- generates Sigstore-backed GitHub build-provenance attestations for every
  archive before publication;
- gives build jobs only source-read plus attestation, artifact-metadata, and
  OIDC permissions, while the publishing job receives artifact-read and
  release-write permissions;
- uses `gh release create --verify-tag` so publication cannot synthesize a
  missing tag.

Immutable releases are enabled in the GitHub repository settings. Published
release assets and their tags cannot be replaced in place. All action references
are pinned by commit SHA with the readable tag in a trailing comment; Dependabot
maintains the pins.

Do not claim an architecture is “verified” when it was only cross-compiled.
Use precise language: built, statically inspected, emulated, or executed on
real hardware.

### External Vulkan alpha: what publication requires

The external Vulkan alpha **is published**, as an explicitly alpha artifact. The
gate it must clear before each release is mechanical, and every item below is
enforced by a check that fails the build or the workflow:

1. the manifest declares `variant: "glx"`, `maturity: "alpha"`, and
   `renderer: "zink"` (`release.yml`);
2. the packaged binary contains no `/nix/store` path, no `libLLVM` or `LLVM_*`
   symbol reference, and no `swrast_dri`, `libGL.so`, or `libgallium*.so`
   reference (`package-glx-external-vulkan.nix`);
3. the packaged `share/xvfb-static/licenses/` directory contains no LLVM notice
   — incorporating LLVM into this variant is forbidden, so shipping its notice
   would mean the ban had been breached silently
   (`package-glx-external-vulkan.nix`);
4. every `GLIBC_*` symbol the binary imports is at or below the floor declared
   in `nix/manylinux-2-28-images.json`, both when the toolchain is built
   (`test/manylinux-2-28-toolchain.sh`) and again against the finished archive
   (`test/glx-external-vulkan-smoke.sh`);
5. the binary's dynamic dependencies match the allowlist, and a missing Vulkan
   loader or absent ICD produces a loud failure rather than a fallback
   (`test/glx-external-vulkan-smoke.sh`);
6. Zink render/readback succeeds over the CI Vulkan device.

None of these may be skipped. `test/glx-external-vulkan-smoke.sh` previously
printed "structural ABI checks passed" and exited 0 whenever the binary exceeded
the glibc floor — that is, precisely when the contract was violated — skipping
all runtime coverage while the release workflow treated the green exit as a
gate. It now fails.

The gate item 6 does **not** cover is actual-GPU render/readback. CI runs Zink
over lavapipe, which is integration coverage for the Zink path, not evidence
that a real driver works. This is a published limitation of the alpha, stated in
`README.md` and `docs/GLX-EXTERNAL-VULKAN-PLAN.md`, not a publication blocker.
Promoting the variant out of `alpha` does require native actual-GPU
render/readback on both architectures, with renderer evidence excluding all
software devices and each result recording the GPU, kernel, Vulkan loader, ICD,
Mesa version, and architecture.

## 11. Known gaps and next recommended work

In priority order:

1. **Validate compliance against the actual closure.** The hand-maintained
   license lists in the three package derivations have never been checked
   against what the binaries actually incorporate, and nothing in the build
   compares them — the extractor fails only when a *listed* file is missing,
   never when an incorporated component is *unlisted*. Add a check that
   compares the license list against the derivation's closure and fails on any
   statically incorporated component with no notice. Until that exists, audit
   the list by hand after any dependency change.

2. **Promote or retire the external Vulkan alpha.** See the gate in section 10.
   The remaining item is native actual-GPU render/readback on both
   architectures; everything else is enforced.

3. **Close two test-coverage asymmetries.**
   - `test/glx-render.nix` hardcodes `mesa-llvmpipe.nix`, so the render client
     used to test the external Vulkan variant is built with LLVM and llvmpipe —
     the two things that variant exists to exclude — rather than with the Zink
     and manylinux toolchain the artifact itself uses. Parameterize it by
     backend.
   - The `-keyboard` selector and the `corruptEmbeddedProfile` fault injection
     are exercised only against the standard variant. Both GLX variants embed
     the same catalog through the same `nix/keymap-catalog.nix` and apply the
     same patch, and neither is covered. `test/smoke.sh` already runs the
     `-keyboard` assertions against the llvmpipe archive; the external Vulkan
     archive cannot run `smoke.sh` at all, so its keyboard coverage is zero.

4. **Consider an SPDX or CycloneDX SBOM.** It should describe the actual
   static closure and complement, not replace, license texts. This and gap 1
   want the same closure-walking machinery; build it once.

Reproducibility is no longer listed as a gap, but the evidence is worth knowing
precisely, because it is narrower than "reproducible":

- **Cross-host, same inputs.** At the store-reference-scrub change, the standard
  x86_64 archive hashed to
  `eaa1d161…` from both a local sandbox and a GitHub-hosted runner. Different
  hosts, different kernels, same bytes.
- **Predicted-byte agreement.** The mode fix that followed was predicted locally
  — by re-taring an existing package tree with the new modes, without running a
  Nix build — as
  `2bfc4b03464a409c9033c9ab82d1e30a58ebf0676d389837955210d8a36098e2`, and CI
  produced exactly that. GNU tar 1.35 and gzip 1.13 reproduce the container's
  archive byte for byte.
- **Refactor-invariance.** Both external Vulkan archives kept the same SHA-256
  across the entire July 2026 de-duplication series, which is what a faithful
  refactor should look like.

What is still missing is a same-host **double build from a cold store**: every
result above reused a persistent Nix cache, so they show the archive assembly
and the derivation graph are stable, not that a from-scratch rebuild lands on
the same bytes.

Four of the six archives changed bytes during that series (the two external
Vulkan ones did not), so the next release needs a `releaseRevision` bump;
`release.sh` derives it from the published tags itself.

Closed, and kept here so the record is not re-opened by accident:

- **First clean builds** (was gap 1). Four release tags exist, `v21.1.23-r1`
  through `-r4`, each built and tested by the full CI matrix from a clean
  runner checkout.
- **aarch64 verification** (was gap 4). Both workflows build and test aarch64
  on native aarch64 runners, not emulation and not cross-compilation.
- **Pin GitHub Actions by commit SHA** (was gap 7). Every `uses:` reference in
  both workflows carries a commit SHA with the readable tag in a trailing
  comment; Dependabot maintains them. Do not add one by tag.
- **Pin the test containers by digest.** Alpine, Debian, and Ubuntu are named
  once each in `test/images.sh`, by digest, and `test/docker-image-pins.sh`
  keeps it that way. Note the honest limit recorded in that file: pinning bounds
  the base image only, and the external Vulkan test still installs packages from
  live Debian archives at run time.

## 12. Engineering principles

### Verify by running

Do not infer runtime behavior solely from Nix evaluation, compilation, or
source reading. Boot the actual packaged binary in the minimal target
environment. When fixing a bug, reproduce the old behavior and observe the
new behavior.

### Fail loudly

A missing license, stale patch, incomplete manifest, unsupported keymap,
dynamic link, or dead server should produce an explicit failure. Avoid
fallbacks that create a plausible-looking but incorrect artifact.

### Preserve reproducibility

Every input that affects shipped bytes should be pinned or generated
deterministically. Avoid ambient host tools, locale-dependent ordering,
unfixed timestamps, mutable download URLs, and release-asset replacement.

### Keep the runtime surface honest

The project's appeal is a bounded artifact with one executable. Do not add
runtime files “just in case.” If the contract genuinely expands, update the
manifest, smoke tests, README, release notes, and security/compliance analysis
together.

### Prefer upstream

Where practical, send generally useful fixes upstream and later consume the
upstream version. Keep local patches because they represent intentional
product behavior, not because patching is convenient.

### Treat security claims precisely

“Static” means no dynamic library dependency; it does not mean memory-safe,
sandboxed, vulnerability-free, or universally portable. Xvfb is an X server
and should still be bound, isolated, and access-controlled appropriately by
its caller.

## 13. Safe workspace and Git practices

- Inspect `git status` before editing.
- Existing uncommitted changes belong to the user unless proven otherwise.
- Avoid broad cleanup or destructive commands.
- Never discard files with `git checkout --`, `git reset --hard`, or
  recursive deletion merely to make tests clean.
- Build outputs belong only under ignored `out/` or Nix result links.
- Use temporary directories with narrow, project-specific names.
- Clean up only processes and containers you started and can identify.
- Make small, reviewable commits: build logic, patch behavior, dependency
  bumps, and documentation changes should be separable when practical.
- Never add generated release binaries to ordinary source commits unless the
  repository explicitly adopts that policy later.

## 14. Useful diagnostic commands

```sh
# Repository overview
git status --short
find . -maxdepth 3 -type f -print | sort

# Source-tree checks, matching the CI job and release.sh: shell syntax plus
# the documentation-consistency checks. Needs no build.
./test/repo-checks.sh

# Shell syntax alone. Note the loop: `bash -n a.sh b.sh` parses only a.sh and
# treats the rest as positional parameters, so it exits 0 on a broken b.sh.
for script in $(git ls-files '*.sh'); do bash -n "$script"; done

# Find accidental legacy branding or absolute paths. /src is included because
# it is the container mount point, and Nix files must not hardcode it: doing so
# makes them unevaluatable outside Docker. Hits inside build scripts and
# workflows, which legitimately construct the mount, are expected.
rg -n 'legacy-product-name|/workspace|/home/|/src' . --glob '!AGENTS.md'

# Inspect output
file out/x86_64/package/bin/Xvfb
tar -tvzf out/x86_64/xvfb-static-linux-x86_64.tar.gz
jq . out/x86_64/package/share/xvfb-static/manifest.json

# Check for dynamic linkage (both should indicate no dynamic dependency)
ldd out/x86_64/package/bin/Xvfb || true
readelf -l out/x86_64/package/bin/Xvfb | rg 'interpreter' || true

# Check embedded diagnostics/keymap guard strings
grep -a 'xvfb-static:' out/x86_64/package/bin/Xvfb

# Compare two independently saved builds
sha256sum build-a/xvfb-static-linux-x86_64.tar.gz
sha256sum build-b/xvfb-static-linux-x86_64.tar.gz
cmp build-a/xvfb-static-linux-x86_64.tar.gz \
    build-b/xvfb-static-linux-x86_64.tar.gz
```

## 15. Definition of done

A code or dependency change affecting shipped bytes is done only when:

1. the relevant source and patch logic have been reviewed;
2. every affected variant builds on both architectures from the pinned
   environment;
3. `test/archive-checks.sh` passes on every affected archive, and each fully
   static packaged Xvfb boots in the Alpine smoke test on its native
   architecture;
4. the failure path relevant to the change has been exercised;
5. static linkage and archive contents are inspected;
6. manifest and licensing output are complete;
7. documentation states any behavior or verification-status change;
8. both architectures are built when the change can affect shipped bytes;
9. reproducibility-sensitive inputs remain pinned;
10. no unsupported claim is made in README or release notes.

Documentation-only changes do not require a full binary rebuild unless they
alter instructions, version claims, provenance, licensing, or release facts
that can be checked only against an artifact.

## 16. Cold-start checklist for the next agent

1. Read `README.md` and this file completely.
2. Run `git status --short` and preserve user work.
3. Check section 11 against the commit history and open issues; close or
   restate anything newer evidence has changed.
4. Inspect the latest commit history and open issues.
5. Confirm Docker availability and architecture.
6. If touching shipped bytes, build and smoke-test before claiming success.
7. If touching dependencies or packaging, audit the static closure and
   license output.
8. Update this file when an important assumption, command, limitation, or
   verification status changes. Stale operational guidance is worse than a
   clearly stated gap.

The core invariant to preserve is simple: **one honestly described, fully
static Xvfb binary, reproducibly built from pinned sources, verified by
booting, and shipped with complete provenance and licensing material.**
