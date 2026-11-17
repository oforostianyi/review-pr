#!/usr/bin/env bash

set -euo pipefail

test_dir=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
source "$test_dir/lib/assert.sh"

test_root=$(portable_mktemp_dir review-pr-mock-runner)
trap 'rm -rf -- "$test_root"' EXIT

run_mock() {
    local behavior=$1
    local phase=${2:-'primary review'}
    local output="$test_root/${behavior}.md"
    local error="$test_root/${behavior}.log"
    local tokens="$test_root/${behavior}.tokens"
    local usage="$test_root/${behavior}.json"
    local output_contract=markdown

    if [[ "$behavior" == valid-ndjson && "$phase" == 'primary review' ]]; then
        output_contract=ndjson-v1
    fi

    if REVIEW_PR_MOCK_BEHAVIOR="$behavior" \
        REVIEW_PR_AGENT=fixture \
        REVIEW_PR_PHASE="$phase" \
        REVIEW_PR_OUTPUT_CONTRACT="$output_contract" \
        REVIEW_PR_MODEL=fixture-model \
        REVIEW_PR_EFFORT=low \
        REVIEW_PR_ATTEMPT=1 \
        REVIEW_PR_USAGE_FILE="$tokens" \
        REVIEW_PR_USAGE_JSON="$usage" \
        "$test_dir/mock-agent-runner.sh" \
        >"$output" 2>"$error" <<<'fixture prompt'; then
        MOCK_STATUS=0
    else
        MOCK_STATUS=$?
    fi
    MOCK_OUTPUT=$output
    MOCK_ERROR=$error
    MOCK_USAGE=$usage
}

run_mock valid
assert_eq '0' "$MOCK_STATUS" 'valid mock behavior exits successfully'
assert_file_contains "$MOCK_OUTPUT" 'No actionable findings.' 'valid mock behavior returns Markdown'
assert_eq 'mock_runner' "$(jq -r '.source' "$MOCK_USAGE")" 'mock usage is machine-readable'

run_mock valid-ndjson
assert_eq '0' "$MOCK_STATUS" 'structured mock behavior exits successfully'
assert_eq 'finding' "$(sed -n '1p' "$MOCK_OUTPUT" | jq -r '.record')" 'structured mock emits one finding record per line'
assert_eq 'complete' "$(sed -n '2p' "$MOCK_OUTPUT" | jq -r '.record')" 'structured mock terminates with a completion record'

run_mock empty
assert_eq '0' "$MOCK_STATUS" 'empty mock behavior can model a successful empty CLI response'
assert_false 'empty mock behavior writes no report body' test -s "$MOCK_OUTPUT"

run_mock invalid cross-review
assert_eq '0' "$MOCK_STATUS" 'invalid mock behavior isolates schema errors from process errors'
assert_file_contains "$MOCK_OUTPUT" 'does not follow the requested schema' 'invalid mock behavior emits malformed content'

run_mock truncated
assert_eq '0' "$MOCK_STATUS" 'truncated mock behavior leaves status interpretation to the orchestrator'
assert_eq 'length' "$(jq -r '.stop_reason' "$MOCK_USAGE")" 'truncated mock behavior exposes the length stop reason'

run_mock nonzero
assert_eq '23' "$MOCK_STATUS" 'nonzero mock behavior returns a stable failing exit code'
assert_file_contains "$MOCK_ERROR" 'mock runner failed' 'nonzero mock behavior emits diagnostics'

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
