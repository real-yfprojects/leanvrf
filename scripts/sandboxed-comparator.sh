#!/usr/bin/env bash
# Run comparator on the assembled Lake project inside a sealed bubblewrap jail.
#
# Usage: sandboxed-comparator.sh <project_dir> <config.json>
#
# Environment:
#   LEAN_ROOT         Trusted Lean toolchain incl. lean4export (default: /opt/lean)
#   VERIFIER_BIN_DIR  Directory holding comparator, landrun and the external
#                     kernels named in the config (default: /opt/bin)
#
# comparator (leanprover/comparator) is configured through the JSON file only
# and drives the whole check itself: for Challenge and then Solution it runs
# `lake build` and `lean4export` under a landrun (Landlock) sandbox, compares
# the exported statements, checks the axiom whitelist, feeds the solution
# export to each configured external kernel (again under landrun) and finally
# replays it through the Lean kernel in-process. It must be started via
# `lake env` from the project directory so that LEAN_PATH points at
# .lake/build/lib/lean, and it needs `lean`, `lake`, `git`, `landrun`,
# `lean4export` and the kernel binaries in PATH.
#
# This jail is the outer wall around all of that: no network, own PID
# namespace (everything the solution build might leave running dies with the
# jail), toolchain and verifier binaries read-only, the project read-only
# except for .lake, which Lake needs and which landrun further restricts to
# the build steps. Elaborating Solution.lean is the only point where untrusted
# code executes, and comparator exports the challenge before it does.
#
# There is deliberately no wall-clock limit: the prover pays for their own
# runner minutes, a killed run can never yield an attestation, and a tight
# bound would only reject slow-but-honest proofs. GitHub's job limit applies.
set -euo pipefail

project="${1:-}"
config="${2:-}"
if [ -z "$project" ] || [ ! -d "$project" ] || [ -z "$config" ] || [ ! -f "$config" ]; then
    echo "Usage: $(basename "$0") <project_dir> <config.json>" >&2
    exit 1
fi

LEAN_ROOT="${LEAN_ROOT:-/opt/lean}"
VERIFIER_BIN_DIR="${VERIFIER_BIN_DIR:-/opt/bin}"
project="$(realpath "$project")"
config="$(realpath "$config")"
mkdir -p "$project/.lake"

# --unshare-all covers user, pid, net, ipc and uts namespaces. The abstract
# unix sockets comparator's README guards against with systemd-run are scoped
# to the network namespace, which the jail does not share with the host.
exec bwrap \
    --unshare-all \
    --die-with-parent \
    --ro-bind /usr /usr \
    --ro-bind /lib /lib \
    --ro-bind /lib64 /lib64 \
    --ro-bind /bin /bin \
    --ro-bind "$LEAN_ROOT" /opt/lean \
    --ro-bind "$VERIFIER_BIN_DIR" /opt/bin \
    --ro-bind "$project" /work \
    --bind "$project/.lake" /work/.lake \
    --ro-bind "$config" /config/comparator.json \
    --tmpfs /tmp \
    --proc /proc \
    --dev /dev \
    --chdir /work \
    env -i PATH="/opt/lean/bin:/opt/bin:/usr/bin:/bin" HOME="/tmp" LEAN_ABORT_ON_PANIC=1 \
    lake env comparator /config/comparator.json
