#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
remote="origin"
branch="main"
image="nixos/nix@sha256:22c0a3a816eb3d315eb6720d2a58a3c3b622c9717c578f3c80b687668c6da277"
dry_run=false

if [[ "${1:-}" == "--dry-run" && $# -eq 1 ]]; then
  dry_run=true
elif (( $# != 0 )); then
  echo "usage: ./release.sh [--dry-run]" >&2
  exit 2
fi

cd "$root"

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
command -v git >/dev/null || { echo "git is required" >&2; exit 1; }

current_branch="$(git symbolic-ref --quiet --short HEAD)" || {
  echo "releases must be made from a branch, not detached HEAD" >&2
  exit 1
}
if [[ "$current_branch" != "$branch" ]]; then
  echo "releases must be made from $branch (currently $current_branch)" >&2
  exit 1
fi
if [[ -n "$(git status --short)" ]]; then
  echo "the worktree must be clean before preparing a release" >&2
  git status --short >&2
  exit 1
fi

remote_url="$(git remote get-url "$remote")" || {
  echo "missing Git remote: $remote" >&2
  exit 1
}
case "$remote_url" in
  git@github.com:*|ssh://git@github.com/*|https://github.com/*) ;;
  *) echo "$remote does not point to GitHub: $remote_url" >&2; exit 1 ;;
esac

echo "Fetching $remote/$branch and reading release tags..."
git fetch --prune "$remote" \
  "+refs/heads/$branch:refs/remotes/$remote/$branch"
remote_head="$(git rev-parse "refs/remotes/$remote/$branch")"
if ! git merge-base --is-ancestor "$remote_head" HEAD; then
  echo "local $branch does not contain the current $remote/$branch; pull or rebase first" >&2
  exit 1
fi

case "$(uname -m)" in
  x86_64|amd64) arch="x86_64" ;;
  aarch64|arm64) arch="aarch64" ;;
  *) echo "unsupported host architecture: $(uname -m)" >&2; exit 2 ;;
esac

echo "Evaluating the pinned X.Org Server version..."
upstream_version="$(
  docker run --rm \
    -e NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1 \
    -v "$root":/src -w /src \
    -v xvfb-static-nix:/nix \
    "$image" sh -c "
      set -eu
      git config --global --add safe.directory /src
      nix --extra-experimental-features 'nix-command flakes' \\
        eval '.#xvfb-static-$arch.upstreamVersion' --raw --impure
    "
)"
if [[ ! "$upstream_version" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
  echo "unexpected X.Org Server version: $upstream_version" >&2
  exit 1
fi

highest_revision=0
while IFS= read -r ref; do
  tag="${ref#refs/tags/}"
  revision="${tag#v${upstream_version}-r}"
  if [[ "$revision" =~ ^[1-9][0-9]*$ ]] && (( revision > highest_revision )); then
    highest_revision="$revision"
  fi
done < <(git ls-remote --refs --tags "$remote" "v${upstream_version}-r*" | awk '{print $2}')

next_revision=$((highest_revision + 1))
release_version="${upstream_version}-r${next_revision}"
release_tag="v${release_version}"
current_revision="$(sed -nE 's/^  releaseRevision = ([0-9]+);$/\1/p' package.nix)"
if [[ ! "$current_revision" =~ ^[1-9][0-9]*$ ]]; then
  echo "could not read the unique releaseRevision from package.nix" >&2
  exit 1
fi

printf '\nRelease preview\n'
printf '  Version:       %s\n' "$release_tag"
printf '  X.Org Server:  %s\n' "$upstream_version"
printf '  Revision:      r%s -> r%s\n' "$current_revision" "$next_revision"
printf '  Commit:        %s\n' "$(git rev-parse --short HEAD)"
printf '  Push target:   %s (%s)\n' "$remote/$branch" "$remote_url"
if [[ "$current_revision" == "$next_revision" ]]; then
  printf '  File update:   none; package.nix already has the required revision\n'
else
  printf '  File update:   package.nix releaseRevision\n'
fi
printf '  Tag:           signed, annotated %s\n\n' "$release_tag"

if $dry_run; then
  echo "Dry run complete; no files, commits, tags, or remote branches were changed."
  exit 0
fi

if [[ -t 0 && -t 1 ]]; then
  while true; do
    read -r -p "Proceed with this release? [y/N] " answer
    case "$answer" in
      [Yy]|[Yy][Ee][Ss]) break ;;
      ""|[Nn]|[Nn][Oo]) echo "Release cancelled."; exit 0 ;;
      *) echo "Please answer Yes or No." ;;
    esac
  done
else
  echo "No TTY detected; proceeding without confirmation."
fi

if [[ "$current_revision" != "$next_revision" ]]; then
  tmp="$(mktemp "$root/.package.nix.release.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT
  awk -v revision="$next_revision" '
    /^  releaseRevision = [0-9]+;$/ {
      print "  releaseRevision = " revision ";"
      next
    }
    { print }
  ' package.nix > "$tmp"
  mv "$tmp" package.nix
  trap - EXIT

  git diff --check
  git add -- package.nix
  git commit -m "Release $release_tag" -- package.nix
fi

evaluated_version="$(
  docker run --rm \
    -e NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1 \
    -v "$root":/src -w /src \
    -v xvfb-static-nix:/nix \
    "$image" sh -c "
      set -eu
      git config --global --add safe.directory /src
      nix --extra-experimental-features 'nix-command flakes' \\
        eval '.#xvfb-static-$arch.releaseVersion' --raw --impure
    "
)"
if [[ "$evaluated_version" != "$release_version" ]]; then
  echo "evaluated release version $evaluated_version does not match $release_version" >&2
  exit 1
fi

bash -n build.sh build-glx-llvmpipe.sh test/smoke.sh test/glx-llvmpipe-smoke.sh release.sh
git diff --check
if [[ -n "$(git status --short)" ]]; then
  echo "release preparation left unexpected worktree changes" >&2
  git status --short >&2
  exit 1
fi

if git show-ref --verify --quiet "refs/tags/$release_tag"; then
  if [[ "$(git rev-list -n 1 "$release_tag")" != "$(git rev-parse HEAD)" ]]; then
    echo "local tag $release_tag already exists at another commit" >&2
    exit 1
  fi
  echo "Reusing local tag $release_tag at HEAD."
else
  git tag -s "$release_tag" -m "xvfb-static $release_tag"
fi

echo "Pushing $branch and $release_tag atomically to $remote..."
git push --atomic "$remote" \
  "HEAD:refs/heads/$branch" \
  "refs/tags/$release_tag:refs/tags/$release_tag"

echo "Release tag $release_tag pushed; GitHub Actions will build and publish it."
