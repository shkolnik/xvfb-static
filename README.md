# static-xvfb

Reproducible, fully static Xvfb binaries for Linux. The release artifact has
no dynamic linker dependency and needs no host X11 packages or XKB data tree.

The build uses Nix `pkgsStatic` inside a digest-pinned Docker image. Nixpkgs,
X.Org X Server, its static dependencies, and the build tools are pinned by
`flake.lock`; archive ownership, ordering, locale, and timestamps are fixed.

> [!IMPORTANT]
> This build embeds one keyboard layout: `evdev` / `pc105` / `us`. Runtime
> keymap selection is intentionally unsupported. Use a distribution Xvfb if
> you need arbitrary layouts or a conventional XKB installation.

GLX is disabled because its GLVND implementation requires shared libraries
and is incompatible with this project's fully static artifact contract.

## Download

Published GitHub Releases will contain:

- `static-xvfb-linux-x86_64.tar.gz`
- `static-xvfb-linux-aarch64.tar.gz`
- `SHA256SUMS`

Each archive contains `bin/Xvfb`, a machine-readable manifest, and the exact
third-party license texts applicable to the binary.

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

Pushing a matching tag builds and smoke-tests x86_64 and aarch64 on native
GitHub-hosted runners. If both pass and the version in each artifact matches
the tag, the workflow publishes both archives and a combined `SHA256SUMS` file
as an immutable GitHub Release. Both archives receive signed build-provenance
attestations. The exact Nixpkgs revision remains recorded separately in
`flake.lock` and the release notes.

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

## Verify a download

```sh
sha256sum --check SHA256SUMS
gh attestation verify static-xvfb-linux-x86_64.tar.gz \
  --repo shkolnik/xvfb-static
tar -xzf static-xvfb-linux-x86_64.tar.gz
file bin/Xvfb
bin/Xvfb -version
```

The checksum detects altered bytes. The attestation verifies that the archive
was produced by this repository's release workflow from its tagged commit.
`file` should report `statically linked`. The smoke test additionally boots the
server in a clean Alpine container with no X11 packages.

## Why the X server is patched

Stock Xvfb loads XKB rules and invokes `xkbcomp` at runtime. That prevents a
single-file distribution. This project compiles a fixed US keymap during the
build and embeds the resulting XKM data in Xvfb. The patches also make the
unsupported dynamic-keymap path fail explicitly instead of silently choosing
a different layout.

No upstream source is vendored. Patches are applied to the exact X.Org source
pinned transitively by `flake.lock`.

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
