#!/bin/bash
set -euo pipefail

TOKEN_CACHE_FILE="${TOKEN_CACHE_DIR:-/var/run/github-runner}/token.cache"
TOKEN_MAX_AGE_SECONDS=3300  # 55 min — 5 min buffer before GitHub's 1-hour expiry

mkdir -p "$(dirname "$TOKEN_CACHE_FILE")"

load_cached_token() {
  [ -f "$TOKEN_CACHE_FILE" ] || return 1
  local cached_token cached_at now age
  # shellcheck source=/dev/null
  source "$TOKEN_CACHE_FILE"
  cached_token="${CACHED_TOKEN:-}"
  cached_at="${CACHED_AT:-0}"
  now=$(date +%s)
  age=$(( now - cached_at ))
  if [ -n "$cached_token" ] && [ "$age" -lt "$TOKEN_MAX_AGE_SECONDS" ]; then
    echo "[runner] Loaded cached token (age: ${age}s, valid for another $(( TOKEN_MAX_AGE_SECONDS - age ))s)"
    RUNNER_TOKEN="$cached_token"
    export RUNNER_TOKEN
    return 0
  fi
  echo "[runner] Cached token expired or missing (age: ${age}s)"
  return 1
}

fetch_token_via_pat() {
  if [ "${RUNNER_SCOPE:-}" = "org" ]; then
    API_URL="https://api.github.com/orgs/${ORG_NAME}/actions/runners/registration-token"
  elif [ -n "${REPO_URL:-}" ]; then
    REPO_PATH="${REPO_URL#https://github.com/}"
    API_URL="https://api.github.com/repos/${REPO_PATH}/actions/runners/registration-token"
  else
    echo "ERROR: set RUNNER_SCOPE=org with ORG_NAME, or set REPO_URL" >&2
    return 1
  fi

  local token
  token=$(curl -sf -X POST \
    -H "Authorization: Bearer ${GITHUB_PAT}" \
    -H "Accept: application/vnd.github+json" \
    "${API_URL}" | jq -r .token)

  if [ -z "$token" ] || [ "$token" = "null" ]; then
    echo "ERROR: GitHub API returned no token — check GITHUB_PAT has admin:org scope" >&2
    return 1
  fi

  printf 'CACHED_TOKEN=%s\nCACHED_AT=%s\n' "$token" "$(date +%s)" > "$TOKEN_CACHE_FILE"
  RUNNER_TOKEN="$token"
  export RUNNER_TOKEN
}

# --- Resolution order ---

if [ -n "${GITHUB_PAT:-}" ]; then
  echo "[runner] Mode: PAT rotation — fetching fresh registration token"
  if fetch_token_via_pat; then
    echo "[runner] Registration token acquired and cached"
  else
    echo "[runner] PAT fetch failed — attempting cached token fallback"
    if ! load_cached_token; then
      echo "ERROR: PAT fetch failed and no valid cached token available" >&2
      exit 1
    fi
  fi
elif load_cached_token; then
  echo "[runner] Mode: cached token from previous PAT rotation"
elif [ -n "${RUNNER_TOKEN:-}" ]; then
  echo "[runner] Mode: static RUNNER_TOKEN (expires 1 hour after generation)"
else
  echo "ERROR: no token source available — set GITHUB_PAT, provide a cached token, or set RUNNER_TOKEN" >&2
  exit 1
fi

exec /entrypoint.sh "$@"
