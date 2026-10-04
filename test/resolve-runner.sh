#!/usr/bin/env bash
# test/resolve-runner.sh
#
# Runs the real script shipped inside action.yml (the "Resolve runner" action), extracted unchanged, against a fake `gh`, with inputs as
# they arrive in practice: pasted into a GitHub UI form, saved from a Windows editor, pretty-printed, padded with spaces. No Docker, no
# GitHub API. (check/action.yml and .github/actions/runner-check/action.yml are symlinks to action.yml, so this covers them too.)
#
# The failure these guard against: a repository variable saved as `["self-hosted","linux","x64"]` followed by CRLF CRLF made the script
# write `runner=...` plus empty lines into $GITHUB_OUTPUT, which GitHub rejects ("Invalid format ''") after the runner was already matched.
#
# Usage:
#   bash test/resolve-runner.sh
#
# Exit code 0 = all tests passed.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# The script under test: the run block of the action's only step, dedented. Fail loudly if the layout of action.yml ever changes.
SCRIPT="$TMP/resolve.sh"
sed -n '/^      run: |$/,$p' "$ROOT/action.yml" | tail -n +2 | sed 's/^        //' >"$SCRIPT"
if [ ! -s "$SCRIPT" ] || ! bash -n "$SCRIPT"; then
  echo "could not extract a valid script from action.yml (expected a trailing '      run: |' block)" >&2
  exit 2
fi

# A fake `gh`: records every call, refuses a token that contains whitespace (a real header with a newline in it fails), and either fails
# or prints the canned runners JSON.
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_CALLS"
case "${GH_TOKEN:-}" in
  *[[:space:]]*)
    echo "gh: token contains whitespace" >&2
    exit 1
    ;;
esac
[ "${FAKE_GH_FAIL:-}" = "1" ] && exit 1
cat "$FAKE_RUNNERS"
EOF
chmod +x "$TMP/bin/gh"

IDLE='{"runners":[{"name":"r1","status":"online","busy":false,"labels":[{"name":"self-hosted"},{"name":"Linux"},{"name":"X64"}]}]}'
BUSY='{"runners":[{"name":"r1","status":"online","busy":true,"labels":[{"name":"self-hosted"},{"name":"Linux"},{"name":"X64"}]}]}'
NONE='{"runners":[]}'

CLEAN_LABELS='["self-hosted","linux","x64"]'
CLEAN_FALLBACK='["ubuntu-latest"]'
BASE=(GH_TOKEN=tok "LABELS=$CLEAN_LABELS" "FALLBACK=$CLEAN_FALLBACK" WAIT_IF_BUSY=false SCOPE=org)

CODE=0

# run RUNNERS_JSON [VAR=value ...]: runs the script with a clean environment. Later assignments override earlier ones.
run() {
  local runners="$1"
  shift
  printf '%s' "$runners" >"$TMP/runners.json"
  : >"$TMP/output"
  : >"$TMP/calls"
  CODE=0
  env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" \
    GITHUB_OUTPUT="$TMP/output" GITHUB_REPOSITORY=acme/widgets \
    FAKE_RUNNERS="$TMP/runners.json" FAKE_CALLS="$TMP/calls" \
    "$@" bash "$SCRIPT" >"$TMP/stdout" 2>"$TMP/stderr" || CODE=$?
}

# The value of a step output, as GitHub would read it (the last `key=value` line wins).
out() { grep -E "^$1=" "$TMP/output" | tail -1 | cut -d= -f2- || true; }

# GitHub rejects any line of $GITHUB_OUTPUT that is not `name=value` (an empty line is "Invalid format ''").
output_valid() { ! grep -qvE '^[A-Za-z_][A-Za-z0-9_]*=' "$TMP/output"; }

calls() { wc -l <"$TMP/calls" | tr -d ' '; }

check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"
    echo "        expected=$expected"
    echo "        got     =$actual"
    FAIL=$((FAIL + 1))
  fi
}

check_ok() {
  local desc="$1"
  shift
  if "$@"; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc"
    FAIL=$((FAIL + 1))
  fi
}

echo
echo "Baseline"
run "$IDLE" "${BASE[@]}"
check "an idle matching runner resolves to the requested labels" "$CLEAN_LABELS" "$(out runner)"
check "and reports matched" "matched" "$(out match_status)"
check_ok "and the output file is valid" output_valid

echo
echo "Whitespace in the values (the incident: a variable saved with trailing CRLF CRLF)"
run "$IDLE" "${BASE[@]}" "LABELS=${CLEAN_LABELS}"$'\r\n\r\n'
check "trailing CRLF CRLF on labels: still resolves to the clean labels" "$CLEAN_LABELS" "$(out runner)"
check "and still matches" "matched" "$(out match_status)"
check_ok "and the output file is valid" output_valid

run "$IDLE" "${BASE[@]}" "LABELS=  ${CLEAN_LABELS}"$'\t \n'
check "leading and trailing spaces, tab and newline on labels" "$CLEAN_LABELS" "$(out runner)"

run "$NONE" "${BASE[@]}" "FALLBACK=${CLEAN_FALLBACK}"$'\r\n'
check "trailing CRLF on the fallback is not copied into the output" "$CLEAN_FALLBACK" "$(out runner)"
check_ok "so the output file stays valid on the fallback path" output_valid

run "$BUSY" "${BASE[@]}" "WAIT_IF_BUSY=true"$'\r\n'
check "wait_if_busy with a trailing CRLF still means true: queue on the labels" "$CLEAN_LABELS" "$(out runner)"
check "and reports busy" "busy" "$(out match_status)"

run "$BUSY" "${BASE[@]}" "WAIT_IF_BUSY= true "
check "wait_if_busy with spaces around it still means true" "$CLEAN_LABELS" "$(out runner)"

run "$IDLE" "${BASE[@]}" "GH_TOKEN=tok"$'\n'
check "a token with a trailing newline is trimmed before it reaches gh" "matched" "$(out match_status)"

run "$IDLE" "${BASE[@]}" "SCOPE= org"$'\r\n'
check "scope with stray whitespace is understood (org-level API was queried)" "1" "$(grep -c '/orgs/acme/actions/runners' "$TMP/calls")"

printf '\xEF\xBB\xBF%s' "$CLEAN_LABELS" >"$TMP/bom"
run "$IDLE" "${BASE[@]}" "LABELS=$(cat "$TMP/bom")"
check "a UTF-8 byte order mark in front of the labels is stripped" "$CLEAN_LABELS" "$(out runner)"

echo
echo "JSON handling"
run "$IDLE" "${BASE[@]}" "LABELS=$(printf '[\n  "self-hosted",\n  "linux",\n  "x64"\n]\n')"
check "pretty-printed labels are written as one line" "$CLEAN_LABELS" "$(out runner)"
check_ok "so the output file is valid" output_valid

run "$IDLE" "${BASE[@]}" 'LABELS=[ "self-hosted" ,"linux", "x64" ]' 'FALLBACK=[ "self-hosted" ,"linux", "x64" ]'
check "labels equal to the fallback up to formatting need no API call" "0" "$(calls)"
check "and resolve to the compact form" "$CLEAN_LABELS" "$(out runner)"

run "$IDLE" "${BASE[@]}" 'LABELS=["self-hosted",'
check "invalid JSON in labels fails the step" "1" "$CODE"
check_ok "with a message that names the input" grep -q "::error::.*labels" "$TMP/stdout"
check_ok "and writes nothing corrupt" output_valid

run "$IDLE" "${BASE[@]}" 'LABELS={"a":1}'
check "labels that are not an array fail the step" "1" "$CODE"

run "$IDLE" "${BASE[@]}" 'LABELS=[1,2]'
check "labels that are not an array of strings fail the step" "1" "$CODE"

run "$IDLE" "${BASE[@]}" 'FALLBACK=not json'
check "an invalid fallback fails the step, naming the input" "1" "$CODE"
check_ok "with a message that names the input" grep -q "::error::.*fallback" "$TMP/stdout"

run "$IDLE" "${BASE[@]}" 'LABELS='
check "blank labels fail the step (the input is required)" "1" "$CODE"
check_ok "with a message that names the input" grep -q "::error::.*labels" "$TMP/stdout"

echo
echo "Defaults for blank optional inputs"
run "$NONE" "${BASE[@]}" "FALLBACK=  "
check "a blank fallback means ubuntu-latest" "$CLEAN_FALLBACK" "$(out runner)"

run "$BUSY" "${BASE[@]}" "WAIT_IF_BUSY= "
check "a blank wait_if_busy means false: fall back rather than queue" "$CLEAN_FALLBACK" "$(out runner)"

run "$IDLE" "${BASE[@]}" "SCOPE= "
check "a blank scope means auto: org level is tried first" "1" "$(grep -c '/orgs/acme/actions/runners' "$TMP/calls")"

echo
echo "Behaviour that must not change"
run "$NONE" "${BASE[@]}"
check "no matching runner: the fallback" "$CLEAN_FALLBACK" "$(out runner)"
check "and reports offline" "offline" "$(out match_status)"

run "$BUSY" "${BASE[@]}"
check "busy without wait_if_busy: the fallback" "$CLEAN_FALLBACK" "$(out runner)"
check "and reports busy" "busy" "$(out match_status)"

run "$IDLE" "${BASE[@]}" FAKE_GH_FAIL=1
check "scope org and an unavailable API: the step fails" "1" "$CODE"
check "and reports unavailable" "unavailable" "$(out match_status)"
check "with the fallback as its output" "$CLEAN_FALLBACK" "$(out runner)"

run "$IDLE" "${BASE[@]}" SCOPE=repo FAKE_GH_FAIL=1
check "scope repo and an unavailable API: falls back without failing" "0" "$CODE"
check "to the fallback" "$CLEAN_FALLBACK" "$(out runner)"

run "$IDLE" "${BASE[@]}" "LABELS=$CLEAN_FALLBACK"
check "labels identical to the fallback skip the API entirely" "0" "$(calls)"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
