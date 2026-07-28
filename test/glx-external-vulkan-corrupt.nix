# Builds the external Vulkan Xvfb archive with one embedded keyboard profile
# corrupted, for the fault-injection check in
# test/glx-external-vulkan-smoke.sh.
#
# This variant is host-assisted: its packaged ELF interpreter is rewritten to
# a host loader path (nix/manylinux-2-28-stdenv.nix's deploymentLoader) that
# the Nix build sandbox does not provide, so it cannot boot inside a `nix
# build` the way the no-GLX and GLX llvmpipe variants do in flake.nix's
# `checks` (see integration-test.nix). The corrupt binary this file produces
# is instead booted inside the same Debian container test/glx-external-vulkan-smoke.sh
# already uses for its other runtime assertions.
#
# Reuses package-glx-external-vulkan.nix's own corruptEmbeddedProfile
# parameter rather than a second copy of the catalog-corruption logic.
#
# The corrupted profile is fixed at "de", matching flake.nix's mkCorrupt for
# the no-GLX variant: test/glx-external-vulkan-smoke.sh's fault-injection
# assertion hard-codes the same id, so making it independently overridable
# here would only let the two silently drift apart.
{ system ? builtins.currentSystem
, nixpkgsSource ? (builtins.getFlake (toString ../.)).inputs.nixpkgs
}:
import ../package-glx-external-vulkan.nix {
  inherit system nixpkgsSource;
  corruptEmbeddedProfile = "de";
}
