# Contributing

Issues and pull requests are welcome. Please keep changes narrowly scoped and
explain the user-visible reason for them.

Before submitting a pull request:

1. Run `./build.sh x86_64`.
2. Run `./test/smoke.sh out/x86_64/xvfb-static-linux-x86_64.tar.gz`.
3. Confirm the archive still includes its manifest and license directory.
4. If a patch changes, explain why the change cannot be made through upstream
   configuration and identify the exact upstream version tested.

Do not add generated binaries to ordinary commits. Release artifacts are
published by the release workflow from a tagged commit.
