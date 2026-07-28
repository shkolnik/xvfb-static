# Pinned base images for the test containers.
#
# Sourced, not executed. The shipped bytes are built in the digest-pinned
# container named by build-image.txt; these are the runtime environments the
# archives are then tested in, and they were the last unpinned Docker
# references in the repository. test/static-smoke.sh and test/glx-llvmpipe-smoke.sh
# had already drifted to different Alpine majors (3.20 and 3.22) while booting
# the same binary for the same reason.
#
# Each digest is the multi-architecture index digest, so one value resolves
# correctly on both the x86_64 and aarch64 native runners. The tag each digest
# was resolved from is recorded beside it; re-resolve with
#
#   docker buildx imagetools inspect <tag> --format '{{.Manifest.Digest}}'
#
# Pinning bounds the base image only. The external Vulkan test still runs
# apt-get against live Debian archives, so its Vulkan loader and Mesa versions
# are not pinned by this file.

# Minimal musl host for the fully static archives.
# alpine:3.22
XVFB_STATIC_ALPINE_IMAGE="alpine@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce"

# Supplies the advertised glibc and loader floor.
# debian:11-slim
XVFB_STATIC_DEBIAN_11_IMAGE="debian@sha256:cba95a21c96c1f5fc2470081829363eed57706634f7dc26e8c6712934303d57a"

# Newer glibc runtime, for the lavapipe integration case Debian 11's Mesa 22
# is too old to serve.
# debian:trixie-slim
XVFB_STATIC_DEBIAN_TRIXIE_IMAGE="debian@sha256:020c0d20b9880058cbe785a9db107156c3c75c2ac944a6aa7ab59f2add76a7bd"

# Second glibc distribution for the manylinux probes.
# ubuntu:24.04
XVFB_STATIC_UBUNTU_2404_IMAGE="ubuntu@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90"
