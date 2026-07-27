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

## Open compliance gap

The license lists in the three package derivations are hand-maintained, and
nothing in the build compares them against what the binaries actually
incorporate. The extractor fails when a *listed* notice is missing, empty, or
ambiguous — it cannot fail when an incorporated component is *unlisted*.

That gap is real and currently unclosed. Until a closure-versus-list check
exists, the bundled notices should be treated as complete for the components
listed and unverified for the closure as a whole, and any dependency change
requires a manual audit. `AGENTS.md` section 11 tracks this as the top open
item.
