#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
updater="$repo_root/scripts/update-manylinux-2-28-lock.sh"
test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/xvfb-static-manylinux-lock.XXXXXX")
trap 'rm -rf "$test_tmp"' EXIT

cat > "$test_tmp/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == buildx && "$2" == imagetools && "$3" == inspect ]]; then
  printf '{"manifest":{"digest":"%s"}}\n' "$MOCK_DIGEST"
  exit 0
fi

echo "unexpected docker invocation: $*" >&2
exit 99
EOF
chmod +x "$test_tmp/docker"

assert_rejected_digest() {
  local digest=$1
  local output

  if output=$(PATH="$test_tmp:$PATH" MOCK_DIGEST="$digest" "$updater" 2>&1); then
    echo "updater accepted invalid digest: $digest" >&2
    exit 1
  fi
  if [[ "$output" != *"failed to resolve an immutable digest"* ]]; then
    echo "unexpected invalid-digest failure: $output" >&2
    exit 1
  fi
}

assert_rejected_digest 'sha256:abc'
assert_rejected_digest 'sha256:a61875a2f84cab7df8de222ff12cabc08ff86eb4ad402ac90ba7bdaed9600ccag'
