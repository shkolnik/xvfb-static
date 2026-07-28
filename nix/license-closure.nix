# Shared link-closure walker and license-coverage assertion, used by all three
# package derivations to close the gap tracked in AGENTS.md section 11 gap 1:
# the license lists used to be hand-maintained with nothing checking that
# every statically linked dependency actually had a notice.
#
# "Link closure" means the transitive buildInputs/propagatedBuildInputs of a
# package -- nixpkgs' own distinction between "linked dependency" and "build
# tool" (nativeBuildInputs, which this deliberately does not walk). This does
# not see code that arrives through the stdenv itself (musl, libgcc) rather
# than through buildInputs; that is a real, separate blind spot, not closed
# by this file. See AGENTS.md section 11.
{ lib }:
rec {
  # opaqueLeaves: package values (not pnames -- pnames like the compiler's
  # are architecture-dependent) whose OWN buildInputs/propagatedBuildInputs
  # are not walked. Needed for e.g. static.stdenv.cc.cc(.lib): we reference
  # it only to extract libstdc++'s own license, but its buildInputs describe
  # what was needed to *build* GCC (gmp, mpfr, isl, python3, bash, ...), not
  # what Xvfb links against. Confirmed empirically (2026-07): none of those
  # packages are reachable from LLVM's own closure; they come solely from
  # stdenv.cc.cc.lib's build-time composition. The leaf itself is still a
  # required closure member and still needs its own license entry.
  linkClosure = { root, opaqueLeaves ? [ ] }:
    let
      opaqueOutPaths = map (p: p.outPath) opaqueLeaves;
    in
    builtins.genericClosure {
      startSet = [{ key = root.outPath; pkg = root; }];
      operator = { pkg, ... }:
        if builtins.elem pkg.outPath opaqueOutPaths then [ ]
        else
          let
            deps = (pkg.buildInputs or [ ]) ++ (pkg.propagatedBuildInputs or [ ]);
          in
          map (d: { key = d.outPath; pkg = d; })
            (builtins.filter (d: builtins.isAttrs d && d ? outPath) deps);
    };

  linkClosurePnames = { root, opaqueLeaves ? [ ] }:
    lib.unique (map
      ({ pkg, ... }:
        pkg.pname or pkg.name or
          (throw "xvfb-static: link-closure member ${pkg.outPath} has neither pname nor name"))
      (linkClosure { inherit root opaqueLeaves; }));

  # Looks up a single closure member by pname, so license entries for
  # transitive dependencies don't need their own callPackage-wired function
  # argument (nixpkgs' pname and its top-level attribute name frequently
  # disagree -- e.g. pname "libxcb-image" is attribute xcbutilimage).
  findInClosure = { root, opaqueLeaves ? [ ] }: pname:
    let
      matches = builtins.filter ({ pkg, ... }: (pkg.pname or pkg.name or "") == pname)
        (linkClosure { inherit root opaqueLeaves; });
    in
    if matches == [ ] then
      throw "xvfb-static: '${pname}' is not in ${root.pname or root.name}'s link closure"
    else (builtins.head matches).pkg;

  # entries: the same { pkg, rel, dest } records used to generate the
  # extract_license shell invocations -- one list, so the covered set can't
  # drift from what is actually extracted.
  # allowlist: [ { pname = "..."; reason = "..."; } ] for closure members
  # known not to need a shipped notice. Every allowlist pname must still be
  # present in the closure, or the audit fails: an allowlist entry that stops
  # matching anything is gap 1 reopening quietly.
  # extraCoveredPnames: pnames covered by extraction that doesn't fit the
  # single { pkg, rel, dest } shape (e.g. xorgproto's per-protocol
  # COPYING-<name> files, extracted via extract_license_glob).
  audit = { root, label, entries, allowlist ? [ ], extraCoveredPnames ? [ ], opaqueLeaves ? [ ] }:
    let
      closurePnames = linkClosurePnames { inherit root opaqueLeaves; };
      rootPname = root.pname or root.name or null;
      required = builtins.filter (p: p != rootPname) closurePnames;
      coveredPnames = lib.unique
        (map (e: e.pkg.pname or e.pkg.name) entries ++ extraCoveredPnames);
      allowlistPnames = map (a: a.pname) allowlist;
      uncovered = lib.subtractLists (coveredPnames ++ allowlistPnames) required;
      staleAllowlist = builtins.filter (p: !(builtins.elem p closurePnames)) allowlistPnames;
    in
    {
      ok = uncovered == [ ] && staleAllowlist == [ ];
      message =
        (if uncovered != [ ] then ''
          xvfb-static: ${label} statically links packages with no license entry:
          ${lib.concatMapStringsSep "\n" (p: "  - ${p}") uncovered}
          Add an extract_license entry, or an explicit allowlist entry with a reason.
        '' else "")
        + (if staleAllowlist != [ ] then ''
          xvfb-static: ${label}'s license allowlist names packages no longer in
          the link closure: ${lib.concatStringsSep ", " staleAllowlist}. Remove the
          stale allowlist entry.
        '' else "");
    };
}
