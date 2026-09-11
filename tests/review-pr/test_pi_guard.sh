#!/usr/bin/env bash

set -euo pipefail

test_dir=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo_root=$(cd -P -- "$test_dir/../.." && pwd -P)
source "$test_dir/lib/assert.sh"

export REVIEW_PR_LIBRARY_MODE=true
# shellcheck source=/dev/null
source "$repo_root/bin/review-pr" --
unset REVIEW_PR_LIBRARY_MODE

test_root=$(portable_mktemp_dir review-pr-pi-guard)
trap 'rm -rf -- "$test_root"' EXIT

extension=$(pi_guard_extension_path)
assert_eq "$repo_root/runners/review-pr-pi-guard.js" "$extension" \
    'the Pi guard extension is resolved next to the runners in a repository checkout'
assert_file_exists "$extension" 'the Pi guard extension ships with the repository'

guard_log="$test_root/guard-log.ndjson"
printf '%s\n' \
    '{"event":"allowed","tool":"bash","calls":1}' \
    '{"event":"duplicate_blocked","tool":"bash","calls":1,"blocked":1}' \
    '{"event":"allowed","tool":"read","calls":2}' \
    '{"event":"budget_blocked","tool":"bash","calls":2,"blocked":2}' \
    >"$guard_log"
assert_eq 'Pi tool guard: 2 tool calls executed, 1 duplicate call blocked, budget exhausted after 2 calls (1 blocked), not terminated.' \
    "$(summarize_pi_guard_log "$guard_log" 2)" \
    'guard log summarizes executed, duplicate, and budget-blocked calls'
assert_eq 'Pi tool guard: no tool calls were attempted.' \
    "$(summarize_pi_guard_log "$test_root/missing-log.ndjson" 2)" \
    'a missing guard log yields an explicit no-call summary'

control_prompt="$test_root/control-prompt.md"
control_file="$test_root/control.txt"
printf '%s\n' 'Phase: independent primary review' 'Reviewer: Pi (pi)' '===== BEGIN CONFIGURED REVIEW SKILL (REFERENCE) =====' 'skill body' >"$control_prompt"
write_pi_control_prompt "$control_prompt" "$control_file"
assert_file_contains "$control_file" 'Phase: independent primary review' \
    'the Pi control prompt keeps the orchestration header'
assert_file_contains "$control_file" 'inspect the callers and flows that the changed code affects' \
    'the Pi guard instruction asks for consumer and flow inspection, matching the review skill'
assert_false 'the Pi guard instruction no longer confines inspection to changed code' \
    grep -Fq -- 'bounded to changed code' "$control_file"
assert_file_contains "$control_file" 'Never repeat an identical tool call' \
    'the Pi guard instruction still forbids repeated inspection'

if ! command -v node >/dev/null 2>&1; then
    printf 'node is unavailable; skipping extension behaviour tests\n'
    printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
    exit 0
fi

run_guard() {
    local max=$1 log=$2 script=$3
    REVIEW_PR_PI_MAX_TOOL_CALLS=$max REVIEW_PR_PI_GUARD_LOG=$log \
        node "$test_dir/lib/pi-guard-harness.mjs" "$extension" "$script"
}

dedupe_log="$test_root/dedupe.ndjson"
dedupe_result=$(run_guard 100 "$dedupe_log" '[
    {"tool":"bash","input":{"command":"sed -n 1,20p a.php"}},
    {"tool":"bash","input":{"command":"sed -n 1,20p a.php"}},
    {"tool":"read","input":{"path":"a.php"}},
    {"tool":"read","input":{"path":"a.php"}},
    {"tool":"bash","input":{"command":"sed -n 21,40p a.php"}}
]')
assert_eq 'tool_call' "$(jq -r '.registered | join(",")' <<<"$dedupe_result")" \
    'the extension registers a tool_call handler'
assert_eq 'null' "$(jq -c '.results[0]' <<<"$dedupe_result")" \
    'a first-time tool call is allowed'
assert_eq 'true' "$(jq -r '.results[1].block' <<<"$dedupe_result")" \
    'an identical repeated tool call is blocked'
assert_true 'the duplicate block explains that the result already exists' \
    grep -q 'already executed' <<<"$(jq -r '.results[1].reason' <<<"$dedupe_result")"
assert_eq 'false' "$(jq -r '.results[1].terminate // false' <<<"$dedupe_result")" \
    'a duplicate block does not terminate the agent'
assert_eq 'true' "$(jq -r '.results[3].block' <<<"$dedupe_result")" \
    'repeated read calls are blocked by path'
assert_eq 'null' "$(jq -c '.results[4]' <<<"$dedupe_result")" \
    'a different command on the same file is still allowed'
assert_eq '2' "$(jq -s '[.[] | select(.event == "duplicate_blocked")] | length' "$dedupe_log")" \
    'the guard log records every blocked duplicate'

budget_log="$test_root/budget.ndjson"
budget_script=$(jq -nc '[range(0; 16) | {tool: "bash", input: {command: ("echo " + (. | tostring))}}]')
budget_result=$(run_guard 3 "$budget_log" "$budget_script")
assert_eq 'null,null,null' "$(jq -r '[.results[0:3][] | tostring] | join(",")' <<<"$budget_result")" \
    'distinct calls within the budget are allowed'
assert_eq 'true' "$(jq -r '.results[3].block' <<<"$budget_result")" \
    'the first call beyond the budget is blocked'
assert_true 'the budget block asks for the final output' \
    grep -qi 'budget' <<<"$(jq -r '.results[3].reason' <<<"$budget_result")"
assert_eq 'false' "$(jq -r '.results[3].terminate // false' <<<"$budget_result")" \
    'the first blocked call beyond the budget does not terminate the agent'
assert_eq 'true' "$(jq -r '.results[13].terminate // false' <<<"$budget_result")" \
    'persistent tool use after the budget is exhausted terminates the agent'
assert_eq '3' "$(jq -s '[.[] | select(.event == "allowed")] | length' "$budget_log")" \
    'the guard log counts executed calls'
assert_eq '1' "$(jq -s '[.[] | select(.event == "terminated")] | length' "$budget_log")" \
    'the guard log records the termination once'

unlimited_log="$test_root/unlimited.ndjson"
unlimited_result=$(run_guard 0 "$unlimited_log" "$budget_script")
assert_eq '16' "$(jq '[.results[] | select(. == null)] | length' <<<"$unlimited_result")" \
    'a zero budget disables the budget but keeps the guard loaded'

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
