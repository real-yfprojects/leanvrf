#!/usr/bin/env bash
# Run comparator on the challenge and solution Lake workspaces inside a sealed
# bubblewrap jail.
#
# Usage: sandboxed-comparator.sh <challenge_dir> <solution_dir> <config.json>
#
# Environment:
#   LEAN_ROOT         Trusted Lean toolchain incl. lean4export (default: /opt/lean)
#   VERIFIER_BIN_DIR  Directory holding comparator, landrun and the external
#                     kernels named in the config (default: /opt/bin)
#
# comparator (leanprover/comparator, with patches/comparator applied) is
# configured through the JSON file only and drives the whole check itself: in
# the challenge workspace and then in the solution workspace it runs
# `lake build`, `lake env` (to learn that workspace's LEAN_PATH) and
# `lean4export` under a landrun (Landlock) sandbox, compares the exported
# statements, checks the axiom whitelist, feeds the solution export to each
# configured external kernel (again under landrun) and finally replays it
# through the Lean kernel in-process. It needs `lean`, `lake`, `git`,
# `landrun`, `lean4export` and the kernel binaries in PATH; the config names
# the two workspaces as /work/challenge and /work/solution.
#
# This jail is the outer wall around all of that: no network, own PID
# namespace (everything a build might leave running dies with the jail), no
# nested user namespaces, toolchain and verifier binaries read-only, each
# workspace read-only except for its .lake, which Lake needs and which landrun
# further restricts to the steps working on that workspace.
#
# Both workspaces are prover-supplied, so both builds execute untrusted code
# (a `lakefile.lean`, `#eval`, a dependency's build script). Trust in the
# challenge is about what its sources *mean* to a reviewer, not about its
# build being benign, and the two are kept apart accordingly: comparator
# finishes building and exporting the challenge before anything from the
# solution workspace runs, the export then lives only in comparator's memory,
# and the landrun profile of each step can write nothing but that workspace's
# .lake. A process left behind by the challenge build inherits its Landlock
# domain (and cannot ptrace out of it), so it stays as confined as the build
# was; the jail's PID namespace reaps it at exit.
#
# The two .lake directories are meant to be the *only* paths the sandboxed
# steps can write. The one other candidate is /dev: bwrap's --dev is a fresh
# tmpfs owned by the jail user, and comparator grants every landrun step (both
# builds, both exports, each external kernel) --rw /dev. Nothing in the
# pipeline writes there, but it would be a scratch area shared between one
# build and the trusted steps that run after it, and a build could replace the
# /dev/stdout, /dev/fd, /dev/ptmx symlinks bwrap creates. So the tmpfs is
# remounted read-only right after it is populated. --remount-ro touches only
# that mount: the device nodes are separate bind mounts (and EROFS never
# applies to device nodes anyway), and /dev/pts is its own devpts mount, so
# both stay usable.
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

challenge="${1:-}"
solution="${2:-}"
config="${3:-}"
if [ -z "$challenge" ] || [ ! -d "$challenge" ] || [ -z "$solution" ] || [ ! -d "$solution" ] \
    || [ -z "$config" ] || [ ! -f "$config" ]; then
    echo "Usage: $(basename "$0") <challenge_dir> <solution_dir> <config.json>" >&2
    exit 1
fi

LEAN_ROOT="${LEAN_ROOT:-/opt/lean}"
VERIFIER_BIN_DIR="${VERIFIER_BIN_DIR:-/opt/bin}"
challenge="$(realpath "$challenge")"
solution="$(realpath "$solution")"
config="$(realpath "$config")"
if [ "$challenge" = "$solution" ]; then
    echo "Error: challenge and solution must be separate workspaces" >&2
    exit 1
fi
# fetch-repo.sh created these as plain directories after checking the tree; a
# symlink here would redirect the writable bind mount below.
for d in "$challenge" "$solution"; do
    if [ ! -d "$d/.lake" ] || [ -L "$d/.lake" ]; then
        echo "Error: $d/.lake is missing or not a plain directory" >&2
        exit 1
    fi
done

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

# /etc/alternatives is bound because Debian's `which` (comparator locates git
# with it) and a few other /usr/bin entries are symlinks into it; nothing else
# from /etc is visible, so there is no host git or Lake configuration inside.
# --unshare-all covers pid, net, ipc and uts namespaces and *tries* a user
# namespace; --unshare-user makes that one mandatory (--disable-userns needs
# it, and a jail that silently fell back to the host's user namespace would
# be weaker than intended). The abstract unix sockets comparator's README
# guards against with systemd-run are scoped to the network namespace, which
# the jail does not share with the host. --disable-userns forbids creating
# further user namespaces inside the jail: nothing in the pipeline needs them
# (landrun uses Landlock, not namespaces), and they are the largest piece of
# kernel surface --unshare-user opens up.
exec bwrap \
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
    --ro-bind "$VERIFIER_BIN_DIR" /opt/bin \
    --ro-bind "$challenge" /work/challenge \
    --bind "$challenge/.lake" /work/challenge/.lake \
    --ro-bind "$solution" /work/solution \
    --bind "$solution/.lake" /work/solution/.lake \
    --ro-bind "$config" /config/comparator.json \
    --tmpfs /tmp \
    --proc /proc \
    --dev /dev \
    --remount-ro /dev \
    --chdir /work/solution \
    env -i PATH="/opt/lean/bin:/opt/bin:/usr/bin:/bin" HOME="/tmp" LEAN_ABORT_ON_PANIC=1 \
    /bin/sh -c "$jail_entry"
