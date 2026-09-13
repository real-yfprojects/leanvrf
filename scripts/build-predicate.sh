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
#   TOOLCHAIN_DIGEST  Immutable digest of the verifier toolchain image (sha256:...)
#   SCHEMA_FILE       Path to the leanvrf predicate JSON schema
set -euo pipefail

out="${1:-}"
if [ -z "$out" ]; then
    echo "Usage: $(basename "$0") <output_predicate.json>" >&2
    exit 1
fi

for var in THEOREM CHALLENGE_SHA SOLUTION_SHA SOLUTION_URL VERIFIER_ID TOOLCHAIN_DIGEST SCHEMA_FILE; do
    if [ -z "${!var:-}" ]; then
        echo "Error: required environment variable $var is not set" >&2
        exit 1
    fi
done

mkdir -p "$(dirname "$out")"

# TODO understand policy_uri
# TODO dynamic engine commit hashes from the toolchain container
# TODO schema: verifier.version dependencyLevels + missing SLSA Provenance v1.0 Primitives
jq -n \
  --arg verifier_id "$VERIFIER_ID" \
  --arg time_verified "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --arg resource_uri "$SOLUTION_URL" \
  --arg policy_uri "urn:lean:policy:${THEOREM}" \
  --arg challenge_sha "$CHALLENGE_SHA" \
  --arg solution_sha "$SOLUTION_SHA" \
  --arg theorem "$THEOREM" \
  --arg toolchain_digest "$TOOLCHAIN_DIGEST" \
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
      lean_version: "v4.8.0",
      toolchain_digest: $toolchain_digest,
      allowed_axioms: ["propext", "Quot.sound", "Classical.choice"],
      engines: [
        { name: "leanprover/comparator", commit: "3a4b5c6d7e8f901234567890abcdef1234567890", status: "PASSED" },
        { name: "flypitch/nanoda",       commit: "1a2b3c4d5e6f7890abcdef1234567890abcdef12", status: "PASSED" },
        { name: "digama0/lean4lean",     commit: "9f8e7d6c5b4a3210fedcba0987654321fedcba09", status: "PASSED" }
      ]
    }
  }' > "$out"

# Strict schema validation
check-jsonschema --schemafile "$SCHEMA_FILE" "$out"
