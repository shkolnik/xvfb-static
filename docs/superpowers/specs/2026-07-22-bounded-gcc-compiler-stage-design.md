# Bounded GCC Compiler Stage Design

## Decision

Build the GCC target compiler stage in the existing
`manylinux-2-28-gcc-runtime` derivation, then use that compiler only in that
derivation to build the target `libgcc` and `libstdc++` runtime archives.
The compiler is an intermediate build-tree file, never an installed output or
an input to Mesa/Xvfb packaging.

This replaces the disproved runtime-only assumption.  GCC's native target
runtime make targets require configured recursive prerequisites and `xgcc`; a
`make -n` plan cannot establish that state.  Weakening the old guard, using
`make -k`, or using GCC archives from the manylinux image would either conceal
the dependency or abandon the current-source rebuild requirement.

## Architecture

One Nix derivation owns the full transient GCC build tree:

1. Configure locked GCC 14.3.0 with the Task 2 manylinux 2.28 sysroot and
   build-host GMP, MPFR, and MPC configuration inputs.
2. Build only `all-gcc` with bootstrap, install, and unrelated target runtime
   families disabled.  This produces the private `gcc/xgcc` needed by GCC's
   target-runtime make rules.
3. Build only `all-target-libgcc` and `all-target-libstdc++-v3` with that
   private compiler.
4. Copy exactly `libgcc.a`, `libstdc++.a`, `libsupc++.a`, `crtbeginS.o`, and
   `crtendS.o` to the derivation output, plus small provenance files. GCC's
   `--disable-shared` configuration folds EH objects into target `libgcc.a`,
   so no separate `libgcc_eh.a` is part of this output. The exact output
   inventory rejects every compiler executable and every other file.
5. Configure the existing adapter-wide wrapped compiler to prefer those five
   rebuilt runtime files.  No individual consumer receives ad-hoc linker
   flags.  The C++ probe remains the end-to-end ABI proof.

## Boundaries

- Target headers, startup files, linker scripts, loader, and glibc libraries
  come only from `manylinux-2-28-sysroot.nix` through the existing facade.
- Nix GCC, GMP, MPFR, MPC, make, and other executables are build-host tools.
  They may be used to build the compiler stage but must never become target
  libc search paths or installed runtime payload.
- The compiler stage must not invoke `bootstrap`, `stage1`, `stage2`,
  `stage3`, `install-gcc`, or any `install-*` target.  It must not build Mesa,
  Xvfb, LLVM, or a package-set rebuild.
- The output carries only stage/target provenance, not the compiler itself.
  A compiler in a Nix build log or temporary build tree is expected; a
  compiler in `$out` is a hard failure.

## Success Criteria

The implementer may call this design successful only when all of the following
are observed:

1. Native GCC configuration and the `all-gcc` stage finish with the locked
   GCC 14.3.0 source, the Task 2 sysroot, and no cross-only `--with-headers`.
2. The stage log records the explicit target `all-gcc`, and audit rejects every
   bootstrap/stage/install target.
3. `xgcc` exists only before installation and the runtime derivation output
   has the exact five target archives/startfiles and declared provenance files; it has no
   `gcc`, `g++`, `xgcc`, `cc1`, or `cc1plus` file.
4. The adapter-wide wrapper selects the rebuilt runtime archives for
   `-static-libgcc -static-libstdc++`; no per-probe `-B`, `-L`, or sysroot
   workaround is added.
5. The C and C++ probes have no RPATH/RUNPATH or `/nix/store` string, use the
   normal deployment loader, contain only the permitted glibc `DT_NEEDED`
   entries, and import no symbol newer than `GLIBC_2.28`.
6. Both probes execute successfully without installing runtime packages in
   `debian:11-slim` and `ubuntu:24.04` on the matching native architecture.
7. No Mesa/Xvfb build begins during this task.  Disk high-water is reported;
   no cache or Docker volume is automatically deleted.

## Non-goals

This work does not claim that the external-Vulkan artifact now meets its
published host floor, build Mesa/Xvfb, change the final external ABI, or use
GCC runtime archives extracted from the manylinux image.  Those steps remain
downstream gates after this adapter proof.
