# Shared body of build.sh, build-glx-llvmpipe.sh, and build-glx-external-vulkan.sh.
#
# Sourced, not executed. build-glx-external-vulkan.sh previously contained zero
# original lines: it was build-glx-llvmpipe.sh with one string substituted. The
# triplication had already produced a real divergence -- cp -L versus install -m
# -- in scripts whose entire purpose is byte-determinism.
#
# Every constant that has to agree across the three entry points lives here.

# The pinned build container. build-image.txt is the single source of truth;
# release.sh, test/integration.sh, the manylinux scripts, and both workflows
# read the same file.
xvfb_static_image() {
  cat "$1/build-image.txt"
}

# The named Docker volume holding /nix, so builds reuse the store across runs.
XVFB_STATIC_NIX_VOLUME="xvfb-static-nix"

# A fixed timestamp for every archive entry. 315532800 is 1980-01-01, the
# earliest time the tar and zip epoch conventions represent cleanly.
XVFB_STATIC_MTIME="@315532800"

# Resolve the architecture from an optional argument, defaulting to the host.
# Usage: arch="$(xvfb_static_arch "${1:-}" "$0")" || exit $?
xvfb_static_arch() {
  local requested="$1" program="$2" arch
  arch="$requested"
  if [[ -z "$arch" ]]; then
    case "$(uname -m)" in
      x86_64|amd64) arch="x86_64" ;;
      aarch64|arm64) arch="aarch64" ;;
      *) echo "unsupported host architecture: $(uname -m)" >&2; return 2 ;;
    esac
  fi
  case "$arch" in
    x86_64|aarch64) ;;
    *) echo "usage: $program [x86_64|aarch64]" >&2; return 2 ;;
  esac
  printf '%s\n' "$arch"
}

# Build one variant and assemble its deterministic archive and checksum.
#
#   xvfb_static_build <root> <arch> <flake-attr-prefix> <output-subdir> <archive-prefix>
#
# Every variant nests its output under its own name, so no variant owns the
# bare architecture directory.
xvfb_static_build() {
  local root="$1" arch="$2" attribute="$3" subdir="$4" archive_prefix="$5"
  local image uid gid output archive
  image="$(xvfb_static_image "$root")"
  uid="$(id -u)"
  gid="$(id -g)"
  output="$root/out/$subdir"
  archive="$archive_prefix-linux-$arch.tar.gz"
  mkdir -p "$output"

  # Modes are set explicitly with install rather than inherited through cp, so
  # the archive depends on neither the store's modes nor the caller's umask.
  docker run --rm \
    -e BUILD_UID="$uid" -e BUILD_GID="$gid" \
    -e CACHIX_CACHE_NAME -e CACHIX_AUTH_TOKEN -e CACHIX_SIGNING_KEY \
    -v "$root":/src -w /src \
    -v "$XVFB_STATIC_NIX_VOLUME":/nix \
    "$image" sh -c "
      set -eu
      git config --global --add safe.directory /src
      out=/src/out/$subdir
      bash /src/nix-build-cached.sh \\
        nix --extra-experimental-features 'nix-command flakes' \\
        build '.#$attribute-$arch' -o \$out/result --option log-lines 200
      rm -rf \$out/package
      mkdir -p \$out/package/bin \$out/package/share/xvfb-static/licenses
      install -m 0755 \$out/result/bin/Xvfb \$out/package/bin/Xvfb
      install -m 0644 \\
        \$out/result/share/xvfb-static/manifest.json \\
        \$out/package/share/xvfb-static/manifest.json
      install -m 0644 \\
        \$out/result/share/xvfb-static/licenses/* \\
        \$out/package/share/xvfb-static/licenses/
      cd \$out/package
      LC_ALL=C tar --sort=name --owner=0 --group=0 --numeric-owner \\
        --mtime=$XVFB_STATIC_MTIME -czf \$out/$archive bin share
      cd \$out
      sha256sum $archive > SHA256SUMS
      chown -R \"\$BUILD_UID:\$BUILD_GID\" \$out
    "

  cat "$output/SHA256SUMS"
}
