#!/usr/bin/env bash
# Build every tool listed in toolchain.lock from source at its pinned commit.
#
# Usage: build-tools.sh <toolchain.lock> <dist_dir>
#
# Environment:
#   LEAN_ROOT   Provisioned Lean toolchain used for `lake` builds (default: /opt/lean)
#
# Each tool is cloned at exactly `commit` (verified after checkout), built with
# the recipe named by `build` (lake | cargo | go | script) and copied to
# <dist_dir>/<name>. `script` runs the tool's own build script from the pinned
# checkout (`script` field) and takes `artifact` from where it puts the binary.
# Lake builds use the locked Lean release, not elan, so every Lean-based tool
# is compiled against the same toolchain that will later run it. Rust, Go and
# GHC come from the hash-pinned tarballs in `build_toolchains`, never from the
# runner image. Afterwards <dist_dir>/SHA256SUMS and <dist_dir>/toolchain.lock
# (the input lock with the fresh hashes filled in) are written.
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

# Same hardened fetch + hash check as provision-toolchain.sh.
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

# Rust, Go and GHC from the hash-pinned tarballs in `build_toolchains`, installed
# into the scratch dir and put in front of whatever the runner image ships.
echo "::group::Provision build toolchains"
rust_version="$(jq -er '.build_toolchains.rust.version' "$lock")"
fetch_pinned "$(jq -er '.build_toolchains.rust.url' "$lock")" \
             "$(jq -er '.build_toolchains.rust.sha256' "$lock")" "$work/rust.tar.xz"
mkdir "$work/rust-dist"
tar -xJf "$work/rust.tar.xz" -C "$work/rust-dist" --strip-components=1
# Only the compiler, std and cargo; the tarball also carries docs, clippy, ...
"$work/rust-dist/install.sh" --prefix="$work/rust" --disable-ldconfig \
    --components=rustc,cargo,rust-std-x86_64-unknown-linux-gnu >/dev/null
export PATH="$work/rust/bin:$PATH"
if ! cargo --version | grep -qF "cargo $rust_version "; then
    echo "Error: cargo in PATH is '$(cargo --version)', lockfile wants $rust_version" >&2
    exit 1
fi

go_version="$(jq -er '.build_toolchains.go.version' "$lock")"
fetch_pinned "$(jq -er '.build_toolchains.go.url' "$lock")" \
             "$(jq -er '.build_toolchains.go.sha256' "$lock")" "$work/go.tar.gz"
tar -xzf "$work/go.tar.gz" -C "$work"   # unpacks to $work/go
export PATH="$work/go/bin:$PATH"
# Never let go auto-download a newer toolchain because a go.mod asks for one.
export GOTOOLCHAIN=local
if ! go version | grep -qF " $go_version "; then
    echo "Error: go in PATH is '$(go version)', lockfile wants $go_version" >&2
    exit 1
fi
ghc_version="$(jq -er '.build_toolchains.ghc.version' "$lock")"
fetch_pinned "$(jq -er '.build_toolchains.ghc.url' "$lock")" \
             "$(jq -er '.build_toolchains.ghc.sha256' "$lock")" "$work/ghc.tar.xz"
mkdir "$work/ghc-dist"
tar -xJf "$work/ghc.tar.xz" -C "$work/ghc-dist" --strip-components=1
# A GHC bindist is relocated by its configure script; nothing is compiled here.
# Linking Haskell programs later needs the runner's gcc and libgmp-dev.
(cd "$work/ghc-dist" && ./configure --prefix="$work/ghc" >/dev/null && make install >/dev/null)
export PATH="$work/ghc/bin:$PATH"
if [ "$(ghc --numeric-version)" != "$ghc_version" ]; then
    echo "Error: ghc in PATH is '$(ghc --numeric-version)', lockfile wants $ghc_version" >&2
    exit 1
fi
echo "rust: $(cargo --version)   go: $(go version)   ghc: $(ghc --numeric-version)   lean: $(lean --version)"
echo "::endgroup::"

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
        script)
            script="$(jq -er '.script' <<<"$tool")"
            artifact="$(jq -er '.artifact' <<<"$tool")"
            (cd "$src" && bash -c -- "$script")
            cp "$src/$artifact" "$dist/$name"
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
