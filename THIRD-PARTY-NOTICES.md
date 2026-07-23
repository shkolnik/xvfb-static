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

The external Vulkan GLX alpha prototype instead incorporates Mesa Zink and
its statically linked support libraries. It must not incorporate LLVM,
llvmpipe, softpipe, or lavapipe, and its archive must therefore contain no
LLVM license bundle. The exact Mesa/Zink dependency notices still come from
the pinned build sources and remain part of the package.

That prototype loads the host's `libvulkan.so.1`, which in turn discovers a
host-installed Vulkan ICD and any vendor-driver dependencies. The Vulkan
loader, ICD, and their transitive libraries are runtime prerequisites but are
not redistributed in the archive; their notices and license obligations
remain with the host packages. This distinction must be re-audited against
the actual linked closure before the prototype is eligible for release.
