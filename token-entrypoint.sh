#!/bin/bash
set -euo pipefail

# --- Configuration ---
TOKEN_CACHE_DIR="${TOKEN_CACHE_DIR:-/var/run/github-runner}"
TOKEN_CACHE_FILE="${TOKEN_CACHE_DIR}/token.cache"
TOKEN_MAX_AGE_SECONDS=3300  # 55 min — 5 min buffer before GitHub's 1-hour expiry

mkdir -p "$TOKEN_CACHE_DIR"

# --- GitHub App JWT Generation ---
generate_jwt() {
  local app_id=$1
  local private_key=$2
  
  local header
  header=$(echo -n '{"alg":"RS256","typ":"JWT"}' | openssl base64 | tr -d "\n" | tr -d '=' | tr '/+' '_-')
  local payload
  payload=$(echo -n "{\"iat\":$(($(date +%s) - 60)),\"exp\":$(($(date +%s) + 600)),\"iss\":\"${app_id}\"}" | openssl base64 | tr -d "\n" | tr -d '=' | tr '/+' '_-')
  local signature
  signature=$(echo -n "${header}.${payload}" | openssl dgst -sha256 -sign <(echo "$private_key") | openssl base64 | tr -d "\n" | tr -d '=' | tr '/+' '_-')
  
  echo "${header}.${payload}.${signature}"
}

# --- Token Management ---

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

fetch_token_via_app() {
  echo "[runner] Fetching token via GitHub App (ID: ${APP_ID})"
  local jwt
  jwt=$(generate_jwt "${APP_ID}" "${APP_PRIVATE_KEY}")
  
  # 1. Get Installation ID (if not provided)
  if [ -z "${APP_INSTALLATION_ID:-}" ]; then
    if [ "${RUNNER_SCOPE:-}" = "org" ]; then
      APP_INSTALLATION_ID=$(curl -sf -H "Authorization: Bearer ${jwt}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/orgs/${ORG_NAME}/installations" | jq -r '.[0].id')
    else
      local repo_path="${REPO_URL#https://github.com/}"
      APP_INSTALLATION_ID=$(curl -sf -H "Authorization: Bearer ${jwt}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${repo_path}/installations" | jq -r '.id')
    fi
  fi

  # 2. Get Installation Access Token
  local install_token
  install_token=$(curl -sf -X POST \
    -H "Authorization: Bearer ${jwt}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/${APP_INSTALLATION_ID}/access_tokens" | jq -r .token)

  # 3. Get Registration Token
  fetch_registration_token "$install_token"
}

fetch_token_via_pat() {
  echo "[runner] Fetching token via PAT"
  fetch_registration_token "$GITHUB_PAT"
}

fetch_registration_token() {
  local auth_token=$1
  local api_url
  
  if [ "${RUNNER_SCOPE:-}" = "org" ]; then
    api_url="https://api.github.com/orgs/${ORG_NAME}/actions/runners/registration-token"
  elif [ -n "${REPO_URL:-}" ]; then
    local repo_path="${REPO_URL#https://github.com/}"
    api_url="https://api.github.com/repos/${repo_path}/actions/runners/registration-token"
  else
    echo "ERROR: set RUNNER_SCOPE=org with ORG_NAME, or set REPO_URL" >&2
    return 1
  fi

  local token
  token=$(curl -sf -X POST \
    -H "Authorization: Bearer ${auth_token}" \
    -H "Accept: application/vnd.github+json" \
    "${api_url}" | jq -r .token)

  if [ -z "$token" ] || [ "$token" = "null" ]; then
    echo "ERROR: GitHub API returned no token" >&2
    return 1
  fi

  printf 'CACHED_TOKEN=%s\nCACHED_AT=%s\n' "$token" "$(date +%s)" > "$TOKEN_CACHE_FILE"
  RUNNER_TOKEN="$token"
  export RUNNER_TOKEN
}

# --- Execution ---

main() {
  # 1. JIT Configuration (highest priority, bypasses myoung34 registration)
  if [ -n "${JIT_CONFIG:-}" ]; then
    echo "[runner] Mode: JIT Configuration — bypassing standard registration"
    export DEBUG_ONLY=true
    # Cleanup sensitive variables before starting the runner
    unset GITHUB_PAT
    unset APP_PRIVATE_KEY
    # Execute via entrypoint but override the command to run jit config
    exec /entrypoint.sh bash -c "./config.sh --jitconfig ${JIT_CONFIG} && ./run.sh"
  fi

  # 2. Static Token
  if [ -n "${RUNNER_TOKEN:-}" ] && [ "${RUNNER_TOKEN:-}" != "null" ]; then
    echo "[runner] Mode: Static RUNNER_TOKEN provided"
  # 3. GitHub App
  elif [ -n "${APP_ID:-}" ] && [ -n "${APP_PRIVATE_KEY:-}" ]; then
    fetch_token_via_app || { load_cached_token || exit 1; }
  # 4. PAT Rotation
  elif [ -n "${GITHUB_PAT:-}" ]; then
    fetch_token_via_pat || { load_cached_token || exit 1; }
  # 5. Cache Fallback
  elif load_cached_token; then
    echo "[runner] Mode: Cached token fallback"
  else
    echo "ERROR: No token source available (JIT_CONFIG, RUNNER_TOKEN, APP_ID/KEY, or GITHUB_PAT)" >&2
    exit 1
  fi

  # Cleanup sensitive variables before starting the runner
  unset GITHUB_PAT
  unset APP_PRIVATE_KEY
  unset JIT_CONFIG

  echo "[runner] Starting runner agent..."
  exec /entrypoint.sh "$@"
}

# If we are not being sourced, run main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
