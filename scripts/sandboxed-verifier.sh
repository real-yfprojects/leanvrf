#!/usr/bin/env bash
# Run a trusted verifier binary (comparator, nanoda, lean4lean) in a pristine,
# sealed bubblewrap jail. The jail only sees the inert .export files; no Lean
# toolchain is mounted, so no code from the theories can execute here.
#
# Usage: sandboxed-verifier.sh <binary> [args...]
#        <binary> is a path inside the jail (e.g. /opt/bin/comparator)
#
# Environment:
#   VERIFIER_BIN_DIR  Host directory with verifier binaries (default: /opt/bin)
#   EXPORTS_DIR       Host directory with sanitised .export files (default: /tmp/exports)
set -euo pipefail

binary="${1:-}"
if [ -z "$binary" ]; then
    echo "Usage: $(basename "$0") <binary> [args...]" >&2
    exit 1
fi
shift

VERIFIER_BIN_DIR="${VERIFIER_BIN_DIR:-/opt/bin}"
EXPORTS_DIR="${EXPORTS_DIR:-/tmp/exports}"

exec bwrap \
    --unshare-all \
    --unshare-net \
    --die-with-parent \
    --ro-bind /usr /usr \
    --ro-bind /lib /lib \
    --ro-bind /lib64 /lib64 \
    --ro-bind /bin /bin \
    --ro-bind "$VERIFIER_BIN_DIR" /opt/bin \
    --ro-bind "$EXPORTS_DIR" /exports \
    --tmpfs /tmp \
    --proc /proc \
    --dev /dev \
    --chdir /tmp \
    env -i PATH="/bin:/usr/bin:/opt/bin" HOME="/tmp" \
    "$binary" "$@"
