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

The GLX llvmpipe alpha archives additionally incorporate Mesa llvmpipe, LLVM (including
its BLAKE3 support code and Polly's isl/imath components), the GCC C++ runtime,
and their statically linked support libraries. Their pinned-source license and
runtime-exception texts are included alongside the X.Org notices in each GLX
archive. The standard archives do not include the GLX software-rendering stack.

The external Vulkan GLX alpha archives instead incorporate Mesa Zink and its
statically linked support libraries. They must not incorporate LLVM, llvmpipe,
softpipe, or lavapipe, and their archives must therefore contain no LLVM
license bundle. That is enforced, not merely intended: the build fails if any
LLVM, Polly, or BLAKE3 notice appears in the packaged license directory, and
separately if the binary contains an LLVM symbol reference. The exact
Mesa/Zink dependency notices still come from the pinned build sources and
remain part of the package.

That variant loads the host's `libvulkan.so.1`, which in turn discovers a
host-installed Vulkan ICD and any vendor-driver dependencies. The Vulkan
loader, ICD, and their transitive libraries are runtime prerequisites but are
**not redistributed** in the archive; their notices and license obligations
remain with the host packages. Do not list them among the archive's notices,
and do not omit a statically incorporated component on the grounds that the
host is likely to have one too.

## License elections

Two pinned components ship under a choice of licenses, and this project
elects one deliberately rather than accepting whatever nixpkgs' summarized
`meta.license` happens to report:

- **FreeType** offers the FTL and GPLv2 as mutually exclusive options (per its
  own `docs/FTL.TXT`). This project ships the FTL text and never the GPLv2
  text, to keep an otherwise all-permissive closure permissive.
- **zstd** offers a BSD license (`LICENSE`) and, separately, GPLv2
  (`COPYING`). This project ships the BSD text.

`mesa-gl-headers` (Mesa's own `include/{GL,EGL,GLES*}` tree, pulled in as a
direct dependency of nixpkgs' own `xvfb` derivation for DRI3/Present support,
independent of GLX) ships as part of every variant, including the standard
one. Its upstream license bundle aggregates notices for Mesa's entire
repository, not just this header subset. The archive carries the
plausibly-applicable permissive texts (Apache-2.0, MIT, SGI-B-2.0) from that
bundle and deliberately omits the GPL-1.0, GPL-2.0, and BSL-1.0 texts also
present there, on the assessment that the packaged public GL/EGL API headers
follow Khronos's own permissive licensing, consistent with the rest of that
header family.

## Closure-versus-license audit

`nix/license-closure.nix` walks each variant's real Nix dependency graph
(`buildInputs` plus `propagatedBuildInputs`, transitively) and fails the build
if any linked package has neither a license entry nor an explicit, justified
allowlist entry. It also fails if an allowlist names a package no longer
reachable in the closure, so a stale allowlist entry cannot silently
substitute for real coverage — an early version of this project's own GLX
variant refactor tripped that exact check when it copied allowlist entries
that no longer applied to that variant's actual closure. Each package
derivation asserts this audit before it will build at all.

This closes the practical version of the gap this section used to describe:
every package genuinely reachable through the closure walk now has to be
either licensed or explicitly, auditably excused. Two things are
intentionally excluded from the walk, not accidentally missed by it:

- **musl and other implicit stdenv toolchain inputs** are not part of
  `buildInputs`/`propagatedBuildInputs` and so are outside what a dependency
  closure walk can see at all.
- **`opaqueLeaves`** (currently `stdenv.cc.cc.lib` and, for the llvmpipe
  variant, `python3`) stop the walk at that package's own boundary. These are
  referenced only for their own license text or as build tooling; their
  *internal* build-time composition (GCC's own gmp/mpfr/isl, Python's stdlib
  dependency chain) is nixpkgs plumbing, not evidence of something statically
  linked into Xvfb, and walking into it would just reintroduce noise the
  audit exists to cut through.

Treat those two exclusions as the honestly-scoped remainder of the original
gap, not as unaudited surface. `AGENTS.md` section 11 tracks further closure
work (an SBOM) as a related, separate item.
