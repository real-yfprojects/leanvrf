#!/usr/bin/env bash
# Build the Lean-extended VSA predicate and validate it against the schema.
#
# Usage: build-predicate.sh <output_predicate.json>
#
# Required environment:
#   THEOREM           Fully-qualified Lean identifier that was verified
#   CHALLENGE_SHA     SHA-256 of Challenge.lean (hex)
#   SOLUTION_SHA      SHA-256 of Solution.lean (hex)
#   SOLUTION_URL      Where Solution.lean was fetched from
#   VERIFIER_ID       Canonical URI of the workflow that ran the verification
#   TOOLCHAIN_LOCK    Path to toolchain.lock from the trusted checkout; its
#                     sha256 becomes lean.toolchain_digest and its entries
#                     populate lean.lean_version and lean.engines
#   SCHEMA_FILE       Path to the leanvrf predicate JSON schema
set -euo pipefail

out="${1:-}"
if [ -z "$out" ]; then
    echo "Usage: $(basename "$0") <output_predicate.json>" >&2
    exit 1
fi

for var in THEOREM CHALLENGE_SHA SOLUTION_SHA SOLUTION_URL VERIFIER_ID TOOLCHAIN_LOCK SCHEMA_FILE; do
    if [ -z "${!var:-}" ]; then
        echo "Error: required environment variable $var is not set" >&2
        exit 1
    fi
done
if [ ! -f "$TOOLCHAIN_LOCK" ]; then
    echo "Error: TOOLCHAIN_LOCK '$TOOLCHAIN_LOCK' does not exist" >&2
    exit 1
fi

mkdir -p "$(dirname "$out")"

# The lockfile is the single description of what ran; hashing it lets a verifier
# reproduce exactly which Lean release and which verifier binaries were used.
toolchain_digest="sha256:$(sha256sum "$TOOLCHAIN_LOCK" | awk '{print $1}')"

# TODO understand policy_uri
# TODO schema: verifier.version dependencyLevels + missing SLSA Provenance v1.0 Primitives
jq -n \
  --arg verifier_id "$VERIFIER_ID" \
  --arg time_verified "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --arg resource_uri "$SOLUTION_URL" \
  --arg policy_uri "urn:lean:policy:${THEOREM}" \
  --arg challenge_sha "$CHALLENGE_SHA" \
  --arg solution_sha "$SOLUTION_SHA" \
  --arg theorem "$THEOREM" \
  --arg toolchain_digest "$toolchain_digest" \
  --slurpfile lock "$TOOLCHAIN_LOCK" \
  '{
    verifier: { id: $verifier_id },
    timeVerified: $time_verified,
    resourceUri: $resource_uri,
    policy: {
      uri: $policy_uri,
      digest: { sha256: $challenge_sha }
    },
    verificationResult: "PASSED",
    verifiedLevels: ["SLSA_BUILD_LEVEL_3"],
    slsaVersion: "v1.0",
    lean: {
      theorem: $theorem,
      challenge_sha256: $challenge_sha,
      solution_sha256: $solution_sha,
      lean_version: ("leanprover/lean4:" + $lock[0].lean.version),
      toolchain_digest: $toolchain_digest,
      allowed_axioms: ["propext", "Quot.sound", "Classical.choice"],
      engines: [
        $lock[0].tools[]
        | select(.engine == true)
        | { name: .repo, commit: .commit, status: "PASSED" }
      ]
    }
  }' > "$out"

# Strict schema validation
check-jsonschema --schemafile "$SCHEMA_FILE" "$out"
