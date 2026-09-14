#!/usr/bin/env bash
# Populate a Lake workspace's `.lake/packages` from its `lake-manifest.json` so that
# `lake build` inside the (network-less) comparator jail finds every dependency
# already present at the pinned revision.
#
# Usage: materialize-deps.sh <project_dir>
#
# Lake never runs here. `lake update` would elaborate the `lakefile.lean` of every
# dependency on the host to discover transitive requires; the manifest already
# lists the flattened, transitive set with a git url and an exact revision per
# package, and that is all a checkout needs. Each entry goes through
# fetch-repo.sh, i.e. the same jail, the same protocol restrictions and the same
# tree policy (no `.lake`, no build outputs) as the root repositories.
#
# What the manifest is allowed to say (anything else is a rejection, not a
# best-effort guess; Lake would fail offline anyway, this only makes the reason
# legible):
#   - it exists and is a regular file (a package without one cannot build in the
#     read-only workspace, since Lake would try to create it);
#   - `packagesDir` is exactly ".lake/packages" and `lakeDir` exactly ".lake":
#     `.lake` is the directory fetch-repo.sh created empty and the only path the
#     jail can write, so a manifest pointing elsewhere would either be unbuildable
#     or, worse, make us clone into a path the repository itself controls (a
#     committed symlink, say).
#   - every package is `type: "git"` with an https `url` and a full-length `rev`;
#     `path` dependencies reach outside the attested tree by construction.
#   - `name` is a single safe path component and unique.
# Lake compares the checkout's `origin` URL and HEAD against the manifest at build
# time and would try to re-clone on a mismatch, so the URL is used verbatim and the
# revision is verified by fetch-repo.sh.
set -euo pipefail

project="${1:-}"
if [ -z "$project" ] || [ ! -d "$project" ] || [ $# -ne 1 ]; then
    echo "Usage: $(basename "$0") <project_dir>" >&2
    exit 1
fi
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
manifest="$project/lake-manifest.json"

# Lake writes a manifest on its first run even for a package without
# dependencies, and inside the jail the workspace root is read-only, so a
# package that never committed one cannot be built at all. Say so here.
if [ ! -e "$manifest" ] && [ ! -L "$manifest" ]; then
    echo "Error: $project has no lake-manifest.json; run \`lake update\` and commit the manifest" >&2
    exit 1
fi
if [ ! -f "$manifest" ] || [ -L "$manifest" ]; then
    echo "Error: $manifest is not a regular file" >&2
    exit 1
fi
if [ ! -d "$project/.lake" ] || [ -L "$project/.lake" ]; then
    echo "Error: $project/.lake must be a directory created by fetch-repo.sh" >&2
    exit 1
fi

# One jq program validates the whole document and prints the entries as
# tab-separated lines; any violation is a single error message and a non-zero exit.
entries="$(jq -r '
  def fail(msg): error("manifest rejected: " + msg);
  if type != "object" then fail("not an object") else . end
  | if (.packagesDir // ".lake/packages") != ".lake/packages" then fail("packagesDir must be .lake/packages") else . end
  | if (.lakeDir // ".lake") != ".lake" then fail("lakeDir must be .lake") else . end
  | (.packages // []) as $pkgs
  | if ($pkgs | type) != "array" then fail("packages must be an array") else . end
  | if ($pkgs | map(.name) | unique | length) != ($pkgs | length) then fail("duplicate package names") else . end
  | $pkgs[]
  | if .type != "git" then fail("package \(.name // "?") is not a git dependency") else . end
  | if (.name | type) != "string" or (.name | test("^[A-Za-z0-9_][A-Za-z0-9_.-]*$") | not) or .name == "." or .name == ".."
      then fail("invalid package name \(.name)") else . end
  | if (.url | type) != "string" or (.url | test("^https://[^[:space:][:cntrl:]@]+$") | not)
      then fail("package \(.name) has no acceptable https url") else . end
  | if (.rev | type) != "string" or (.rev | test("^([a-f0-9]{40}|[a-f0-9]{64})$") | not)
      then fail("package \(.name) is not pinned to a full revision") else . end
  | [.name, .url, .rev] | @tsv
' "$manifest")"

mkdir "$project/.lake/packages"
count=0
while IFS=$'\t' read -r name url rev; do
    [ -n "$name" ] || continue
    echo "::group::Dependency $name"
    bash "$here/fetch-repo.sh" "$url" "$rev" "$project/.lake/packages/$name"
    echo "::endgroup::"
    count=$((count + 1))
done <<<"$entries"

echo "Materialized $count dependencies into $project/.lake/packages"
