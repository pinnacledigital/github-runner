#!/usr/bin/env bash
# test/token-rotation.sh

set -euo pipefail

PASS=0
FAIL=0

# Mock environment
TOKEN_CACHE_DIR="/tmp/runner-test-54321"
mkdir -p "$TOKEN_CACHE_DIR"
TOKEN_CACHE_FILE="$TOKEN_CACHE_DIR/token.cache"
export TOKEN_CACHE_DIR
export TOKEN_CACHE_FILE

# Mock date function
date() {
  echo "1700000000"
}
export -f date

# Source the script
# shellcheck source=/dev/null
source "/Users/hillct/git/github-runner/token-entrypoint.sh"

check_cache_load() {
  local desc="$1"
  local token="$2"
  local timestamp="$3"
  local expected_status="$4"

  echo "CACHED_TOKEN=$token" > "$TOKEN_CACHE_FILE"
  echo "CACHED_AT=$timestamp" >> "$TOKEN_CACHE_FILE"

  if load_cached_token >/dev/null 2>&1; then
    actual_status=0
  else
    actual_status=1
  fi

  if [ "$actual_status" -eq "$expected_status" ]; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"
    echo "        expected_status=$expected_status  got=$actual_status"
    FAIL=$((FAIL + 1))
  fi
}

echo "── Cache Loading ────────────────────────────────────────────────────────"

check_cache_load "Valid cached token (fresh) → success" "test-token" "1700000000" 0
check_cache_load "Expired cached token (older than 55m) → failure" "test-token" "1699990000" 1

rm -rf "$TOKEN_CACHE_DIR"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
