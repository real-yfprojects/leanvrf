#!/usr/bin/env bash
# Build every tool listed in toolchain.lock from source at its pinned commit.
#
# Usage: build-tools.sh <toolchain.lock> <dist_dir>
#
# Environment:
#   LEAN_ROOT   Provisioned Lean toolchain used for `lake` builds (default: /opt/lean)
#
# Each tool is cloned at exactly `commit` (verified after checkout), built with
# the recipe named by `build` (lake | cargo | go) and copied to <dist_dir>/<name>.
# Lake builds use the locked Lean release, not elan, so every Lean-based tool
# is compiled against the same toolchain that will later run it. Afterwards
# <dist_dir>/SHA256SUMS and <dist_dir>/toolchain.lock (the input lock with the
# fresh hashes filled in) are written.
set -euo pipefail

lock="${1:-}"
dist="${2:-}"
if [ -z "$lock" ] || [ ! -f "$lock" ] || [ -z "$dist" ]; then
    echo "Usage: $(basename "$0") <toolchain.lock> <dist_dir>" >&2
    exit 1
fi
lock="$(realpath "$lock")"
mkdir -p "$dist"
dist="$(realpath "$dist")"

LEAN_ROOT="${LEAN_ROOT:-/opt/lean}"
export PATH="$LEAN_ROOT/bin:$PATH"

# The toolchain in PATH must be the locked release, otherwise the .olean files
# the built tools accept would not match what the verifier workflow compiles.
want="$(jq -er '.lean.version' "$lock")"
have="$(lean --version | sed -E 's/.*version ([0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?).*/v\1/')"
if [ "$have" != "$want" ]; then
    echo "Error: lean in PATH is $have, lockfile wants $want" >&2
    exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

clone_pinned() {
    local repo="$1" commit="$2" dir="$3"
    git init -q "$dir"
    git -C "$dir" remote add origin "https://github.com/${repo}.git"
    git -C "$dir" fetch -q --depth 1 origin "$commit"
    git -C "$dir" checkout -q --detach FETCH_HEAD
    if [ "$(git -C "$dir" rev-parse HEAD)" != "$commit" ]; then
        echo "Error: $repo checked out $(git -C "$dir" rev-parse HEAD), expected $commit" >&2
        return 1
    fi
}

n="$(jq -er '.tools | length' "$lock")"
for ((i = 0; i < n; i++)); do
    tool="$(jq -c ".tools[$i]" "$lock")"
    name="$(jq -er '.name' <<<"$tool")"
    repo="$(jq -er '.repo' <<<"$tool")"
    commit="$(jq -er '.commit' <<<"$tool")"
    build="$(jq -er '.build' <<<"$tool")"

    if ! [[ "$name" =~ ^[A-Za-z0-9_.-]+$ ]] || ! [[ "$commit" =~ ^[a-f0-9]{40}$ ]]; then
        echo "Error: invalid name/commit for tool #$i" >&2
        exit 1
    fi

    echo "::group::Build $name ($repo@${commit:0:12}, $build)"
    src="$work/$name"
    clone_pinned "$repo" "$commit" "$src"

    case "$build" in
        lake)
            target="$(jq -er '.target' <<<"$tool")"
            artifact="$(jq -er '.artifact' <<<"$tool")"
            (cd "$src" && lake build "$target")
            cp "$src/$artifact" "$dist/$name"
            ;;
        cargo)
            artifact="$(jq -er '.artifact' <<<"$tool")"
            (cd "$src" && cargo build --release --locked)
            cp "$src/$artifact" "$dist/$name"
            ;;
        go)
            package="$(jq -er '.package' <<<"$tool")"
            (cd "$src" && CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o "$dist/$name" "$package")
            ;;
        *)
            echo "Error: unknown build kind '$build' for $name" >&2
            exit 1
            ;;
    esac
    chmod 0755 "$dist/$name"
    file "$dist/$name"
    echo "::endgroup::"
done

# Checksums + a copy of the lock with the real hashes, ready to commit.
(cd "$dist" && sha256sum -- $(jq -r '.tools[].name' "$lock") > SHA256SUMS && cat SHA256SUMS)

jq --rawfile sums "$dist/SHA256SUMS" '
  ($sums | split("\n") | map(select(length > 0) | split("  ") | {key: .[1], value: .[0]}) | from_entries) as $h
  | .tools |= map(.sha256 = $h[.name])
' "$lock" > "$dist/toolchain.lock"
