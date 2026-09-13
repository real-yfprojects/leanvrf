#!/usr/bin/env bash
# Download one untrusted input file (Challenge.lean / Solution.lean) over HTTPS.
#
# Usage: fetch-untrusted.sh <https_url> <destination_path>
#
# The URL is chosen by the prover and is only a locator: nothing about it is
# trusted or checked, and whatever bytes arrive are what the pipeline hashes,
# verifies and attests. This script therefore has one narrow job -- make sure
# curl can do nothing *other* than write the response body to <destination_path>:
#   - https only, also across redirects (no file://, ftp://, http:// downgrade)
#   - TLS 1.2+
#   - no URL globbing, so '{}' and '[]' cannot fan out into several requests
#     or be misparsed
#   - no ~/.curlrc, so the fetch is fully described by this command line
#   - '--' so a URL starting with '-' cannot be read as an option
#   - fail on HTTP errors and leave no partial file behind
#   - the result must be a regular file, not a symlink or FIFO
# There is deliberately no size or time limit: the prover pays for the runner
# (see README, adversarial model), and a truncated file can never yield an
# attestation for the file the verifier expects.
set -euo pipefail

url="${1:-}"
dest="${2:-}"
if [ -z "$url" ] || [ -z "$dest" ]; then
    echo "Usage: $(basename "$0") <https_url> <destination_path>" >&2
    exit 1
fi

# curl enforces the same via --proto; this just gives a clearer error.
case "$url" in
    https://*) ;;
    *)
        echo "Error: only https:// URLs are accepted" >&2
        exit 1
        ;;
esac

mkdir -p "$(dirname "$dest")"
rm -f "$dest"

# --disable must be the first argument to take effect.
if ! curl \
    --disable \
    --globoff \
    --proto '=https' \
    --proto-redir '=https' \
    --tlsv1.2 \
    --fail \
    --silent \
    --show-error \
    --location \
    --output "$dest" \
    -- "$url"; then
    # %q keeps a URL containing newlines or control characters on one log line.
    printf 'Error: failed to fetch %q\n' "$url" >&2
    rm -f "$dest"
    exit 1
fi

if [ ! -f "$dest" ] || [ -L "$dest" ]; then
    echo "Error: '$dest' is not a regular file after download" >&2
    rm -f "$dest"
    exit 1
fi
