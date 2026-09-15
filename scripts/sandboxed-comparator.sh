#!/usr/bin/env bash
# Compare two lean4export outputs and run the kernels on the solution, inside a
# sealed bubblewrap jail that holds nothing but the verifier binaries and the two
# export files.
#
# Usage: sandboxed-comparator.sh <challenge.export> <solution.export> <config.json>
#
# Environment:
#   VERIFIER_BIN_DIR  Directory holding comparator, landrun and the external
#                     kernels named in the config (default: /opt/bin)
#
# The exports were produced by scripts/sandboxed-build-export.sh, each in its own
# jail that has since exited. comparator (leanprover/comparator, with
# patches/comparator applied) is configured through the JSON file only, which
# names the exports as /exports/challenge.export and /exports/solution.export;
# in that mode it neither builds nor exports and needs no Lean toolchain. It
# checks that the solution states the theorem exactly as the challenge does
# (the whole closure of the statement, constant by constant), that the solution
# depends only on whitelisted axioms, feeds the solution export to each
# configured external kernel under a landrun (Landlock) sandbox, and replays it
# through the Lean kernel in-process. Its exit status is the joint verdict.
#
# No prover code runs here -- only prover *bytes* are parsed (by comparator's
# export parser and by the kernels). The jail is still sealed the same way as
# the build jails: no network, own namespaces, no nested user namespaces,
# everything read-only except the private /tmp comparator uses for the kernels'
# input files. /dev is remounted read-only after bwrap populates it because
# comparator grants the kernels --rw /dev; --remount-ro touches only that
# tmpfs, the device nodes and /dev/pts are separate mounts and stay usable.
#
# landrun is invoked by comparator with --best-effort: on a kernel (or in a
# namespace) where Landlock is unavailable it would run the kernels
# *unconfined* without reporting anything. So before comparator starts, the
# jail probes landrun behaviourally with comparator's own base flags: a write
# outside the granted paths must be refused, and the same write with the path
# granted must succeed (to tell "enforced" apart from "broken").
set -euo pipefail

challenge_export="${1:-}"
solution_export="${2:-}"
config="${3:-}"
if [ -z "$challenge_export" ] || [ ! -f "$challenge_export" ] || [ -z "$solution_export" ] \
    || [ ! -f "$solution_export" ] || [ -z "$config" ] || [ ! -f "$config" ]; then
    echo "Usage: $(basename "$0") <challenge.export> <solution.export> <config.json>" >&2
    exit 1
fi
VERIFIER_BIN_DIR="${VERIFIER_BIN_DIR:-/opt/bin}"
challenge_export="$(realpath "$challenge_export")"
solution_export="$(realpath "$solution_export")"
config="$(realpath "$config")"

# Runs as the jail's init process. The landrun flags are the fixed prefix of
# comparator's buildLandrunArgs (Main.lean); the probe writes into the jail's
# private /tmp, which is writable for everything not under landrun. The third
# check runs with exactly those base flags, i.e. with --rw /dev granted, and
# still expects the write to /dev to fail: that is the read-only remount below
# doing its job, independent of Landlock.
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
if landrun --best-effort --ro / --rw /dev -ldd -add-exec \
        -- /bin/sh -c "echo x > /dev/leanvfy-probe" 2>/dev/null; then
    echo "Jail self-test failed: /dev is writable despite the read-only remount" >&2
    exit 1
fi
rm -r "$probe"
exec comparator /config/comparator.json
'

# --unshare-all covers pid, net, ipc and uts namespaces and *tries* a user
# namespace; --unshare-user makes that one mandatory (--disable-userns needs
# it, and a jail that silently fell back to the host's user namespace would
# be weaker than intended). --disable-userns forbids creating further user
# namespaces inside the jail: nothing here needs them (landrun uses Landlock,
# not namespaces), and they are the largest piece of kernel surface
# --unshare-user opens up.
exec bwrap \
    --unshare-all \
    --unshare-user \
    --disable-userns \
    --die-with-parent \
    --ro-bind /usr /usr \
    --ro-bind /lib /lib \
    --ro-bind /lib64 /lib64 \
    --ro-bind /bin /bin \
    --ro-bind "$VERIFIER_BIN_DIR" /opt/bin \
    --ro-bind "$challenge_export" /exports/challenge.export \
    --ro-bind "$solution_export" /exports/solution.export \
    --ro-bind "$config" /config/comparator.json \
    --tmpfs /tmp \
    --proc /proc \
    --dev /dev \
    --remount-ro /dev \
    --chdir /tmp \
    env -i PATH="/opt/bin:/usr/bin:/bin" HOME="/tmp" LEAN_ABORT_ON_PANIC=1 \
    /bin/sh -c "$jail_entry"
