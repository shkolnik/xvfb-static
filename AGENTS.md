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

The project has passed static checks: shell parsing, executable-bit checks,
path and branding scans, and patch/build-file consistency inspection.

- The two X.Org patches in this repository have previously been used to build
  and boot a static x86_64 Xvfb.
- This repository has **not yet been built end-to-end from a clean checkout**.
  Treat clean native builds and Alpine smoke tests for both architectures as
  the immediate pre-publication gate. Do not erase this caveat until you
  personally run the commands and observe them pass.
- x86_64 and aarch64 are configured as native sibling builds. On 2026-07-21,
  the curated-profile branch built and passed its Alpine smoke and 28-profile
  Nix integration checks on native Apple-silicon aarch64 Docker. The workspace
  was not a clean checkout, so this does not close the clean-build gate above.
- The GLX llvmpipe and external Vulkan work is alpha-stage. The external
  Vulkan variant is a host-assisted prototype and is not release-eligible
  until actual-GPU render/readback passes natively on both architectures.

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
- timestamps use a fixed `SOURCE_DATE_EPOCH` value;
- the resulting archive receives a SHA-256 checksum.

The GLX variants preserve the one-executable package shape but have distinct
runtime contracts:

- `xvfb-static-glx-llvmpipe-alpha` statically incorporates Mesa llvmpipe and
  LLVM and remains fully static;
- `xvfb-static-glx-external-vulkan-alpha` statically incorporates Mesa Zink
  but opens the host's `libvulkan.so.1`. It is host-assisted, contains no LLVM
  or software-renderer fallback, and requires a compatible glibc host, Vulkan
  loader, and ICD.

The intended external-Vulkan host floor is glibc 2.31. Do not encode or
advertise that as a minimum until the build toolchain, `GLIBC_*` symbol audit,
and Debian 11 runtime test prove it. Keep `alpha` synchronized across names,
manifests, documentation, CI, and release metadata.

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

| Path | Purpose |
|---|---|
| `README.md` | Public user-facing overview, installation/build instructions, limitations, and licensing summary. |
| `AGENTS.md` | Maintainer and agent cold-start guide; operational truth and maintenance invariants. |
| `flake.nix` | Defines symmetric native x86_64 and aarch64 package outputs. |
| `flake.lock` | Exact nixpkgs revision and content hash. This transitively pins X.Org and linked dependencies. |
| `package.nix` | Core build: static-libxcvt workaround, embedded keymap, Xvfb override, stripping, license extraction, and manifest generation. |
| `build.sh` | Docker-only entry point and reproducible archive/checksum assembly. |
| `mesa-llvmpipe.nix` / `package-glx-llvmpipe.nix` | Fully static Mesa llvmpipe/LLVM and GLX Xvfb alpha build. |
| `build-glx-llvmpipe.sh` | Deterministic llvmpipe GLX alpha archive entry point. |
| `mesa-zink.nix` / `package-glx-external-vulkan.nix` | Host-assisted external Vulkan/Zink alpha build; filenames may appear as the prototype lands. |
| `build-glx-external-vulkan.sh` | Deterministic external Vulkan GLX alpha archive entry point. |
| `cachix.nix` | Resolves the Cachix client from the exact nixpkgs revision in `flake.lock`. |
| `nix-build-cached.sh` | In-container build wrapper: configures public cache reads and pushes new paths when authenticated. |
| `release.sh` | Local maintainer helper that selects the next release revision, commits it when needed, creates a signed tag, and atomically pushes it to GitHub. |
| `patches/xserver-0001-xkb-env-overrides.patch` | Makes the legacy xkbcomp path shell-free and adds explicit path overrides. Retained even though the embedded-keymap path makes it normally unreachable. |
| `patches/xserver-0002-embedded-keymap.patch` | Selects and loads a compiled XKM blob from memory, bypasses runtime rules lookup/xkbcomp, and rejects unsupported string-keymap compilation. |
| `patches/xserver-0003-keyboard-profile-option.patch` | Adds the Xvfb-only `-keyboard PROFILE` startup selector. |
| `patches/xserver-0004-component-log-prefixes.patch` | Adds stable component labels to project-owned Xserver and XKB diagnostics. |
| `test/smoke.sh` | Extracts the archive, checks its shape/static linkage, and boots Xvfb inside clean Alpine. |
| `test/glx-llvmpipe-smoke.sh` | Verifies indirect llvmpipe GLX render/readback without host graphics libraries. |
| `test/glx-external-vulkan-smoke.sh` | Verifies the host-assisted ABI and Zink render/readback; use a glibc environment, not Alpine. |
| `docs/KEYBOARD-INPUT-ARCHITECTURE.md` | General recommendations for profile-aware Unicode-to-physical-key input. |
| `docs/GLX-EXTERNAL-VULKAN-PLAN.md` | External Vulkan architecture, ABI, tests, compatibility policy, and release gates. |
| `THIRD-PARTY-NOTICES.md` | Explains artifact licensing and pinned-source provenance. |
| `LICENSE` / `NOTICE` | Apache-2.0 licensing for original project code and patches; not a blanket license for Xvfb. |
| `SECURITY.md` | Supported-version and private-reporting policy. |
| `CONTRIBUTING.md` | Public contribution expectations and minimum local gates. |
| `.github/workflows/ci.yml` | Builds and smoke-tests both architectures on native runners, then uploads ephemeral CI artifacts. |
| `.github/workflows/release.yml` | Validates `v<upstream>-r<revision>` tags, builds and smoke-tests both native architectures, attests both archives, and publishes them with combined checksums. |
| `.github/dependabot.yml` | Monthly GitHub Actions update checks. It does not update Nix inputs. |
| `out/` | Ignored local build products. Never treat these as source. |

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

The build currently needs
`NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1` and `--impure`. This is not a
general request to ignore unsupported software. It narrowly permits evaluation
of nixpkgs' static-platform block on `libxcvt` after this project replaces
its hard-coded Meson `shared_library()` with `library()`, which honors
the static toolchain.

### Layer 2: static Xvfb derivation

`package.nix` starts with nixpkgs' top-level Xvfb-only X.Org server variant rather
than re-creating the X server configuration flags. It:

1. makes `libxcvt` build as a static archive;
2. replaces the stock `libxcvt` input with that corrected derivation;
3. applies both local X.Org patches;
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
NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1 \
  nix build .#xvfb-static-x86_64 --impure
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

Make temporary regressions surgically and revert only your own changes. Never
use broad destructive Git commands in a dirty working tree.

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
5. Confirm both patches still apply in their listed order.
6. Rebuild the production binary.
7. Run the clean-container boot test.
8. Exercise the failure path, not only the happy path.
9. Record any behavior change in `README.md` and this file.

Patch 0001 precedes patch 0002 because patch 0002 was authored against a tree
with patch 0001 already applied. Patch 0003 then connects the VFB-only parser
to the embedded loader. Patch 0004 labels the diagnostics introduced by the
preceding patches and must remain last. Do not reorder them casually.

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

Dependabot covers GitHub Actions only. It does not monitor nixpkgs or the
static dependency closure. Add automated vulnerability/update monitoring
later if it can be made signal-rich and reviewable, but never mistake a bot's
green status for a closure audit.

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

CI builds and smoke-tests x86_64 and aarch64 on matching native runners, then
uploads ephemeral workflow artifacts. Tags matching
`v<upstream-xorg-version>-r<positive-revision>` trigger the release workflow.
The upstream portion must match the X.Org Server version in both artifact
manifests, and the full tag must match the manifest's xvfb-static version. The
project revision is maintained as `releaseRevision` in `package.nix`, starts at
`r1`, increments whenever new bytes are released for the same upstream
version, and resets to `r1` when upstream changes.

Run `./release.sh` from a clean local `main` checkout to prepare and push a
release. It derives the upstream version through the same digest-pinned Nix
Docker image as `build.sh`, considers tags already present on GitHub, and
updates only `releaseRevision`. Interactive runs require confirmation;
`--dry-run` previews without changing source, commits, tags, or remote
branches. Keep the Docker image digest in `release.sh` synchronized with
`build.sh` whenever the build environment changes.

The release workflow:

- triggers from an intentional version tag;
- builds x86_64 and aarch64 from the tagged commit;
- boot-tests both artifacts in Alpine on matching native runners;
- uploads both archives and one unambiguous checksum file;
- identifies the X.Org version, nixpkgs revision, architectures,
  embedded-layout limitation, and verification status;
- generates Sigstore-backed GitHub build-provenance attestations for both
  archives before publication;
- gives build jobs only source-read plus attestation, artifact-metadata, and
  OIDC permissions, while the publishing job receives artifact-read and
  release-write permissions;
- uses `gh release create --verify-tag` so publication cannot synthesize a
  missing tag.

Immutable releases are enabled in the GitHub repository settings. Published
release assets and their tags cannot be replaced in place. Action references
should eventually be pinned by commit SHA for stronger supply-chain hygiene.

Do not claim an architecture is “verified” when it was only cross-compiled.
Use precise language: built, statically inspected, emulated, or executed on
real hardware.

The external Vulkan alpha may be built and uploaded as an ephemeral CI
artifact while it is being validated, but release publication must remain
disabled or explicitly guarded. Enable it only after native actual-GPU
render/readback passes on x86_64 and aarch64, renderer evidence excludes all
software devices, and each result records the GPU, kernel, Vulkan loader, ICD,
Mesa version, and architecture. A Zink-over-lavapipe CI test is useful
integration coverage but does not satisfy this hardware gate.

## 11. Known gaps and next recommended work

In priority order:

1. **Run the first clean builds.** Fix any build issues, then run
   `test/smoke.sh` natively on both architectures and inspect both archives
   manually.
2. **Validate compliance against the actual closure.** Confirm every linked or
   incorporated component and its required notices.
3. **Prove reproducibility.** Build twice from clean output directories (and
   ideally on two hosts) and compare archive SHA-256 values. A persistent Nix
   cache is fine; source output state must not leak between attempts.
4. **Verify aarch64.** Record the first successful native build and smoke test.
5. **Validate external Vulkan on hardware.** Prove the glibc ABI floor and
   dependency allowlist, loud missing-loader/no-ICD failures, absence of LLVM
   and software fallback, the expected size reduction, and native actual-GPU
   pixel readback on both architectures before publication.
6. **Consider an SPDX or CycloneDX SBOM.** It should describe the actual
   static closure and complement, not replace, license texts.
7. **Pin GitHub Actions by commit SHA.** Dependabot can maintain those pins.

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

# Shell syntax
bash -n build.sh test/smoke.sh

# Find accidental legacy branding or absolute paths
rg -n 'legacy-product-name|/workspace|/home/' . --glob '!AGENTS.md'

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
2. both architecture artifacts build from the pinned environment;
3. each actual packaged Xvfb boots in the Alpine smoke test on its native
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
3. Determine whether the first standalone build gap in section 2 has been
   closed by newer committed evidence.
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
