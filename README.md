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

## Download

Published GitHub Releases will contain:

- `static-xvfb-linux-x86_64.tar.gz` (built and boot-tested on x86_64)
- `static-xvfb-linux-aarch64.tar.gz` (cross-built; see the release notes for
  its runtime-verification status)
- `SHA256SUMS`

Each archive contains `bin/Xvfb`, a machine-readable manifest, and the exact
third-party license texts applicable to the binary.

## Build

Docker is the only host prerequisite:

```sh
./build.sh x86_64
./test/smoke.sh out/x86_64/static-xvfb-linux-x86_64.tar.gz
```

The output is written under `out/<architecture>/`. You can also build with an
existing flakes-enabled Nix installation:

```sh
NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1 nix build .#static-xvfb-x86_64 --impure
```

## Verify a download

```sh
sha256sum --check SHA256SUMS
tar -xzf static-xvfb-linux-x86_64.tar.gz
file bin/Xvfb
bin/Xvfb -version
```

`file` should report `statically linked`. The smoke test additionally boots
the server in a clean Alpine container with no X11 packages.

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

