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

The standard artifacts disable GLX to minimize size and dependency surface.
Separate **GLX llvmpipe alpha** artifacts embed Mesa llvmpipe for software-rendered,
indirect GLX without a host GPU driver or shared library. They are larger and
remain explicitly experimental while their compatibility receives broader
testing.

An **external Vulkan GLX alpha** prototype takes the opposite tradeoff. It
statically incorporates Mesa Zink but deliberately opens the host's
`libvulkan.so.1`, allowing the Vulkan loader and installed ICD to expose a real
GPU. It contains no LLVM or llvmpipe and is expected to be substantially
smaller than the llvmpipe artifact. This variant is host-assisted rather than
fully static: it requires a compatible glibc host, Vulkan loader, and usable
ICD. The intended compatibility floor is glibc 2.31, but that is not yet a
published guarantee while the build toolchain and symbol-version gate are
being completed.

The external Vulkan prototype is not a release asset. Publication remains
blocked until native render/readback succeeds on actual x86_64 and aarch64
GPUs, with tests proving that no software renderer was selected. See the
[implementation and validation plan](docs/GLX-EXTERNAL-VULKAN-PLAN.md).

## Download

Published GitHub Releases will contain:

- `xvfb-static-linux-x86_64.tar.gz`
- `xvfb-static-linux-aarch64.tar.gz`
- `xvfb-static-glx-llvmpipe-alpha-linux-x86_64.tar.gz`
- `xvfb-static-glx-llvmpipe-alpha-linux-aarch64.tar.gz`
- `SHA256SUMS`

`xvfb-static-glx-external-vulkan-alpha-linux-<arch>.tar.gz` is reserved for
the host-assisted prototype and is intentionally excluded from this release
list until its two-architecture hardware gate passes.

Each archive contains `bin/Xvfb`, a machine-readable manifest, and the exact
third-party license texts applicable to the binary. GLX manifests additionally
declare `"variant": "glx"`, `"maturity": "alpha"`, and
`"renderer": "llvmpipe"` so the experimental status survives renaming or
extraction of the archive.

## Versions and releases

Release versions follow `v<upstream-xorg-version>-r<revision>`, for example
`v21.1.20-r1`. The first portion is the X.Org Server version that provides
Xvfb. The `r` suffix is this project's packaging revision and starts again at
`r1` when the upstream version changes. Changes to patches, dependencies, the
toolchain, or packaging that produce new release bytes increment the revision.
The complete release version and numeric revision are also recorded in each
archive's manifest. The revision is maintained in `package.nix` and must match
the release tag.

Maintainers prepare a release from a clean `main` checkout with:

```sh
./release.sh
```

The helper fetches GitHub tags, derives the pinned upstream version, selects
the next revision, updates and commits `package.nix` when necessary, creates a
signed annotated tag using the maintainer's configured Git signing key, and
atomically pushes `main` and the tag to GitHub. In a terminal it previews the
version and requires confirmation. Use `./release.sh --dry-run` to preview
without changing files, commits, tags, or remote branches.

Pushing a matching tag builds and smoke-tests the standard and GLX llvmpipe alpha
variants for x86_64 and aarch64 on native GitHub-hosted runners. The GLX tests
create an indirect context with llvmpipe, render two colors, and read pixels
back for verification. If all four artifacts match the tag and pass, the
workflow publishes them with a combined `SHA256SUMS` file as an immutable
GitHub Release. Every archive receives a signed build-provenance attestation.
The exact Nixpkgs revision remains recorded separately in `flake.lock` and the
release notes.

## Build

Docker is the only host prerequisite:

```sh
./build.sh
./test/smoke.sh
```

With no argument, both scripts select the host architecture. You can pass
`x86_64` or `aarch64` to `build.sh`, and an explicit archive path to the smoke
test. Output is written under `out/<architecture>/`.

You can also build the native package with an existing flakes-enabled Nix
installation:

```sh
NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1 nix build .#default --impure
```

Build and test the native GLX llvmpipe alpha artifact with:

```sh
./build-glx-llvmpipe.sh x86_64
./test/smoke.sh out/glx-llvmpipe-alpha/x86_64/xvfb-static-glx-llvmpipe-alpha-linux-x86_64.tar.gz
./test/glx-llvmpipe-smoke.sh out/glx-llvmpipe-alpha/x86_64/xvfb-static-glx-llvmpipe-alpha-linux-x86_64.tar.gz
```

The explicit architecture names accepted by `build-glx-llvmpipe.sh` are `x86_64` and
`aarch64`, matching `build.sh`.

The external Vulkan alpha build, when enabled in the current checkout, uses an
equivalently explicit `build-glx-external-vulkan.sh` entry point and writes
under `out/glx-external-vulkan-alpha/<architecture>/`. Its runtime test must
run on a glibc distribution with `libvulkan.so.1` and an installed Vulkan ICD;
the ordinary fully static Alpine contract does not apply to this variant. The
smoke test uses a newer Mesa lavapipe runtime only for Zink integration
coverage; actual-GPU render/readback is still required before publication.

## Verify a download

```sh
sha256sum --check SHA256SUMS
gh attestation verify xvfb-static-linux-x86_64.tar.gz \
  --repo shkolnik/xvfb-static
tar -xzf xvfb-static-linux-x86_64.tar.gz
file bin/Xvfb
bin/Xvfb -version
```

The checksum detects altered bytes. The attestation verifies that the archive
was produced by this repository's release workflow from its tagged commit.
`file` should report `statically linked`. The smoke test additionally boots the
server in a clean Alpine container with no X11 packages.

For a GLX llvmpipe alpha download, substitute its full filename in both checksum and
attestation commands. Its manifest should identify the `glx` variant, `alpha`
maturity, llvmpipe renderer, and pinned Mesa and LLVM versions.

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
