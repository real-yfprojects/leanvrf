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
# jail), no nested user namespaces, toolchain and verifier binaries read-only,
# the project read-only except for .lake, which Lake needs and which landrun
# further restricts to the build steps. Elaborating Solution.lean is the only
# point where untrusted code executes, and comparator exports the challenge
# before it does.
#
# Inside the jail, landrun is the only wall between that untrusted build and
# comparator, and comparator invokes it with --best-effort: on a kernel (or in
# a namespace) where Landlock is unavailable it would run the build and the
# kernels *unconfined* without reporting anything. So before comparator starts,
# the jail probes landrun behaviourally with comparator's own base flags: a
# write outside the granted paths must be refused, and the same write with the
# path granted must succeed (to tell "enforced" apart from "broken").
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

# Runs as the jail's init process. The landrun flags are the fixed prefix of
# comparator's buildLandrunArgs (Main.lean); the probe writes into the jail's
# private /tmp, which is writable for everything not under landrun.
jail_entry='
set -eu
probe=/tmp/landlock-probe
mkdir -p "$probe/allowed"
if landrun --best-effort --ro / --rw /dev -ldd -add-exec \
        -- /bin/sh -c "echo x > $probe/denied" 2>/dev/null; then
    echo "Landlock self-test failed: landrun --ro / let a write outside the granted paths through; Landlock is not enforced in this jail" >&2
    exit 1
fi
if ! landrun --best-effort --ro / --rw /dev -ldd -add-exec --rwx "$probe/allowed" \
        -- /bin/sh -c "echo x > $probe/allowed/f"; then
    echo "Landlock self-test failed: landrun refused a write to a granted path" >&2
    exit 1
fi
rm -r "$probe"
exec lake env comparator /config/comparator.json
'

# --unshare-all covers user, pid, net, ipc and uts namespaces. The abstract
# unix sockets comparator's README guards against with systemd-run are scoped
# to the network namespace, which the jail does not share with the host.
# --disable-userns forbids creating further user namespaces inside the jail:
# nothing in the pipeline needs them (landrun uses Landlock, not namespaces),
# and they are the largest piece of kernel surface --unshare-user opens up.
exec bwrap \
    --unshare-all \
    --disable-userns \
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
    /bin/sh -c "$jail_entry"
