#!/usr/bin/env bash
# Build the leanvfy verification predicate and validate it against the schema.
#
# Usage: build-predicate.sh <output_predicate.json>
#
# Required environment:
#   THEOREM           Fully-qualified Lean declaration that was verified
#   CHALLENGE_REPO    Where the challenge repository was fetched from (locator only)
#   CHALLENGE_COMMIT  Commit id of the challenge that was checked out
#   CHALLENGE_MODULE  Module of the challenge package the theorem was exported from
#   CHALLENGE_DIGEST  Tree digest (scripts/tree-digest.sh) of that checkout, hex sha256
#   SOLUTION_REPO     Where the solution repository was fetched from (locator only)
#   SOLUTION_COMMIT   Commit id of the solution that was checked out
#   SOLUTION_MODULE   Module of the solution package the theorem was exported from
#   SOLUTION_DIGEST   Tree digest of that checkout, hex sha256
#   ALLOWED_AXIOMS    Comma-separated axiom whitelist the kernels were run with
#   TOOLCHAIN_LOCK    Path to toolchain.lock from the trusted checkout; its
#                     entries populate the `toolchain` block verbatim
#   SCHEMA_FILE       Path to schemas/leanvfy-v1.json (in-toto-v1.json must sit
#                     next to it; the schema references it by relative path)
#
# Deliberately NOT inputs: workflow identity, runner environment, repository,
# run id, timestamps. The Sigstore certificate minted by actions/attest carries
# those from GitHub's OIDC token; copying them from the runner context would
# only add an attacker-influenced duplicate. See README "Attestation contents".
set -euo pipefail

out="${1:-}"
if [ -z "$out" ]; then
    echo "Usage: $(basename "$0") <output_predicate.json>" >&2
    exit 1
fi

for var in THEOREM CHALLENGE_REPO CHALLENGE_COMMIT CHALLENGE_MODULE CHALLENGE_DIGEST \
           SOLUTION_REPO SOLUTION_COMMIT SOLUTION_MODULE SOLUTION_DIGEST \
           ALLOWED_AXIOMS TOOLCHAIN_LOCK SCHEMA_FILE; do
    if [ -z "${!var:-}" ]; then
        echo "Error: required environment variable $var is not set" >&2
        exit 1
    fi
done
for f in "$TOOLCHAIN_LOCK" "$SCHEMA_FILE"; do
    if [ ! -f "$f" ]; then
        echo "Error: '$f' does not exist" >&2
        exit 1
    fi
done

mkdir -p "$(dirname "$out")"

# The lockfile is the single description of what ran; its digest lets a
# verifier confirm the expanded toolchain block below with one comparison
# against the workflow repository at the attested commit.
lock_sha="$(sha256sum "$TOOLCHAIN_LOCK" | awk '{print $1}')"

# Artifact references use in-toto ResourceDescriptors: name + uri + digest,
# with leanvfy-specific facts under `annotations` (in-toto's extension point).
# For the two repositories `gitCommit` is the identity a verifier compares
# against the challenge they audited, and `sha256` the tree digest that
# doubles as attestation subject. A tool built from a patched checkout lists the
# patch files (paths in this repository at the attested workflow commit).
jq -n \
  --arg theorem "$THEOREM" \
  --arg challenge_repo "$CHALLENGE_REPO" \
  --arg challenge_commit "$CHALLENGE_COMMIT" \
  --arg challenge_module "$CHALLENGE_MODULE" \
  --arg challenge_digest "$CHALLENGE_DIGEST" \
  --arg solution_repo "$SOLUTION_REPO" \
  --arg solution_commit "$SOLUTION_COMMIT" \
  --arg solution_module "$SOLUTION_MODULE" \
  --arg solution_digest "$SOLUTION_DIGEST" \
  --arg allowed_axioms "$ALLOWED_AXIOMS" \
  --arg lock_sha "$lock_sha" \
  --slurpfile lock "$TOOLCHAIN_LOCK" \
  '{
    verificationResult: "PASSED",
    theorem: $theorem,
    challenge: {
      name: ("challenge@" + $challenge_commit),
      uri: $challenge_repo,
      digest: { gitCommit: $challenge_commit, sha256: $challenge_digest },
      annotations: { module: $challenge_module }
    },
    solution: {
      name: ("solution@" + $solution_commit),
      uri: $solution_repo,
      digest: { gitCommit: $solution_commit, sha256: $solution_digest },
      annotations: { module: $solution_module }
    },
    policy: {
      allowedAxioms: ($allowed_axioms | split(",") | map(select(length > 0)))
    },
    toolchain: {
      lock: { name: "toolchain.lock", digest: { sha256: $lock_sha } },
      lean: {
        name: "lean4",
        uri: $lock[0].lean.url,
        digest: { sha256: $lock[0].lean.sha256 },
        annotations: { version: $lock[0].lean.version }
      },
      tools: [
        $lock[0].tools[]
        | {
            name: .name,
            uri: .url,
            digest: { sha256: .sha256 },
            annotations: ({ repository: .repo, commit: .commit, engine: .engine }
              + (if (.patches // []) | length > 0 then { patches: .patches } else {} end))
          }
      ]
    }
  }' > "$out"

# Strict schema validation; a malformed predicate must never reach the signer.
check-jsonschema --schemafile "$SCHEMA_FILE" "$out"
