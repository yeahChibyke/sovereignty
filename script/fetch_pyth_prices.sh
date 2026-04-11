#!/usr/bin/env bash
# Fetches hex-encoded price update data from Pyth Hermes for the given feed IDs.
# Usage: fetch_pyth_prices.sh <feed_id_1> <feed_id_2> ...
# Returns: hex-encoded binary update data (0x-prefixed), one per line.

set -euo pipefail

BASE_URL="https://hermes.pyth.network/v2/updates/price/latest"

# Build query string from arguments
QUERY=""
for feed_id in "$@"; do
    if [ -z "$QUERY" ]; then
        QUERY="ids[]=${feed_id}"
    else
        QUERY="${QUERY}&ids[]=${feed_id}"
    fi
done

RESPONSE=$(curl -s -X GET "${BASE_URL}?${QUERY}&encoding=hex&parsed=false")

# Extract hex data array entries, prefix with 0x
echo "$RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data['binary']['data']:
    print('0x' + item)
"
