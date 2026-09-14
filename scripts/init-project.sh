#!/usr/bin/env bash
# Turn a directory holding the fetched .lean files into the Lake project that
# comparator expects: one `lean_lib` per module, no dependencies, no manifest.
#
# Usage: init-project.sh <project_dir> <toolchain.lock> <module>...
#
#   <project_dir>    must already contain <module>.lean for every <module>
#   <toolchain.lock> only used to write lean-toolchain, which documents the
#                    Lean version for anyone reproducing the build with elan;
#                    the workflow itself runs the pinned toolchain from PATH.
#
# This mirrors the layout comparator's own test runner creates (runtests.lean):
# lakefile.toml, lean-toolchain and the module sources side by side. Lake keeps
# every build artifact under .lake, which is the only writable path the
# comparator jail gets; it is created here so the jail can bind-mount it.
set -euo pipefail

project="${1:-}"
lock="${2:-}"
if [ -z "$project" ] || [ ! -d "$project" ] || [ -z "$lock" ] || [ ! -f "$lock" ] || [ $# -lt 3 ]; then
    echo "Usage: $(basename "$0") <project_dir> <toolchain.lock> <module>..." >&2
    exit 1
fi
shift 2

lean_version="$(jq -er '.lean.version' "$lock")"

{
    echo 'name = "leanvrf"'
    echo 'version = "0.1.0"'
    for module in "$@"; do
        if ! [[ "$module" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "Error: invalid module name '$module'" >&2
            exit 1
        fi
        if [ ! -f "$project/$module.lean" ] || [ -L "$project/$module.lean" ]; then
            echo "Error: $project/$module.lean is missing or not a regular file" >&2
            exit 1
        fi
        printf '\n[[lean_lib]]\nname = "%s"\n' "$module"
    done
} > "$project/lakefile.toml"

echo "leanprover/lean4:$lean_version" > "$project/lean-toolchain"
mkdir -p "$project/.lake"

echo "Lake project initialised in $project for modules: $*"
