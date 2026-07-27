# Small package overrides needed at more than one place in the external
# Vulkan / manylinux 2.28 build: once inside mesa-zink.nix's target overlay
# (so every dependent in that package set resolves to the patched
# derivation), and again at the Xvfb dependency boundary in
# package-glx-external-vulkan.nix (because Xvfb's fixed nixpkgs dependency
# graph can still retain the unmodified derivation even when the overlay
# replaces the public attribute). Each was previously a verbatim copy at both
# call sites; this is the one implementation.
{
  # libXfont2 unconditionally builds an uninstalled lsfontdir test utility.
  # Its static FreeType/Brotli link is incomplete, while the library itself is
  # incorporated into and exercised through Xvfb.
  noLsfontdir = pkg: pkg.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace Makefile.in \
        --replace-fail 'noinst_PROGRAMS = lsfontdir' 'noinst_PROGRAMS ='
    '';
    postConfigure = (old.postConfigure or "") + ''
      find . -name Makefile -type f -exec sed -i \
        's/noinst_PROGRAMS = lsfontdir/noinst_PROGRAMS =/' {} +
    '';
  });

  # Pixman's test executables are not incorporated into Xvfb and their static
  # libpng link omits libz. The packaged GLX render test exercises the
  # incorporated pixman library at the product boundary.
  noPixmanTests = pkg: pkg.overrideAttrs (old: {
    mesonFlags = (old.mesonFlags or [ ]) ++ [ "-Dtests=disabled" ];
    # Some nixpkgs pixman revisions still enter the test subdirectory despite
    # the option above when cross-building. Those test executables are
    # build-only and pull in host OpenMP/zlib details; remove the
    # subdirectory explicitly for this static target.
    postPatch = (old.postPatch or "") + ''
      sed -i \
        -e "s/if not get_option('tests').disabled()/if false/" \
        -e "s/if not get_option('tests').disabled() or not get_option('demos').disabled()/if not get_option('demos').disabled()/" \
        meson.build
    '';
  });

  # libdrm's Intel and Valgrind support are neither needed nor available in
  # this static/cross build.
  noIntelNoValgrindLibdrm = pkg: pkg.override {
    withIntel = false;
    withValgrind = false;
  };
}
