#!/usr/bin/env bash
# Build one Lake workspace and export the closure of the given declarations, inside
# a throwaway bubblewrap jail that contains nothing but that workspace.
#
# Usage: sandboxed-build-export.sh <workspace_dir> <module> <targets_file> <export_out>
#
#   <workspace_dir>  checkout prepared by fetch-repo.sh + materialize-deps.sh
#   <module>         Lean module to build and export from (dotted name)
#   <targets_file>   declarations to export, one per line, as printed by
#                    `comparator --print-export-targets`
#   <export_out>     host path that receives the lean4export output
#
# Environment:
#   LEAN_ROOT   Trusted Lean toolchain incl. lean4export (default: /opt/lean)
#
# This is where prover code runs: `lake build` elaborates the workspace and its
# dependencies (lakefiles, `#eval`, macros, build scripts), then `lake env
# lean4export` loads the resulting .olean files and writes the export to stdout,
# which is the only thing that leaves the jail. The jail is the entire wall:
# no network, own user/pid/ipc/uts namespaces, no nested user namespaces,
# toolchain read-only, the workspace read-only except for its .lake. Only this
# one workspace is mounted, so a challenge build cannot see the solution nor
# the other way round, and when the jail exits every process it started is
# gone; nothing that ran here exists any more when the exports are compared.
#
# lean4export runs in the same jail as the build that produced the .oleans it
# reads, deliberately: those bytes are that workspace's own output and are
# judged downstream (statement comparison against the other export, axiom
# check, three kernels), so nothing is gained by isolating the exporter from
# them. The export travels through a pipe owned by this script, which no
# process inside the jail can reach.
#
# There is deliberately no wall-clock limit: the prover pays for their own
# runner minutes, a killed run can never yield an attestation, and a tight
# bound would only reject slow-but-honest proofs. GitHub's job limit applies.
set -euo pipefail

workspace="${1:-}"
module="${2:-}"
targets_file="${3:-}"
export_out="${4:-}"
if [ -z "$workspace" ] || [ ! -d "$workspace" ] || [ -z "$module" ] || [ -z "$targets_file" ] \
    || [ ! -f "$targets_file" ] || [ -z "$export_out" ] || [ $# -ne 4 ]; then
    echo "Usage: $(basename "$0") <workspace_dir> <module> <targets_file> <export_out>" >&2
    exit 1
fi
if ! [[ "$module" =~ ^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$ ]]; then
    echo "Error: '$module' is not a Lean module name" >&2
    exit 1
fi
LEAN_ROOT="${LEAN_ROOT:-/opt/lean}"
workspace="$(realpath "$workspace")"
# fetch-repo.sh created this as a plain directory after checking the tree; a
# symlink here would redirect the writable bind mount below.
if [ ! -d "$workspace/.lake" ] || [ -L "$workspace/.lake" ]; then
    echo "Error: $workspace/.lake is missing or not a plain directory" >&2
    exit 1
fi

targets=()
while IFS= read -r line; do
    [ -n "$line" ] || continue
    if ! [[ "$line" =~ ^[^[:space:]]+$ ]]; then
        echo "Error: invalid export target '$line'" >&2
        exit 1
    fi
    targets+=("$line")
done <"$targets_file"
if [ "${#targets[@]}" -eq 0 ]; then
    echo "Error: no export targets" >&2
    exit 1
fi

mkdir -p "$(dirname "$export_out")"
rm -f "$export_out"

# Build output goes to stderr so that stdout carries the export alone.
# /etc/alternatives: Debian's `which` and a few /usr/bin entries are symlinks
# into it; nothing else from /etc is visible, so Lake and git see no host
# configuration.
echo "Building and exporting $module from $workspace"
if ! bwrap \
    --unshare-all \
    --unshare-user \
    --disable-userns \
    --die-with-parent \
    --ro-bind /usr /usr \
    --ro-bind /lib /lib \
    --ro-bind /lib64 /lib64 \
    --ro-bind /bin /bin \
    --ro-bind-try /etc/alternatives /etc/alternatives \
    --ro-bind "$LEAN_ROOT" /opt/lean \
    --ro-bind "$workspace" /work \
    --bind "$workspace/.lake" /work/.lake \
    --tmpfs /tmp \
    --proc /proc \
    --dev /dev \
    --chdir /work \
    env -i PATH="/opt/lean/bin:/usr/bin:/bin" HOME="/tmp" LEAN_ABORT_ON_PANIC=1 \
    /bin/sh -c 'mod="$1"; shift; lake build --no-cache "$mod" >&2 && exec lake env lean4export "$mod" -- "$@"' \
    sh "$module" "${targets[@]}" >"$export_out"; then
    rm -f "$export_out"
    echo "Error: building or exporting $module failed" >&2
    exit 1
fi
if [ ! -s "$export_out" ]; then
    echo "Error: export of $module is empty" >&2
    exit 1
fi
echo "Exported $module: $(wc -c <"$export_out") bytes"
