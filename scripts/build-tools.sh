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
# An optional `patches` list names diffs, relative to the lockfile's directory
# (i.e. this repository), applied with `git apply` before building; they are
# part of the trusted checkout and thus of the attested build recipe.
# Lake builds use the locked Lean release, not elan, so every Lean-based tool
# is compiled against the same toolchain that will later run it. Rust, Go and
# GHC come from the hash-pinned tarballs in `build_toolchains`, never from the
# runner image. Afterwards <dist_dir>/SHA256SUMS and <dist_dir>/toolchain.lock
# (the input lock with the fresh hashes filled in) are written.
#
# Hardening. The kernels judge attacker-influenced export bytes and a crash is
# always the safe verdict (comparator treats any non-zero exit as a rejection),
# so the build turns silent misbehaviour into aborts where the compiler lets
# it: Rust is built with overflow checks and panic=abort, eink0rn's runtime
# refuses `+RTS`/GHCRTS overrides of its baked-in limits (see the `script` in
# the lock). On top of that the usual ELF mitigations (PIE, full RELRO, NX
# stack) are requested where the toolchain supports them and audit_elf checks
# the produced binaries rather than trusting the flags. The Lean-based tools
# are compiled by the toolchain's own `leanc`; its flags are not overridden
# because LEAN_CC drops leanc's internal sysroot/lld flags, and the C++ kernel
# they call lives in the prebuilt libleanshared.so anyway.
#
# Every tool is built with SOURCE_DATE_EPOCH set to its commit time and with
# the scratch directory remapped out of Rust debug info, as a step towards
# rebuilds that reproduce the attested hashes.
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
tar -xzf "$work/go.tar.gz" -C "$work" # unpacks to $work/go
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

# Check the ELF mitigations of a produced binary instead of trusting the flags
# that asked for them. An executable stack is always an error. PIE and full
# RELRO (GNU_RELRO segment + BIND_NOW) are errors when `strict` is 1 and
# warnings otherwise. Rust guarantees all three on x86_64-unknown-linux-gnu so
# cargo builds are strict; Go's static PIE, the GHC bindist (whose libraries
# are not PIC, so no PIE is possible) and leanc's link are only reported until
# a build has shown what they actually emit, at which point tighten this.
audit_elf() {
    local f="$1" strict="$2" hdr dyn rc=0
    hdr="$(readelf -hlW -- "$f")"
    dyn="$(readelf -dW -- "$f" 2>/dev/null || true)"
    if grep -qE '^\s*GNU_STACK\s.*\sRWE\s' <<<"$hdr"; then
        echo "::error::$f has an executable stack" >&2
        rc=1
    fi
    if ! grep -qE 'GNU_STACK' <<<"$hdr"; then
        echo "::error::$f has no GNU_STACK program header (executable stack by default)" >&2
        rc=1
    fi
    local level="::warning::"
    [ "$strict" = 1 ] && level="::error::"
    local missing=()
    grep -qE 'Type:\s+DYN' <<<"$hdr" || missing+=("PIE")
    grep -qE '^\s*GNU_RELRO\s' <<<"$hdr" || missing+=("RELRO")
    grep -qE '\(BIND_NOW\)|\(FLAGS\)\s.*BIND_NOW|\(FLAGS_1\)\s.*NOW' <<<"$dyn" || missing+=("BIND_NOW")
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "${level}$f lacks: ${missing[*]}" >&2
        [ "$strict" = 1 ] && rc=1
    fi
    return "$rc"
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
    while IFS= read -r patch; do
        [ -n "$patch" ] || continue
        if [[ "$patch" = /* ]] || [[ "$patch" = *..* ]]; then
            echo "Error: patch path '$patch' must be relative and free of '..'" >&2
            exit 1
        fi
        patch_file="$(dirname "$lock")/$patch"
        echo "Applying $patch ($(sha256sum "$patch_file" | awk '{print $1}'))"
        git -C "$src" apply --check "$patch_file"
        git -C "$src" apply "$patch_file"
    done < <(jq -r '.patches // [] | .[]' <<<"$tool")
    # Timestamps embedded by the compilers come from the pinned commit, not from now.
    SOURCE_DATE_EPOCH="$(git -C "$src" log -1 --format=%ct)"
    export SOURCE_DATE_EPOCH

    strict=0
    case "$build" in
        lake)
            target="$(jq -er '.target' <<<"$tool")"
            artifact="$(jq -er '.artifact' <<<"$tool")"
            (cd "$src" && lake build "$target")
            cp "$src/$artifact" "$dist/$name"
            ;;
        cargo)
            artifact="$(jq -er '.artifact' <<<"$tool")"
            # overflow-checks: wrapped arithmetic in a kernel is a silent wrong
            # answer, a panic is a rejection. panic=abort: no unwinding for a
            # catch_unwind on some worker thread to swallow. The remaps keep the
            # random scratch path out of panic messages and debug info.
            rustflags="-C overflow-checks=on -C panic=abort"
            rustflags+=" --remap-path-prefix=$work=/build"
            rustflags+=" --remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=/cargo"
            (cd "$src" && RUSTFLAGS="$rustflags" cargo build --release --locked)
            cp "$src/$artifact" "$dist/$name"
            strict=1
            ;;
        go)
            package="$(jq -er '.package' <<<"$tool")"
            # Static PIE (internal linking supports it without cgo on linux/amd64);
            # -mod=readonly so go.sum is the only source of truth and a stray
            # go.mod edit can never resolve modules over the network; no build
            # id so identical inputs give identical bytes.
            (cd "$src" && CGO_ENABLED=0 go build -mod=readonly -trimpath -buildmode=pie \
                -ldflags='-s -w -buildid=' -o "$dist/$name" "$package")
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
    audit_elf "$dist/$name" "$strict"
    echo "::endgroup::"
done

# Checksums + a copy of the lock with the real hashes, ready to commit.
# Names were validated above as single safe words, so splitting is the intent.
# shellcheck disable=SC2046
(cd "$dist" && sha256sum -- $(jq -r '.tools[].name' "$lock") >SHA256SUMS && cat SHA256SUMS)

jq --rawfile sums "$dist/SHA256SUMS" '
  ($sums | split("\n") | map(select(length > 0) | split("  ") | {key: .[1], value: .[0]}) | from_entries) as $h
  | .tools |= map(.sha256 = $h[.name])
' "$lock" >"$dist/toolchain.lock"
