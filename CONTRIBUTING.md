# Contributing

Issues and pull requests are welcome. Please keep changes narrowly scoped and
explain the user-visible reason for them.

## Before submitting a pull request

Always, on any change:

```sh
./test/repo-checks.sh
```

That parses every tracked shell script and checks the documentation against
the files, counts, and version floors it describes. It needs no build and
takes about a second.

If your change can affect shipped bytes, build and test **every variant it
touches**. CI runs a 3-variant × 2-architecture matrix — no-GLX, GLX
llvmpipe, and GLX external Vulkan alpha, each on x86_64 and aarch64 —
so a green `build-no-glx.sh` plus `static-smoke.sh` is not the gate. It is one cell
of six.

For the no-GLX variant:

```sh
./build-no-glx.sh x86_64
./test/static-smoke.sh out/no-glx/x86_64/xvfb-static-no-glx-linux-x86_64.tar.gz
```

For the GLX llvmpipe variant:

```sh
./build-glx-llvmpipe.sh x86_64
archive=out/glx-llvmpipe/x86_64/xvfb-static-glx-llvmpipe-linux-x86_64.tar.gz
./test/static-smoke.sh "$archive"
./test/glx-llvmpipe-smoke.sh "$archive"
```

For the GLX external Vulkan alpha variant — note that `test/static-smoke.sh` does
**not** apply, because that artifact is host-assisted and cannot boot in
Alpine:

```sh
./build-glx-external-vulkan.sh x86_64
archive=out/glx-external-vulkan-alpha/x86_64/xvfb-static-glx-external-vulkan-alpha-linux-x86_64.tar.gz
./test/archive-checks.sh "$archive"
./test/manylinux-2-28-toolchain.sh
./test/glx-external-vulkan-smoke.sh "$archive"
```

If you touch the keyboard catalog, also run `./test/integration.sh`.

We do not expect contributors to have both architectures on hand. Build and
test what you can locally, say in the pull request which cells you ran, and let
CI cover the rest — an honest "x86_64 only, aarch64 untested" is far more
useful than an unqualified "tested".

## Additional expectations

- If a patch changes, explain why the change cannot be made through upstream
  configuration, and identify the exact upstream version you tested against.
- If a check is the point of your change, show that it has teeth: make the
  failure it claims to catch actually happen, and show the check failing.
- If dependencies change, audit the packaged license texts against what the
  binary now incorporates. The build cannot do this for you; see
  `THIRD-PARTY-NOTICES.md`.

Do not add generated binaries to ordinary commits. Release artifacts are
published by the release workflow from a tagged commit.
