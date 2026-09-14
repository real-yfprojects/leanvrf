#!/usr/bin/env bash
# Build the leanvfy verification predicate and validate it against the schema.
#
# Usage: build-predicate.sh <output_predicate.json>
#
# Required environment:
#   THEOREM           Fully-qualified Lean declaration that was verified
#   CHALLENGE_URL     Where Challenge.lean was fetched from
#   CHALLENGE_SHA     SHA-256 of Challenge.lean (hex)
#   SOLUTION_URL      Where Solution.lean was fetched from
#   SOLUTION_SHA      SHA-256 of Solution.lean (hex)
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

for var in THEOREM CHALLENGE_URL CHALLENGE_SHA SOLUTION_URL SOLUTION_SHA ALLOWED_AXIOMS TOOLCHAIN_LOCK SCHEMA_FILE; do
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
jq -n \
  --arg theorem "$THEOREM" \
  --arg challenge_url "$CHALLENGE_URL" \
  --arg challenge_sha "$CHALLENGE_SHA" \
  --arg solution_url "$SOLUTION_URL" \
  --arg solution_sha "$SOLUTION_SHA" \
  --arg allowed_axioms "$ALLOWED_AXIOMS" \
  --arg lock_sha "$lock_sha" \
  --slurpfile lock "$TOOLCHAIN_LOCK" \
  '{
    verificationResult: "PASSED",
    theorem: $theorem,
    challenge: { name: "Challenge.lean", uri: $challenge_url, digest: { sha256: $challenge_sha } },
    solution:  { name: "Solution.lean",  uri: $solution_url,  digest: { sha256: $solution_sha } },
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
            annotations: { repository: .repo, commit: .commit, engine: .engine }
          }
      ]
    }
  }' > "$out"

# Strict schema validation; a malformed predicate must never reach the signer.
check-jsonschema --schemafile "$SCHEMA_FILE" "$out"
