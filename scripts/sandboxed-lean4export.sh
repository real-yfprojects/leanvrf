#!/usr/bin/env bash
# Run lean4export on an untrusted .lean file inside a sealed bubblewrap jail
# and sanitise the resulting export stream before it is handed to any verifier.
#
# Usage: sandboxed-lean4export.sh <input_lean_file> <output_export_file>
#
# Environment:
#   LEAN_ROOT   Directory holding the trusted Lean toolchain (default: /opt/lean)
#
# There is deliberately no wall-clock limit: the prover pays for their own
# runner minutes, a killed export can never yield an attestation, and a tight
# bound would only reject slow-but-honest proofs. GitHub's job limit applies.
set -euo pipefail

input_file="${1:-}"
output_file="${2:-}"

if [ -z "$input_file" ] || [ -z "$output_file" ]; then
    echo "Usage: $(basename "$0") <input_lean_file> <output_export_file>" >&2
    exit 1
fi

LEAN_ROOT="${LEAN_ROOT:-/opt/lean}"

# 1. Ensure host target exists as an empty, regular file
rm -f "$output_file"
touch "$output_file"

# 2. Execute in sealed Bubblewrap jail
bwrap \
    --unshare-all \
    --unshare-net \
    --die-with-parent \
    --ro-bind /usr /usr \
    --ro-bind /lib /lib \
    --ro-bind /lib64 /lib64 \
    --ro-bind /bin /bin \
    --ro-bind "$LEAN_ROOT" /opt/lean \
    --ro-bind "$input_file" /input/source.lean \
    --tmpfs /tmp \
    --tmpfs /scratch \
    --bind "$output_file" /out/target.export \
    --proc /proc \
    --dev /dev \
    --chdir /scratch \
    env -i PATH="/opt/lean/bin:/bin:/usr/bin" HOME="/tmp" \
    lean4export /input/source.lean /out/target.export

# 3. Defensive check: verify regular file and not a symlink/FIFO
if [ ! -f "$output_file" ] || [ -L "$output_file" ]; then
    echo "Security violation: Export output is missing or an invalid file descriptor." >&2
    exit 1
fi

# 4. Stream sanitation check
# - Rejects lines exceeding 4096 chars (buffer safety)
# - Rejects integer indices > 2^32 - 1 (integer overflow mitigation)
# - Rejects non-printable/binary control bytes
LC_ALL=C awk '
    /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\xFF]/ {
    print "Sanitation error: Non-ASCII/binary byte detected at line " NR > "/dev/stderr";
    exit 1;
    }
    length($0) > 4096 {
    print "Sanitation error: Line " NR " exceeds length limit (4096)" > "/dev/stderr";
    exit 1;
    }
    $1 ~ /^[0-9]+$/ && $1 > 4294967295 {
    print "Sanitation error: 32-bit index overflow at line " NR > "/dev/stderr";
    exit 1;
    }
' "$output_file"
