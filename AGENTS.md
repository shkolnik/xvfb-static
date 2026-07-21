# AGENTS.md — static-xvfb project guide

This file is the cold-start guide for humans and coding agents working on this
repository. Read it completely before changing build inputs, patches, artifact
contents, tests, licensing material, or release automation.

## 1. Project in one paragraph

`static-xvfb` builds reproducible, fully statically linked Xvfb executables for
Linux. A release archive should run without a host dynamic linker, X11
packages, `xkbcomp`, or an XKB data tree. The build is driven by Nix
`pkgsStatic` inside a digest-pinned Docker image. The X.Org source and all
dependencies are pinned through `flake.lock`. A fixed US keyboard map is
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
  Treat the first clean x86_64 build and Alpine smoke test as the immediate
  pre-publication gate. Do not erase this caveat until you personally run the
  commands and observe them pass.
- aarch64 is cross-built from x86_64. Unless newer evidence is recorded here,
  it has not been executed on real aarch64 hardware.

This repository must stay understandable, buildable, testable, and legally
distributable on its own.

## 3. Product contract

### What the artifact promises

A release archive contains:

- `bin/Xvfb` — a stripped, fully static Linux executable;
- `share/static-xvfb/manifest.json` — architecture, component version,
  schema version, and an exact file inventory;
- `share/static-xvfb/licenses/` — third-party license texts extracted from
  the exact pinned sources used by the build.

The archive itself is deterministic given the same declared inputs:

- Nix inputs are locked;
- the build container is pinned by digest;
- tar entries use byte-order sorting;
- owner and group are fixed to numeric zero;
- timestamps use a fixed `SOURCE_DATE_EPOCH` value;
- the resulting archive receives a SHA-256 checksum.

### Intentional capability reduction

The binary supports exactly this embedded XKB profile:

- rules: `evdev`
- model: `pc105`
- layout: `us`

Runtime keymap selection is intentionally unsupported. The artifact does not
ship `xkbcomp` or `share/X11/xkb`. Requests that would require compiling
another keymap must fail rather than silently booting with the embedded US
layout.

This limitation is central to the single-file runtime design. Do not broaden,
hide, or remove it casually. If general keyboard-layout support becomes a
goal, treat that as a product-design change and compare at least:

1. shipping `xkbcomp` plus an XKB data tree;
2. embedding several named precompiled layouts with an explicit selector;
3. publishing separate layout-specific artifacts;
4. abandoning the single-file promise and using a conventional Xvfb package.

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
| `flake.nix` | Defines native x86_64 and cross-compiled aarch64 package outputs. |
| `flake.lock` | Exact nixpkgs revision and content hash. This transitively pins X.Org and linked dependencies. |
| `package.nix` | Core build: static-libxcvt workaround, embedded keymap, Xvfb override, stripping, license extraction, and manifest generation. |
| `build.sh` | Docker-only entry point and reproducible archive/checksum assembly. |
| `patches/xserver-0001-xkb-env-overrides.patch` | Makes the legacy xkbcomp path shell-free and adds explicit path overrides. Retained even though the embedded-keymap path makes it normally unreachable. |
| `patches/xserver-0002-embedded-keymap.patch` | Loads the compiled XKM blob from memory, bypasses runtime rules lookup/xkbcomp, and rejects unsupported string-keymap compilation. |
| `test/smoke.sh` | Extracts the archive, checks its shape/static linkage, and boots Xvfb inside clean Alpine. |
| `THIRD-PARTY-NOTICES.md` | Explains artifact licensing and pinned-source provenance. |
| `LICENSE` / `NOTICE` | Apache-2.0 licensing for original project code and patches; not a blanket license for Xvfb. |
| `SECURITY.md` | Supported-version and private-reporting policy. |
| `CONTRIBUTING.md` | Public contribution expectations and minimum local gates. |
| `.github/workflows/ci.yml` | Builds and smoke-tests x86_64 on pushes and pull requests, then uploads an ephemeral CI artifact. |
| `.github/dependabot.yml` | Monthly GitHub Actions update checks. It does not update Nix inputs. |
| `out/` | Ignored local build products. Never treat these as source. |

## 5. How the build works

### Layer 1: pinned environment

`build.sh` starts a digest-pinned `nixos/nix` container and mounts:

- the repository at `/src`;
- a named Docker volume, `static-xvfb-nix`, at `/nix` for build-cache
  reuse.

The host needs only Docker. Files created as root in the container are handed
back to the invoking host UID/GID before exit.

The build currently needs
`NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1` and `--impure`. This is not a
general request to ignore unsupported software. It narrowly permits evaluation
of nixpkgs' static-platform block on `libxcvt` after this project replaces
its hard-coded Meson `shared_library()` with `library()`, which honors
the static toolchain.

### Layer 2: static Xvfb derivation

`package.nix` starts with nixpkgs' Xvfb-only X.Org server variant rather
than re-creating the X server configuration flags. It:

1. makes `libxcvt` build as a static archive;
2. replaces the stock `libxcvt` input with that corrected derivation;
3. applies both local X.Org patches;
4. generates a fixed XKB source description;
5. compiles it once with the build-platform `xkbcomp`;
6. converts the XKM bytes into a generated C array;
7. compiles that array into Xvfb;
8. copies and strips only `bin/Xvfb` into the output.

The keymap compiler and XKB source data are build-time inputs only.

### Layer 3: attribution and manifest

The package derivation extracts license files from pinned Nix source
derivations, not from mutable web URLs. Missing, ambiguous, or empty license
matches fail the build.

The manifest lists every packaged file including itself. If packaging changes,
the manifest and the smoke test should be updated together.

### Layer 4: deterministic release archive

`build.sh` dereferences the Nix result, creates
`static-xvfb-linux-<arch>.tar.gz`, and writes `SHA256SUMS`. Local
outputs live under `out/<arch>/` and are ignored by Git.

## 6. Normal development workflow

From a clean checkout:

```sh
./build.sh x86_64
./test/smoke.sh out/x86_64/static-xvfb-linux-x86_64.tar.gz
```

Then inspect rather than trusting a green exit status alone:

```sh
tar -tzf out/x86_64/static-xvfb-linux-x86_64.tar.gz
file out/x86_64/package/bin/Xvfb
jq . out/x86_64/package/share/static-xvfb/manifest.json
find out/x86_64/package/share/static-xvfb/licenses -type f -maxdepth 1 -print
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
  nix build .#static-xvfb-x86_64 --impure
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
with patch 0001 already applied. Do not reorder them casually.

The embedded-keymap patch uses `fmemopen()`, available in musl, to feed the
XKM parser without a filesystem temporary. It intentionally makes the fixed
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

Do not vendor or locally modify third-party source casually. The current model
is: exact upstream source from pinned nixpkgs plus clearly separated local
patches. If third-party source is vendored later, document its precise
upstream repository, tag, commit, hashes, license, and modification status.

This section is an engineering compliance policy, not legal advice. Escalate
uncertain licensing questions rather than silently optimizing notices away.

## 10. CI and release expectations

Current CI builds and smoke-tests x86_64, then uploads a workflow artifact.
That artifact is ephemeral and is not a public GitHub Release.

Before the first public release, add or verify a release workflow with these
properties:

- it triggers from an intentional version tag or manual release action;
- it builds x86_64 and aarch64 from the tagged commit;
- x86_64 receives the real Alpine boot test;
- aarch64's execution status is stated loudly and accurately;
- both archives and one unambiguous checksum file are uploaded;
- release notes identify the X.Org version, nixpkgs revision, architectures,
  embedded-layout limitation, and verification status;
- the workflow uses least-privilege GitHub permissions;
- releases and their assets are immutable;
- action references should eventually be pinned by commit SHA for stronger
  supply-chain hygiene.

Do not claim an architecture is “verified” when it was only cross-compiled.
Use precise language: built, statically inspected, emulated, or executed on
real hardware.

## 11. Known gaps and next recommended work

In priority order:

1. **Run the first clean x86_64 build.** Fix any build issues, then run
   `test/smoke.sh` and inspect the archive manually.
2. **Validate compliance against the actual closure.** Confirm every linked or
   incorporated component and its required notices.
3. **Prove reproducibility.** Build twice from clean output directories (and
   ideally on two hosts) and compare archive SHA-256 values. A persistent Nix
   cache is fine; source output state must not leak between attempts.
4. **Add a real release workflow.** Current CI does not publish releases.
5. **Build aarch64.** Record whether cross-compilation succeeds.
6. **Run aarch64.** Prefer real hardware; otherwise label emulation honestly.
7. **Add explicit negative tests.** Pin the absence of runtime XKB files and
   the refusal/failure behavior for unsupported keymap paths.
8. **Consider an SPDX or CycloneDX SBOM.** It should describe the actual
   static closure and complement, not replace, license texts.
9. **Pin GitHub Actions by commit SHA.** Dependabot can maintain those pins.
10. **Choose and document the initial versioning policy.** Semantic Versioning
    is reasonable: artifact-contract changes are major, dependency rebuilds
    with unchanged behavior are patch releases, and compatible additions are
    minor releases.

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
tar -tvzf out/x86_64/static-xvfb-linux-x86_64.tar.gz
jq . out/x86_64/package/share/static-xvfb/manifest.json

# Check for dynamic linkage (both should indicate no dynamic dependency)
ldd out/x86_64/package/bin/Xvfb || true
readelf -l out/x86_64/package/bin/Xvfb | rg 'interpreter' || true

# Check embedded diagnostics/keymap guard strings
grep -a 'static-xvfb:' out/x86_64/package/bin/Xvfb

# Compare two independently saved builds
sha256sum build-a/static-xvfb-linux-x86_64.tar.gz
sha256sum build-b/static-xvfb-linux-x86_64.tar.gz
cmp build-a/static-xvfb-linux-x86_64.tar.gz \
    build-b/static-xvfb-linux-x86_64.tar.gz
```

## 15. Definition of done

A code or dependency change affecting shipped bytes is done only when:

1. the relevant source and patch logic have been reviewed;
2. the x86_64 artifact builds from the pinned environment;
3. the actual packaged Xvfb boots in the Alpine smoke test;
4. the failure path relevant to the change has been exercised;
5. static linkage and archive contents are inspected;
6. manifest and licensing output are complete;
7. documentation states any behavior or verification-status change;
8. aarch64 is built when the change can affect it;
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
