#!/usr/bin/env bash
# Provision the pinned Lean toolchain and verifier binaries from toolchain.lock.
#
# Usage: provision-toolchain.sh [--lean-only] <toolchain.lock>
#
#   --lean-only   Install just the Lean release, skip the prebuilt tools
#                 (used by build-tools.yml, which produces those tools).
#
# Environment:
#   LEAN_ROOT         Where the Lean release is unpacked (default: /opt/lean)
#   VERIFIER_BIN_DIR  Where verifier binaries are installed (default: /opt/bin)
#
# Every artifact is downloaded over HTTPS and rejected unless its sha256 matches
# the lockfile, which comes from the trusted checkout at job.workflow_sha.
# Nothing is ever restored from a cache: in a reusable workflow actions/cache is
# scoped to the *caller's* repository, i.e. the prover's, and could be seeded.
set -euo pipefail

lean_only=0
if [ "${1:-}" = "--lean-only" ]; then
    lean_only=1
    shift
fi
lock="${1:-}"
if [ -z "$lock" ] || [ ! -f "$lock" ]; then
    echo "Usage: $(basename "$0") [--lean-only] <toolchain.lock>" >&2
    exit 1
fi

LEAN_ROOT="${LEAN_ROOT:-/opt/lean}"
VERIFIER_BIN_DIR="${VERIFIER_BIN_DIR:-/opt/bin}"

# Both directories are wiped below; refuse anything that is not an absolute, non-root path.
for dir in "$LEAN_ROOT" "$VERIFIER_BIN_DIR"; do
    if [[ "$dir" != /?* ]]; then
        echo "Error: refusing to provision into '$dir'" >&2
        exit 1
    fi
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Hardened fetch + hash check. Refuses to proceed on any mismatch.
fetch_pinned() {
    local url="$1" sha="$2" dest="$3"
    if ! [[ "$sha" =~ ^[a-f0-9]{64}$ ]]; then
        echo "Error: malformed sha256 for $url in lockfile" >&2
        return 1
    fi
    curl \
        --proto '=https' \
        --proto-redir '=https' \
        --tlsv1.2 \
        --fail \
        --silent \
        --show-error \
        --location \
        -o "$dest" \
        -- "$url"
    echo "$sha  $dest" | sha256sum -c --quiet -
}

# 1. Lean release tarball -> $LEAN_ROOT
lean_url="$(jq -er '.lean.url' "$lock")"
lean_sha="$(jq -er '.lean.sha256' "$lock")"
echo "Fetching Lean toolchain: $lean_url"
fetch_pinned "$lean_url" "$lean_sha" "$work/lean.tar.zst"

sudo rm -rf "$LEAN_ROOT"
sudo mkdir -p "$LEAN_ROOT"
# Upstream archives contain a single top-level lean-<ver>-linux/ directory.
sudo tar --zstd -xf "$work/lean.tar.zst" -C "$LEAN_ROOT" --strip-components=1
if [ ! -x "$LEAN_ROOT/bin/lean" ]; then
    echo "Error: extracted toolchain has no bin/lean" >&2
    exit 1
fi

if [ "$lean_only" = 1 ]; then
    sudo chown -R root:root "$LEAN_ROOT"
    sudo chmod -R a-w "$LEAN_ROOT"
    echo "Lean toolchain provisioned: $LEAN_ROOT ($(jq -r '.lean.version' "$lock"))"
    exit 0
fi

# 2. Prebuilt tools -> $LEAN_ROOT/bin (export jail) or $VERIFIER_BIN_DIR (verifier jail)
sudo rm -rf "$VERIFIER_BIN_DIR"
sudo mkdir -p "$VERIFIER_BIN_DIR"

n="$(jq -er '.tools | length' "$lock")"
for ((i = 0; i < n; i++)); do
    name="$(jq -er ".tools[$i].name" "$lock")"
    url="$(jq -er ".tools[$i].url" "$lock")"
    sha="$(jq -er ".tools[$i].sha256" "$lock")"
    install="$(jq -er ".tools[$i].install" "$lock")"

    if ! [[ "$name" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        echo "Error: invalid tool name '$name' in lockfile" >&2
        exit 1
    fi
    case "$install" in
        toolchain) dest_dir="$LEAN_ROOT/bin" ;;
        verifier)  dest_dir="$VERIFIER_BIN_DIR" ;;
        *)
            echo "Error: unknown install target '$install' for $name" >&2
            exit 1
            ;;
    esac

    echo "Fetching $name -> $dest_dir"
    fetch_pinned "$url" "$sha" "$work/$name"
    sudo install -m 0555 -o root -g root "$work/$name" "$dest_dir/$name"
done

# 3. Lock everything down: root-owned, read-only, no later modification by the runner user
sudo chown -R root:root "$LEAN_ROOT" "$VERIFIER_BIN_DIR"
sudo chmod -R a-w "$LEAN_ROOT" "$VERIFIER_BIN_DIR"

echo "Toolchain provisioned: $LEAN_ROOT ($(jq -r '.lean.version' "$lock")), verifiers in $VERIFIER_BIN_DIR"
