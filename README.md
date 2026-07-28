# xvfb-static

Reproducible, fully static Xvfb binaries for Linux. The release artifact has
no dynamic linker dependency and needs no host X11 packages or XKB data tree.

The build uses Nix `pkgsStatic` inside a digest-pinned Docker image. Nixpkgs,
X.Org X Server, its static dependencies, and the build tools are pinned by
`flake.lock`; archive ownership, ordering, locale, and timestamps are fixed.

> [!IMPORTANT]
> This build embeds a curated keyboard-profile catalog. Select a profile at
> startup with `-keyboard PROFILE`; arbitrary layouts and live switching remain
> unsupported. Use a distribution Xvfb if you need a conventional XKB installation.

## Keyboard profiles

Xvfb defaults to US QWERTY. Select one of the 28 embedded, precompiled profiles:

```sh
Xvfb :99 -keyboard de
```

```text
us          us-intl     gb          de          fr          es
latam       it          pt          br          pl          cz
tr          se          ru          ua          gr          il
ara         vn          be          ch          nl          dk
no          fi          rs          rs-latin
```

The catalog covers common Latin layouts plus Cyrillic, Greek, Hebrew, Arabic,
and Vietnamese input, but does not claim arbitrary XKB support.
Japanese, Korean, Chinese, and Indic text entry are deferred because their
normal input paths require composition or an input method; embedding a
physical layout alone would not provide honest language support.

See [the input architecture recommendations](docs/KEYBOARD-INPUT-ARCHITECTURE.md)
for profile selection, keystroke planning, injection, and
verification layers.

## Pointer scroll

The core/XTEST pointer advertises an XI2.1 `ScrollClass`: a horizontal and a
vertical scroll valuator, each with increment `120.0`. XI2.1-aware clients can
inject and observe scroll at valuator resolution instead of whole detents,
while clients that understand only core wheel buttons 4/5/6/7 keep working
unchanged — one legacy wheel click still moves the axis by exactly one
increment.

The release test suite verifies this against the XI2.1 protocol surface:
scroll-class presence, legacy wheel-button emulation, and valuator-injection
motion. That is the extent of the claim; how any given client maps valuator
units onto its own scroll model is outside this project.

The **no-GLX** artifacts disable GLX to minimize size and dependency surface.
Separate **GLX llvmpipe** artifacts embed Mesa llvmpipe for software-rendered,
indirect GLX without a host GPU driver or shared library. They are larger, and
otherwise carry the same guarantees: fully static, boot-tested in clean Alpine,
and render-tested on both architectures. Because llvmpipe renders in software,
the configuration CI exercises is the configuration you get.

An **external Vulkan GLX alpha** artifact takes the opposite tradeoff. It
statically incorporates Mesa Zink but deliberately opens the host's
`libvulkan.so.1`, allowing the Vulkan loader and installed ICD to expose a real
GPU. It contains no LLVM or llvmpipe. This variant is host-assisted rather than
fully static: it requires a glibc host, a Vulkan loader, and a usable ICD.

Its glibc floor is **2.28**. The binary is built against a manylinux_2_28
compatibility toolchain, and both the toolchain test and the release smoke test
fail if it imports any symbol newer than `GLIBC_2.28`. The floor is also
recorded in each archive's manifest as `glibc_symbol_floor`.

This variant is published, as an alpha. Its release tests prove the ABI floor,
the dynamic-dependency allowlist, a loud failure when the loader or an ICD is
missing, the absence of LLVM and of any software-renderer fallback, and
Zink render/readback — but that last one runs over lavapipe. **No test in this
project performs render/readback on an actual GPU**, so treat GPU support as
untested rather than proven, and validate it on your own hardware before
depending on it. See the
[implementation and validation plan](docs/GLX-EXTERNAL-VULKAN-PLAN.md).

## Download

Published GitHub Releases contain:

- `xvfb-static-no-glx-linux-x86_64.tar.gz`
- `xvfb-static-no-glx-linux-aarch64.tar.gz`
- `xvfb-static-glx-llvmpipe-linux-x86_64.tar.gz`
- `xvfb-static-glx-llvmpipe-linux-aarch64.tar.gz`
- `xvfb-static-glx-external-vulkan-alpha-linux-x86_64.tar.gz`
- `xvfb-static-glx-external-vulkan-alpha-linux-aarch64.tar.gz`
- `SHA256SUMS`

The external Vulkan archives are host-assisted alpha artifacts. They require a
glibc host with `libvulkan.so.1` and a compatible ICD; their release smoke test
proves Zink/Vulkan integration with lavapipe, not actual-GPU execution.

Each archive contains `bin/Xvfb`, a machine-readable manifest, and the exact
third-party license texts applicable to the binary. GLX manifests additionally
declare `"variant": "glx"`, their maturity, and the renderer
(`"llvmpipe"` or `"zink"`) so the experimental status and backend survive
renaming or extraction of the archive.

## Versions and releases

Release versions follow `v<upstream-xorg-version>-r<revision>`, for example
`v21.1.24-r1`. The first portion is the X.Org Server version that provides
Xvfb. The `r` suffix is this project's packaging revision and starts again at
`r1` when the upstream version changes. Changes to patches, dependencies, the
toolchain, or packaging that produce new release bytes increment the revision.
The complete release version and numeric revision are also recorded in each
archive's manifest. The revision is maintained in `package-no-glx.nix` and must match
the release tag.

Maintainers prepare a release from a clean `main` checkout with:

```sh
./release.sh
```

The helper fetches GitHub tags, derives the pinned upstream version, selects
the next revision, updates and commits `package-no-glx.nix` when necessary, creates a
signed annotated tag using the maintainer's configured Git signing key, and
atomically pushes `main` and the tag to GitHub. In a terminal it previews the
version and requires confirmation. Use `./release.sh --dry-run` to preview
without changing files, commits, tags, or remote branches.

Pushing a matching tag builds and smoke-tests the no-GLX, GLX llvmpipe,
and GLX external Vulkan alpha variants for x86_64 and aarch64 on native
GitHub-hosted runners. The GLX tests render and read pixels back for
verification; the external Vulkan test uses lavapipe for integration coverage
and does not establish actual-GPU support. If all six artifacts match the tag
and pass, the workflow publishes them with a combined `SHA256SUMS` file as an
immutable GitHub Release. Every archive receives a signed build-provenance
attestation.
The exact Nixpkgs revision remains recorded separately in `flake.lock` and the
release notes.

## Build

Docker is the only host prerequisite:

```sh
./build-no-glx.sh
./test/static-smoke.sh
```

With no argument, both scripts select the host architecture. You can pass
`x86_64` or `aarch64` to `build-no-glx.sh`, and an explicit archive path to the
smoke test. Output is written under `out/no-glx/<architecture>/`.

You can also build the native package with an existing flakes-enabled Nix
installation:

```sh
nix build .#default
```

Build and test the native GLX llvmpipe artifact with:

```sh
./build-glx-llvmpipe.sh x86_64
./test/static-smoke.sh out/glx-llvmpipe/x86_64/xvfb-static-glx-llvmpipe-linux-x86_64.tar.gz
./test/glx-llvmpipe-smoke.sh out/glx-llvmpipe/x86_64/xvfb-static-glx-llvmpipe-linux-x86_64.tar.gz
```

The explicit architecture names accepted by `build-glx-llvmpipe.sh` are `x86_64` and
`aarch64`, matching `build-no-glx.sh`.

The external Vulkan alpha build uses an equivalently explicit
`build-glx-external-vulkan.sh` entry point and writes under
`out/glx-external-vulkan-alpha/<architecture>/`:

```sh
./build-glx-external-vulkan.sh x86_64
archive=out/glx-external-vulkan-alpha/x86_64/xvfb-static-glx-external-vulkan-alpha-linux-x86_64.tar.gz
./test/archive-checks.sh "$archive"
./test/glx-external-vulkan-smoke.sh "$archive"
```

Note that `test/static-smoke.sh` does not apply to this variant: it asserts static
linkage and boots in Alpine, and this artifact is host-assisted and needs
glibc. `test/archive-checks.sh` holds the checks that are common to every
variant, and `test/static-smoke.sh` runs it first. The external Vulkan runtime test
must run on a glibc distribution with `libvulkan.so.1` and an installed Vulkan
ICD; it uses a lavapipe runtime for Zink integration coverage, which is not
actual-GPU coverage.

## Verify a download

```sh
sha256sum --check SHA256SUMS
gh attestation verify xvfb-static-no-glx-linux-x86_64.tar.gz \
  --repo shkolnik/xvfb-static
tar -xzf xvfb-static-no-glx-linux-x86_64.tar.gz
file bin/Xvfb
bin/Xvfb -version
```

The checksum detects altered bytes. The attestation verifies that the archive
was produced by this repository's release workflow from its tagged commit.
`file` should report `statically linked`. The smoke test additionally boots the
server in a clean Alpine container with no X11 packages.

For a GLX llvmpipe download, substitute its full filename in both checksum and
attestation commands. Its manifest should identify the `glx` variant, `stable`
maturity, llvmpipe renderer, and pinned Mesa and LLVM versions.

An external Vulkan alpha download is host-assisted, so `file` reports a dynamic
executable and `bin/Xvfb -version` needs a host Vulkan loader. Its manifest
identifies the `zink` renderer and records `glibc_symbol_floor`; check that
against your host with `ldd --version`.

## Why the X server is patched

Stock Xvfb loads XKB rules and invokes `xkbcomp` at runtime. That prevents a
single-file distribution. This project compiles the curated profile catalog
during the build and embeds the resulting XKM data in Xvfb. The patches also make the
unsupported dynamic-keymap path fail explicitly instead of silently choosing
a different layout.

No upstream source is vendored. Patches are applied to the exact X.Org source
pinned transitively by `flake.lock`.

## Diagnostics

Xvfb does not create a log file. Its diagnostics remain on standard error
(with command output on standard output), so supervisors should capture those
streams. Runtime messages introduced by this project carry a stable component
prefix, for example:

```text
[xvfb-static:xserver] selected keyboard profile: ru
[xvfb-static:xkb] embedded keyboard profile 'ru' failed to load
```

The prefix identifies project-owned integration code; it does not rewrite
messages emitted by upstream Xserver code or intercept direct writes from
third-party libraries. Future statically linked GLX components should add
their own prefixes, such as `mesa` and `zink`, at their logging boundaries.

## Security and updates

Static linking moves dependency-update responsibility from the host package
manager to this project. See [SECURITY.md](SECURITY.md). Dependency refreshes
must update `flake.lock`, rebuild both architectures, run the smoke tests, and
publish new checksums. Releases should never replace assets in place; every
new byte set gets a new immutable version tag.

## Licensing

Original build code and patches are Apache-2.0 licensed. Xvfb and its linked
dependencies retain their respective licenses. Every archive carries the
relevant texts; see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
