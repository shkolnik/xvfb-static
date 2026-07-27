# The genuine duplication between mesa-llvmpipe.nix and mesa-zink.nix: the
# mesa.override arguments neither backend varies (galliumDrivers/llvmPackages
# excepted), the mesonFlags shared by both static Gallium/GLX builds, and the
# dril dynamic-loader skip that both preConfigure scripts apply identically.
#
# Deliberately NOT unified here, because each side differs in ways that are
# real build behavior, not formatting: the llvmpipe build links a real static
# LLVM and rewrites shared_library() to library(), while the zink build links
# no LLVM at all and rewrites shared_library() to static_library() (with two
# extra library-versioning substitutions llvmpipe does not need); their
# nativeBuildInputs strategies differ (appending targetLLVM.dev vs swapping in
# a full host-toolchain native tool set); their mesonFlags diverge in the
# LLVM/SPIR-V/shader-cache/zstd/c_args region; and their package sets are
# constructed differently (a single pkgsStatic vs a manylinux target/host
# split with its own overlay). Forcing those into one parameterized shape was
# judged higher-risk than the loose duplication it would remove; see AGENTS.md
# section 11.
{
  # Every mesa.override key both backends set to the same value. Each caller
  # supplies its own galliumDrivers and llvmPackages, plus its package set's
  # `disabled` marker (pkgsStatic.emptyDirectory / target.emptyDirectory --
  # the two are different derivations, so this cannot be hard-coded here),
  # and may add backend-only keys (zink's `libunwind = disabled;`) via `extra`.
  mkMesaOverrideArgs = { galliumDrivers, llvmPackages, disabled, extra ? { } }:
    {
      inherit galliumDrivers llvmPackages;
      vulkanDrivers = [ ];
      vulkanLayers = [ ];
      eglPlatforms = [ "x11" ];
      enablePatentEncumberedCodecs = false;
      withValgrind = false;
      directx-headers = disabled;
      elfutils = disabled;
      glslang = disabled;
      spirv-tools = disabled;
      spirv-llvm-translator = disabled;
      libglvnd = disabled;
      libgbm = disabled;
      vulkan-loader = disabled;
      libva-minimal = disabled;
      libdisplay-info = disabled;
      lm_sensors = disabled;
      udev = disabled;
      wayland = disabled;
      wayland-protocols = disabled;
      wayland-scanner = disabled;
      rustc = disabled;
      rust-bindgen = disabled;
      rust-cbindgen = disabled;
    } // extra;

  # mesonFlags common to both backends, split around the LLVM/SPIR-V region
  # where they diverge. Each caller splices its own flags between the two so
  # the assembled list keeps the exact original per-file order:
  #   mesonFlagsHead ++ <backend-specific LLVM/SPIR-V flags> ++ mesonFlagsTail
  #   ++ <any backend-only trailing flags, e.g. zink's -Dc_args=...>
  mesonFlagsHead = [
    "-Dauto_features=disabled"
    "-Ddefault_library=static"
    "-Ddefault_both_libraries=static"
    "-Dplatforms=x11"
    "-Dglx=dri"
    "-Dglvnd=disabled"
    "-Degl=disabled"
    "-Dgbm=disabled"
    "-Dshared-glapi=enabled"
    "-Dgallium-rusticl=false"
    "-Dgallium-extra-hud=false"
    "-Dgallium-va=disabled"
    "-Dteflon=false"
    "-Dinstall-mesa-clc=false"
    "-Dinstall-precomp-compiler=false"
  ];
  mesonFlagsTail = [
    "-Dvideo-codecs="
    "-Dtools="
  ];

  # Both preConfigure scripts skip the dynamic dril loader subdir identically;
  # only its position among the other, backend-specific substitutions differs,
  # which is immaterial since none of the substitutions overlap.
  skipDrilSubdirPatch = ''
    substituteInPlace src/meson.build \
      --replace-fail "    subdir('gallium/targets/dril')" \
      "    message('Skipping unused dynamic dril loader')"
  '';
}
