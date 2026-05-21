#!/usr/bin/env bash
# test/runner-check.sh
#
# Shell unit tests for the runner-check action's core jq matching logic.
# No Docker, no GitHub API — runs anywhere with bash and jq.
#
# Usage:
#   bash test/runner-check.sh
#
# Exit code 0 = all tests passed.

set -euo pipefail

PASS=0
FAIL=0

# ── Helpers ───────────────────────────────────────────────────────────────────

check_match() {
  local desc="$1"
  local runners_json="$2"
  local required="$3"
  local expected="$4"   # "true" or "false"

  local actual
  actual=$(printf '%s' "$runners_json" | jq --argjson required "$required" '
    [.runners[] |
      select(
        .status == "online" and
        .busy   == false    and
        (($required - (.labels | map(.name))) | length == 0)
      )
    ] | length > 0
  ')

  if [ "$actual" = "$expected" ]; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"
    echo "        expected=$expected  got=$actual"
    FAIL=$((FAIL + 1))
  fi
}

check_labels_passthrough() {
  local desc="$1"
  local labels="$2"
  local fallback="$3"
  local expected="$4"   # expected value of runner output

  local runner
  if [ "$labels" = "$fallback" ]; then
    runner="$labels"
  else
    runner="$fallback"   # simplified: no API call in this helper
  fi

  if [ "$runner" = "$expected" ]; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"
    echo "        expected=$expected  got=$runner"
    FAIL=$((FAIL + 1))
  fi
}

# ── Fixtures ──────────────────────────────────────────────────────────────────

ONLINE_IDLE=$(cat <<'EOF'
{
  "total_count": 1,
  "runners": [
    {
      "id": 1,
      "name": "my-runner",
      "status": "online",
      "busy": false,
      "labels": [
        {"id": 1, "name": "self-hosted"},
        {"id": 2, "name": "linux"},
        {"id": 3, "name": "amd64"},
        {"id": 4, "name": "android"}
      ]
    }
  ]
}
EOF
)

ONLINE_BUSY=$(cat <<'EOF'
{
  "total_count": 1,
  "runners": [
    {
      "id": 1,
      "name": "my-runner",
      "status": "online",
      "busy": true,
      "labels": [
        {"id": 1, "name": "self-hosted"},
        {"id": 2, "name": "linux"},
        {"id": 3, "name": "amd64"},
        {"id": 4, "name": "android"}
      ]
    }
  ]
}
EOF
)

OFFLINE=$(cat <<'EOF'
{
  "total_count": 1,
  "runners": [
    {
      "id": 1,
      "name": "my-runner",
      "status": "offline",
      "busy": false,
      "labels": [
        {"id": 1, "name": "self-hosted"},
        {"id": 2, "name": "linux"},
        {"id": 3, "name": "amd64"}
      ]
    }
  ]
}
EOF
)

EMPTY=$(cat <<'EOF'
{ "total_count": 0, "runners": [] }
EOF
)

MULTI=$(cat <<'EOF'
{
  "total_count": 3,
  "runners": [
    {
      "id": 1, "name": "busy-runner", "status": "online", "busy": true,
      "labels": [{"id":1,"name":"self-hosted"},{"id":2,"name":"linux"},{"id":3,"name":"amd64"}]
    },
    {
      "id": 2, "name": "offline-runner", "status": "offline", "busy": false,
      "labels": [{"id":1,"name":"self-hosted"},{"id":2,"name":"linux"},{"id":3,"name":"amd64"}]
    },
    {
      "id": 3, "name": "idle-runner", "status": "online", "busy": false,
      "labels": [{"id":1,"name":"self-hosted"},{"id":2,"name":"linux"},{"id":3,"name":"amd64"},{"id":4,"name":"android"}]
    }
  ]
}
EOF
)

PARTIAL_LABELS=$(cat <<'EOF'
{
  "total_count": 1,
  "runners": [
    {
      "id": 1, "name": "my-runner", "status": "online", "busy": false,
      "labels": [
        {"id":1,"name":"self-hosted"},
        {"id":2,"name":"linux"}
      ]
    }
  ]
}
EOF
)

# ── Tests: jq matching logic ───────────────────────────────────────────────────

echo "── Matching logic ───────────────────────────────────────────────────────"

check_match \
  "online idle runner with all requested labels → match" \
  "$ONLINE_IDLE" \
  '["self-hosted","linux","amd64","android"]' \
  "true"

check_match \
  "online busy runner → no match" \
  "$ONLINE_BUSY" \
  '["self-hosted","linux","amd64","android"]' \
  "false"

check_match \
  "offline idle runner → no match" \
  "$OFFLINE" \
  '["self-hosted","linux","amd64"]' \
  "false"

check_match \
  "empty runner list → no match" \
  "$EMPTY" \
  '["self-hosted"]' \
  "false"

check_match \
  "runner missing one requested label → no match" \
  "$PARTIAL_LABELS" \
  '["self-hosted","linux","amd64"]' \
  "false"

check_match \
  "runner has superset of requested labels → match" \
  "$ONLINE_IDLE" \
  '["self-hosted","linux"]' \
  "true"

check_match \
  "single label subset match" \
  "$ONLINE_IDLE" \
  '["android"]' \
  "true"

check_match \
  "multiple runners — only third is online+idle+matching → match" \
  "$MULTI" \
  '["self-hosted","linux","amd64","android"]' \
  "true"

check_match \
  "multiple runners — request label none have → no match" \
  "$MULTI" \
  '["self-hosted","macos"]' \
  "false"

# ── Tests: fast-path (labels == fallback) ─────────────────────────────────────

echo "── Fast-path (labels == fallback) ───────────────────────────────────────"

check_labels_passthrough \
  "labels identical to fallback → output labels unchanged" \
  '["ubuntu-latest"]' \
  '["ubuntu-latest"]' \
  '["ubuntu-latest"]'

check_labels_passthrough \
  "labels differ from fallback → would query API (fallback returned by helper)" \
  '["self-hosted","amd64"]' \
  '["ubuntu-latest"]' \
  '["ubuntu-latest"]'

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
