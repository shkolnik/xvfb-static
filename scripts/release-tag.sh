# Shared release tag grammar.
#
# Sourced by release.sh and by .github/workflows/release.yml so the tag a
# maintainer can create and the tag the workflow accepts can never disagree.
#
# The workflow's `on.push.tags` glob is only a coarse filter and must stay
# permissive enough to match every tag RELEASE_TAG_REGEX accepts. A glob that is
# stricter than the regex produces the worst failure mode available: a tag that
# validates locally, pushes successfully, and then silently never builds.

# v<upstream-xorg-version>-r<positive-revision>, e.g. v21.1.23-r4
RELEASE_TAG_REGEX='^v([0-9]+(\.[0-9]+)*)-r([1-9][0-9]*)$'

# The upstream X.Org Server version on its own, as derived from the pinned Nix
# build. Must accept exactly the version portion RELEASE_TAG_REGEX allows.
RELEASE_UPSTREAM_REGEX='^[0-9]+(\.[0-9]+)*$'
