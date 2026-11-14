#!/usr/bin/env bash
# The release steps helm-main.yml runs, so CI can run them on every pull
# request without releasing (dry-run): a broken tool shows up there, not
# after a merge.
#
#   ci/release.sh next              the next version (empty: nothing to release)
#   ci/release.sh changelog VERSION prepends VERSION's section to CHANGELOG.md
#   ci/release.sh notes VERSION     VERSION's section alone, on stdout
#   ci/release.sh dry-run           all of the above, changing nothing
#
# The chart has no package.json, so the version and the repository come
# from a context file, not from the tools' defaults.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REPO=${GITHUB_REPOSITORY:-czprz/transmission-wireguard}
# Pinned: they run in a job that can push to the repository.
BUMP_TOOL=(npx -y -p conventional-recommended-bump@12.1.0 -p conventional-changelog-angular@9.4.0 conventional-recommended-bump)
CHANGELOG_TOOL=(npx -y -p conventional-changelog@8.1.3 -p conventional-changelog-angular@9.4.0 conventional-changelog)

current() { sed -n 's/^version: //p' "$ROOT/Chart.yaml"; }

next() {
  local version bump major minor patch
  version=$(current)
  [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Chart.yaml version must be x.y.z, not '$version'" >&2; return 1; }
  bump=$(cd "$ROOT" && "${BUMP_TOOL[@]}" -p angular)
  IFS=. read -r major minor patch <<<"$version"
  case $bump in
    "") return 0 ;;
    major) echo "$((major + 1)).0.0" ;;
    minor) echo "$major.$((minor + 1)).0" ;;
    patch) echo "$major.$minor.$((patch + 1))" ;;
    *) echo "unsupported bump: $bump" >&2; return 1 ;;
  esac
}

# VERSION's section: the commits since the last tag, under VERSION.
section() {
  local version=$1 ctx empty out
  ctx=$(mktemp --suffix .json)
  # The tool prints its section followed by its infile (CHANGELOG.md by
  # default): an empty one, so the release notes are the section alone.
  empty=$(mktemp --suffix .md)
  out=$(mktemp)
  printf '{"version": "%s", "host": "https://github.com", "owner": "%s", "repository": "%s"}\n' \
    "$version" "${REPO%%/*}" "${REPO#*/}" >"$ctx"
  (cd "$ROOT" && "${CHANGELOG_TOOL[@]}" -p angular -c "$ctx" -i "$empty" -r 1 --stdout) >"$out"
  rm -f "$ctx" "$empty"
  # A section without its version is the failure this script exists for.
  grep -q "^#\{1,2\} \[$version\](" "$out" || { echo "the changelog tool did not title the section $version:" >&2; cat "$out" >&2; rm -f "$out"; return 1; }
  (($(grep -c '^#\{1,2\} \[' "$out") == 1)) || { echo "the changelog tool printed more than the section $version:" >&2; grep '^#\{1,2\} \[' "$out" >&2; rm -f "$out"; return 1; }
  cat "$out"
  rm -f "$out"
}

case ${1:-} in
  next) next ;;
  notes) section "${2:?notes needs a version}" ;;
  changelog)
    new=$(section "${2:?changelog needs a version}")
    { printf '%s\n\n' "$new"; cat "$ROOT/CHANGELOG.md" 2>/dev/null || true; } >"$ROOT/CHANGELOG.md.new"
    mv "$ROOT/CHANGELOG.md.new" "$ROOT/CHANGELOG.md"
    ;;
  dry-run)
    version=$(next)
    echo "next version: ${version:-none (nothing to release)}"
    # Even with nothing to release, the changelog tool must work.
    section "${version:-$(current)-dry-run.0}" >/dev/null
    echo "changelog section: ok"
    ;;
  *) sed -n '2,11p' "$0" >&2; exit 2 ;;
esac
