#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154 # Tests assign the sourced orchestrator's globals and index its associative arrays.

set -euo pipefail

test_dir=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo_root=$(cd -P -- "$test_dir/../.." && pwd -P)
source "$test_dir/lib/assert.sh"

export REVIEW_PR_LIBRARY_MODE=true
# shellcheck source=/dev/null
source "$repo_root/bin/review-pr" --
unset REVIEW_PR_LIBRARY_MODE

suite_root=$(portable_mktemp_dir review-pr-phases)
trap 'rm -rf -- "$suite_root"' EXIT

prepare_phase_case() {
    local case_name=$1
    shift
    local -a agents=("$@")
    local agent

    CASE_DIR="$suite_root/$case_name"
    WORK_DIR="$CASE_DIR/work"
    REVIEW_REPO="$CASE_DIR/repository"
    REPORT_STEM=$case_name
    mkdir -p -- "$WORK_DIR" "$REVIEW_REPO"

    PR_NUMBER=123
    PR_TITLE='Fixture PR'
    PR_TASK_DISPLAY='FIX-123 — Fixture PR'
    PR_AUTHOR_DISPLAY='Fixture Author (@fixture)'
    PR_CHANGED_FILES=1
    PR_ADDITIONS=1
    PR_DELETIONS=0
    BASE_REF=main
    HEAD_REF=fixture
    BASE_SHA=1111111111111111111111111111111111111111
    HEAD_SHA=2222222222222222222222222222222222222222
    FINAL_HEADER_TITLE='# Code Review: [PR #123](https://example.test/pull/123) — Fixture PR'
    FINAL_HEADER_TABLE_HEADER='| Field | Value |'
    FINAL_HEADER_TABLE_SEPARATOR='|---|---|'
    FINAL_HEADER_TASK='| **Task** | FIX-123 — Fixture PR |'
    FINAL_HEADER_BASE='| **Base** | `main` → `fixture` |'
    FINAL_HEADER_FILES='| **Files changed** | 1 · +1 / −0 |'
    FINAL_HEADER_AUTHOR='| **Author** | Fixture Author (@fixture) |'

    REVIEW_AGENTS=("${agents[@]}")
    FINAL_SYNTHESIZER=${agents[0]}
    FINAL_COMPARISON_MODE=none
    HEARTBEAT_LOG_ENABLED=false
    DASHBOARD_ACTIVE=true
    TEMP_FILES=()
    RUNNING_PIDS=()
    PROMPT_FILES=()
    TEMP_OUTPUTS=()
    TEMP_LOGS=()
    TEMP_USAGE_FILES=()
    TEMP_USAGE_JSON_FILES=()
    FINAL_OUTPUTS=()
    USAGE_OUTPUTS=()
    ERROR_LOGS=()
    AGENT_RUNNERS=()
    AGENT_MODELS=()
    AGENT_EFFORTS=()
    AGENT_TIMEOUT_SECONDS=()
    AGENT_LABELS=()

    for agent in "${agents[@]}"; do
        AGENT_RUNNERS[$agent]="$test_dir/mock-agent-runner.sh"
        AGENT_MODELS[$agent]="mock-${agent}"
        AGENT_EFFORTS[$agent]=low
        AGENT_TIMEOUT_SECONDS[$agent]=0
        AGENT_LABELS[$agent]="${agent^}"
        PROMPT_FILES[$agent]="$CASE_DIR/${agent}.prompt"
        TEMP_OUTPUTS[$agent]="$CASE_DIR/${agent}.tmp.md"
        TEMP_LOGS[$agent]="$CASE_DIR/${agent}.tmp.log"
        TEMP_USAGE_FILES[$agent]="$CASE_DIR/${agent}.tmp.tokens"
        TEMP_USAGE_JSON_FILES[$agent]="$CASE_DIR/${agent}.tmp.usage.json"
        FINAL_OUTPUTS[$agent]="$CASE_DIR/${agent}.md"
        USAGE_OUTPUTS[$agent]="$CASE_DIR/${agent}-usage.json"
        ERROR_LOGS[$agent]="$CASE_DIR/${agent}-error.log"
        printf 'mock prompt\n' >"${PROMPT_FILES[$agent]}"
    done

    initialize_dashboard full
    EVENT_LOG="$CASE_DIR/events.log"
    SCENARIO_DIR="$CASE_DIR/scenarios"
    mkdir -p -- "$SCENARIO_DIR"
    : >"$EVENT_LOG"
    export REVIEW_PR_MOCK_EVENT_LOG=$EVENT_LOG
    export REVIEW_PR_MOCK_SCENARIO_DIR=$SCENARIO_DIR
}

prepare_phase_case sequential alpha beta
MAX_CONCURRENCY=1
RETRY_MAX_ATTEMPTS=1
RETRY_DELAY_SECONDS=0
export REVIEW_PR_MOCK_DELAY_SECONDS=1
run_review_phase 'primary review' alpha beta
assert_eq $'start\talpha\nend\talpha\nstart\tbeta\nend\tbeta' \
    "$(awk -F '\t' '{print $1 "\t" $2}' "$EVENT_LOG")" \
    'max_concurrency=1 executes agents sequentially'
assert_file_exists "${FINAL_OUTPUTS[alpha]}" 'sequential alpha report is committed atomically'
assert_file_exists "${FINAL_OUTPUTS[beta]}" 'sequential beta report is committed atomically'

prepare_phase_case parallel alpha beta
MAX_CONCURRENCY=2
RETRY_MAX_ATTEMPTS=1
export REVIEW_PR_MOCK_DELAY_SECONDS=1
run_review_phase 'primary review' alpha beta
assert_eq $'start\nstart' "$(awk -F '\t' 'NR <= 2 {print $1}' "$EVENT_LOG")" \
    'max_concurrency=2 starts both agents before either completes'

prepare_phase_case retry alpha beta
printf 'fail-once\n' >"$SCENARIO_DIR/beta-primary-review"
MAX_CONCURRENCY=2
RETRY_MAX_ATTEMPTS=2
RETRY_DELAY_SECONDS=0
export REVIEW_PR_MOCK_DELAY_SECONDS=0
run_review_phase 'primary review' alpha beta
assert_eq '1' "$(awk -F '\t' '$1 == "start" && $2 == "alpha" {count++} END {print count + 0}' "$EVENT_LOG")" \
    'successful agent waits and is not rerun'
assert_eq '2' "$(awk -F '\t' '$1 == "start" && $2 == "beta" {count++} END {print count + 0}' "$EVENT_LOG")" \
    'only the failed agent is retried'
assert_eq '2' "${PHASE_ATTEMPTS[beta]}" 'retry attempt count is recorded'
assert_file_exists "${FINAL_OUTPUTS[beta]}" 'retried agent eventually commits its report'
assert_file_exists "$CASE_DIR/beta-error-attempt-1-usage.json" \
    'failed retry usage is preserved for diagnosis'

prepare_phase_case truncated alpha
printf 'truncated\n' >"$SCENARIO_DIR/alpha-primary-review"
MAX_CONCURRENCY=1
RETRY_MAX_ATTEMPTS=1
export REVIEW_PR_MOCK_DELAY_SECONDS=0
if run_review_phase 'primary review' alpha; then
    fail 'truncated output must fail the phase'
fi
pass 'truncated output fails the phase'
assert_file_not_exists "${FINAL_OUTPUTS[alpha]}" 'truncated output never becomes a canonical report'
assert_file_exists "$CASE_DIR/alpha-error-truncated.md" 'truncated model output is preserved'
assert_file_exists "$CASE_DIR/alpha-error-usage.json" 'truncation usage diagnostics are preserved'

prepare_phase_case nonzero alpha
printf 'nonzero\n' >"$SCENARIO_DIR/alpha-primary-review"
MAX_CONCURRENCY=1
RETRY_MAX_ATTEMPTS=1
if run_review_phase 'primary review' alpha; then
    fail 'non-zero runner exit must fail the phase'
fi
pass 'non-zero runner exit fails the phase'
assert_file_not_exists "${FINAL_OUTPUTS[alpha]}" 'failed runner cannot publish a partial report'
assert_file_exists "$CASE_DIR/alpha-error-partial.md" 'non-zero runner partial output is preserved'
assert_file_exists "$CASE_DIR/alpha-error.log" 'non-zero runner stderr is preserved'

prepare_phase_case timeout alpha beta
printf 'hang\n' >"$SCENARIO_DIR/alpha-primary-review"
MAX_CONCURRENCY=2
RETRY_MAX_ATTEMPTS=1
AGENT_TIMEOUT_SECONDS[alpha]=1
if run_review_phase 'primary review' alpha beta; then
    fail 'timed-out runner must fail the phase'
fi
pass 'timed-out runner fails without blocking its peer'
assert_file_not_exists "${FINAL_OUTPUTS[alpha]}" 'timed-out output is never published'
assert_file_exists "${FINAL_OUTPUTS[beta]}" 'successful peer remains published when another agent times out'
assert_file_contains "$CASE_DIR/alpha-error.log" 'exceeded its configured timeout of 1s' 'timeout reason is preserved in agent diagnostics'
assert_eq 'failed' "${PHASE_AGENT_STATUSES[alpha]}" 'timed-out agent is recorded as failed'
assert_eq 'complete' "${PHASE_AGENT_STATUSES[beta]}" 'successful peer remains complete'

prepare_phase_case preserved alpha beta
PRIMARY_OUTPUTS[alpha]="$WORK_DIR/preserved-alpha.md"
PRIMARY_OUTPUTS[beta]="$WORK_DIR/preserved-beta.md"
CROSS_OUTPUTS[alpha]="$WORK_DIR/preserved-cross-alpha.md"
CROSS_OUTPUTS[beta]="$WORK_DIR/preserved-cross-beta.md"
printf 'preserved primary report\n' >"${PRIMARY_OUTPUTS[alpha]}"
printf '{"reported_total_tokens": 512}\n' >"$WORK_DIR/${REPORT_STEM}-alpha-usage.json"
printf 'preserved cross report\n' >"${CROSS_OUTPUTS[beta]}"
: >"${CROSS_OUTPUTS[alpha]}"
load_preserved_dashboard_statuses
assert_eq 'LOADED' "${DASHBOARD_STATUSES[$(dashboard_key primary alpha)]}" \
    'a preserved primary report is shown as loaded instead of waiting'
assert_eq '512' "${DASHBOARD_TOKENS[$(dashboard_key primary alpha)]}" \
    'a preserved report shows its recorded token total'
assert_eq 'WAITING' "${DASHBOARD_STATUSES[$(dashboard_key primary beta)]}" \
    'a missing primary report still waits'
assert_eq 'LOADED' "${DASHBOARD_STATUSES[$(dashboard_key cross beta)]}" \
    'a preserved cross-review is shown as loaded'
assert_eq 'WAITING' "${DASHBOARD_STATUSES[$(dashboard_key cross alpha)]}" \
    'an empty cross-review artifact is not treated as preserved'

DASHBOARD_SHOW_PID=true
DASHBOARD_COLOR_ENABLED=false
calculate_dashboard_line_count
render_dashboard_snapshot false 2>"$CASE_DIR/frame.txt"
assert_eq "$DASHBOARD_LINE_COUNT" "$(wc -l <"$CASE_DIR/frame.txt")" \
    'the rendered frame height matches the cursor movement used for redraws'
assert_eq '1' "$(grep -c 'PRIMARY REVIEW' "$CASE_DIR/frame.txt")" \
    'one frame draws the primary section title exactly once'

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
