#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
nix_image='nixos/nix@sha256:22c0a3a816eb3d315eb6720d2a58a3c3b622c9717c578f3c80b687668c6da277'

prefetch_lock() {
  local arch=$1
  local image
  local docker_arch
  local docker_platform
  local digest
  local prefetch
  local sha256

  case "$arch" in
    x86_64-linux) image=quay.io/pypa/manylinux_2_28_x86_64 ;;
    aarch64-linux) image=quay.io/pypa/manylinux_2_28_aarch64 ;;
    *) echo "unsupported system: $arch" >&2; exit 2 ;;
  esac

  case "$arch" in
    x86_64-linux)
      docker_arch=amd64
      docker_platform=linux/amd64
      ;;
    aarch64-linux)
      docker_arch=arm64
      docker_platform=linux/arm64
      ;;
  esac

  digest=$(docker buildx imagetools inspect "${image}:latest" --format '{{json .}}' | jq -er '.manifest.digest')
  if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "failed to resolve an immutable digest for ${image}: ${digest}" >&2
    exit 1
  fi

  if ! prefetch=$(docker run --rm --platform "$docker_platform" \
    -v "$repo_root":/src -v xvfb-static-nix:/nix -w /src \
    -e NIX_CONFIG='experimental-features = nix-command flakes' \
    "$nix_image" \
    nix run --impure --expr '
      let
        flake = builtins.getFlake "path:/src";
        pkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; };
      in
      { nix-prefetch-docker = pkgs.nix-prefetch-docker; }
    ' nix-prefetch-docker -- \
    --image-name "$image" --image-digest "$digest" --arch "$docker_arch" \
    --final-image-name "$image" --final-image-tag locked --json); then
    echo "nix-prefetch-docker failed for ${image}" >&2
    return 1
  fi
  if ! sha256=$(jq -er '.hash' <<<"$prefetch"); then
    echo "nix-prefetch-docker did not emit a sha256 for ${image}" >&2
    return 1
  fi

  jq -n \
    --arg imageName "$image" \
    --arg imageDigest "$digest" \
    --arg sha256 "$sha256" \
    '{
      imageName: $imageName,
      imageDigest: $imageDigest,
      sha256: $sha256,
      policy: "manylinux_2_28",
      glibcFloor: "2.28"
    }'
}

x86_64_lock=$(prefetch_lock x86_64-linux)
aarch64_lock=$(prefetch_lock aarch64-linux)

jq -n \
  --argjson x86_64 "$x86_64_lock" \
  --argjson aarch64 "$aarch64_lock" \
  '{
    "x86_64-linux": $x86_64,
    "aarch64-linux": $aarch64
  }'
