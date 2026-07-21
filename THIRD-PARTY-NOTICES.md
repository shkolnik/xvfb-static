# Third-party notices

The `Xvfb` release binary is a statically linked build of X.Org X Server and
its library dependencies. It is not covered solely by this repository's
Apache-2.0 license.

The exact upstream source set is fixed by `flake.lock`. The build extracts
license texts from those pinned Nix sources and places them in every release
archive at `share/xvfb-static/licenses/`. Those bundled texts are the
authoritative component-by-component notices for a particular artifact.

The XKB keymap embedded in the binary is generated from the pinned
`xkeyboard-config` sources with the pinned `xkbcomp` build tool. Their license
texts are retained in the archive as well. No third-party source is vendored
in this repository; patches apply at build time to the exact pinned source.
