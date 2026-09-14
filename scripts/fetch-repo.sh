#!/usr/bin/env bash
# Check out one untrusted git repository at an exact commit.
#
# Usage: fetch-repo.sh [--require-toml] <https_url> <commit> <dest_dir>
#
#   <https_url>   prover-chosen locator; nothing about it is trusted
#   <commit>      full SHA-1 (40 hex) or SHA-256 (64 hex) object id
#   <dest_dir>    must not exist yet; created here, so nothing can sit there beforehand
#   --require-toml
#                 additionally demand a regular `lakefile.toml` and no `lakefile.lean` at
#                 the root. The workflow passes this for the challenge: a `lakefile.lean` is
#                 a program that runs at `lake build` and could write oleans a reviewer of
#                 the sources never sees, while TOML is inert.
#
# This is the only code path through which prover-controlled bytes reach the host, so it
# does one narrow thing -- make git put the commit's tree into <dest_dir> -- and refuses
# everything else:
#   - https only, also across redirects: protocol.allow=never plus an explicit allow for
#     https closes ext:: (command execution), file://, ssh://, git:// and any other
#     transport; the URL is validated first and passed after `--`.
#   - no credentials, no prompts, no host git config (see git-jail.sh). The prover cannot
#     make git use anything the runner may hold, and private repositories simply fail.
#   - git runs inside the bubblewrap jail of git-jail.sh, which has the network but can
#     write only to the destination directory. Hostile packfiles are parsed there; a git
#     bug yields a throwaway jail and a directory the pipeline treats as untrusted anyway.
#     transfer/fetch.fsckObjects reject malformed objects up front.
#   - exactly the requested commit: fetched by id (full fetch as fallback for hosts that do
#     not serve arbitrary ids), checked out detached, HEAD compared to the argument.
#     Git's SHA-1 implementation detects collision attacks on receipt.
#   - no hooks (not versioned, and core.hooksPath is neutralised anyway), no submodules
#     (trees with gitlink entries are rejected outright),
#     no clean/smudge filters (they need configuration that does not exist here).
#   - the tree may not contain `.lake` at any depth, nor Lake build outputs (*.olean,
#     *.ilean, *.trace, *.hash). The workflow bind-mounts <dest_dir>/.lake read-write into
#     the build jail, so a committed `.lake` (a symlink, say) would redirect that
#     mount; and a committed olean with a matching trace would make `lake build` a no-op,
#     letting the exported environment come from bytes nobody reviewing the sources sees.
#     `.lake` is created empty afterwards, so every olean the run reads was built here.
# Size and time are deliberately unbounded: the prover pays for the runner, and a failed
# fetch can never yield an attestation.
set -euo pipefail

require_toml=0
if [ "${1:-}" = "--require-toml" ]; then
    require_toml=1
    shift
fi

url="${1:-}"
commit="${2:-}"
dest="${3:-}"
if [ -z "$url" ] || [ -z "$commit" ] || [ -z "$dest" ] || [ $# -ne 3 ]; then
    echo "Usage: $(basename "$0") [--require-toml] <https_url> <commit> <dest_dir>" >&2
    exit 1
fi

# No whitespace or control characters (log injection, argument confusion), no userinfo
# (credentials do not belong in a locator), nothing but https.
if ! [[ "$url" =~ ^https://[^[:space:][:cntrl:]@]+$ ]]; then
    echo "Error: repository URL must be https:// without userinfo or whitespace" >&2
    exit 1
fi
if ! [[ "$commit" =~ ^([a-f0-9]{40}|[a-f0-9]{64})$ ]]; then
    echo "Error: commit must be a full lowercase SHA-1 or SHA-256 object id" >&2
    exit 1
fi
if [ -e "$dest" ] || [ -L "$dest" ]; then
    echo "Error: destination '$dest' already exists" >&2
    exit 1
fi
mkdir -p "$dest"
dest="$(realpath "$dest")"

# All git invocations run inside the jail described in git-jail.sh, with the
# destination writable and the network shared.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/git-jail.sh
source "$here/git-jail.sh"
git_in_jail() { git_jail "$dest" fetch git "$@"; }

git_in_jail init -q
git_in_jail remote add origin -- "$url"
# Fetching a bare object id is allowed by GitHub, GitLab and Gitea; hosts that refuse fall
# back to the full ref set, from which the id is then looked up locally.
if ! git_in_jail fetch -q --depth 1 --no-tags origin "$commit"; then
    echo "Fetch by object id refused; fetching all refs" >&2
    git_in_jail fetch -q --no-tags origin
fi
git_in_jail checkout -q --detach "$commit"

actual="$(git_in_jail rev-parse HEAD)"
if [ "$actual" != "$commit" ]; then
    echo "Error: checked out $actual, expected $commit" >&2
    exit 1
fi

# Tree policy (see header). Submodule entries (gitlinks) are content that is not in the
# repository, so neither the tree digest nor a reviewer of the commit can account for
# it. `find` does not follow symlinks, so a symlink *named* .lake is caught by -name,
# and nothing inside the tree is ever resolved.
if git_in_jail ls-tree -r "$commit" | awk '$2 == "commit" { found = 1 } END { exit !found }'; then
    echo "Error: the repository contains submodule entries; only plain trees are accepted" >&2
    exit 1
fi
if [ -e "$dest/.lake" ] || [ -L "$dest/.lake" ]; then
    echo "Error: the repository contains a top-level .lake entry" >&2
    exit 1
fi
offending="$(find "$dest" -path "$dest/.git" -prune -o \
    \( -name .lake -o -name '*.olean' -o -name '*.ilean' -o -name '*.trace' -o -name '*.hash' \) -print \
    | awk 'NR <= 5')"
if [ -n "$offending" ]; then
    echo "Error: the repository contains Lake build outputs; only sources are accepted:" >&2
    echo "$offending" >&2
    exit 1
fi
if [ "$require_toml" = 1 ]; then
    if [ -e "$dest/lakefile.lean" ] || [ -L "$dest/lakefile.lean" ]; then
        echo "Error: lakefile.lean is not accepted here; the package must be configured by lakefile.toml" >&2
        exit 1
    fi
    if [ ! -f "$dest/lakefile.toml" ] || [ -L "$dest/lakefile.toml" ]; then
        echo "Error: lakefile.toml is missing or not a regular file" >&2
        exit 1
    fi
fi
mkdir "$dest/.lake"

echo "Checked out $url @ $commit into $dest"
