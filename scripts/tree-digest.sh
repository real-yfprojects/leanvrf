#!/usr/bin/env bash
# Content digest of a git commit's tree, used as the attestation subject for the
# challenge and solution repositories.
#
# Usage: tree-digest.sh <checkout_dir> <commit>
#
# Prints one lowercase hex sha256. Algorithm, so that a verifier can recompute it
# on an independent clone (this script is the reference implementation):
#
#   1. list the tree recursively:  git ls-tree -r <commit>
#      giving lines "<mode> blob <blob-oid>\t<path>" in git's canonical order
#      (bytewise by path). Only blobs occur: submodule entries (gitlinks, mode
#      160000) are rejected, since their content is not in the repository.
#   2. replace each <blob-oid> by the sha256 of that blob's content
#      (git cat-file blob <oid> | sha256sum), and drop the word "blob";
#   3. the digest is the sha256 of the resulting lines
#      "<mode> <sha256-of-content> <path>\n", concatenated in that order.
#
# Why not the commit id: git ids are SHA-1 (in almost every repository), and
# actions/attest indexes subjects by sha256. Why not `git archive`: its tar
# output is not specified to be byte-stable across git versions. This digest
# binds exactly what a source review looks at -- every path, its mode (regular,
# executable or symlink) and its bytes -- and nothing else.
#
# The listing is produced inside the read-only, network-less jail of git-jail.sh:
# reading packs and resolving deltas are git code paths of their own, and the
# object store is prover-controlled bytes, so git gets the same wall here as it
# did when fetching. Only the listing text leaves the jail; the final sha256
# over it is taken on the host.
set -euo pipefail

dir="${1:-}"
commit="${2:-}"
if [ -z "$dir" ] || [ ! -d "$dir" ] || ! [[ "$commit" =~ ^([a-f0-9]{40}|[a-f0-9]{64})$ ]]; then
    echo "Usage: $(basename "$0") <checkout_dir> <commit>" >&2
    exit 1
fi
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/git-jail.sh
source "$here/git-jail.sh"

# Runs inside the jail (bash, git and sha256sum from /usr/bin). Paths are taken
# from -z output so names with unusual characters are not quoted or escaped by
# git; the listing is re-emitted with plain newlines, which git tree entries
# cannot contain.
list_tree='
set -euo pipefail
tab=$(printf "\t")
git ls-tree -r -z "$1" | while IFS= read -r -d "" entry; do
    meta="${entry%%"$tab"*}"
    path="${entry#*"$tab"}"
    read -r mode type oid <<<"$meta"
    if [ "$type" != "blob" ]; then
        echo "Error: unsupported tree entry ($type) at $path; submodules are not accepted" >&2
        exit 1
    fi
    content_sha="$(git cat-file blob "$oid" | sha256sum | cut -d" " -f1)"
    printf "%s %s %s\n" "$mode" "$content_sha" "$path"
done
'
listing="$(git_jail "$(realpath "$dir")" read bash -c "$list_tree" bash "$commit")"
printf '%s\n' "$listing" | sha256sum | awk '{print $1}'
