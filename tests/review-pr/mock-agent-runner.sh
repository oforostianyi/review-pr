#!/usr/bin/env bash

set -euo pipefail

behavior=${REVIEW_PR_MOCK_BEHAVIOR:-valid}
scenario_directory=${REVIEW_PR_MOCK_SCENARIO_DIR:-}
phase=${REVIEW_PR_PHASE:-unknown}
agent=${REVIEW_PR_AGENT:-unknown}
attempt=${REVIEW_PR_ATTEMPT:-1}
phase_key=${phase// /-}
phase_key=${phase_key//\//-}

if [[ -n "${REVIEW_PR_MOCK_CAPTURE_DIR:-}" ]]; then
    mkdir -p -- "$REVIEW_PR_MOCK_CAPTURE_DIR"
    cat >"${REVIEW_PR_MOCK_CAPTURE_DIR}/${phase_key}-${agent}-attempt-${attempt}.prompt"
fi

if [[ -n "$scenario_directory" && -f "${scenario_directory}/${agent}-${phase_key}" ]]; then
    IFS= read -r behavior <"${scenario_directory}/${agent}-${phase_key}"
fi

if [[ -n "${REVIEW_PR_MOCK_EVENT_LOG:-}" ]]; then
    printf 'start\t%s\t%s\t%s\t%s\n' "$agent" "$phase_key" "$attempt" "$(date +%s)" >>"$REVIEW_PR_MOCK_EVENT_LOG"
fi

write_usage() {
    local stop_reason=${1:-null}
    local output_tokens=${2:-41}
    local total_tokens=$((output_tokens + 100))
    local stop_json=null

    if [[ "$stop_reason" != null ]]; then
        stop_json=$(printf '%s' "$stop_reason" | jq -R .)
    fi
    if [[ -n "${REVIEW_PR_USAGE_FILE:-}" ]]; then
        printf '%s\n' "$total_tokens" >"$REVIEW_PR_USAGE_FILE"
    fi
    if [[ -n "${REVIEW_PR_USAGE_JSON:-}" ]]; then
        jq -n \
            --arg agent "$agent" \
            --arg phase "$phase" \
            --arg model "${REVIEW_PR_MODEL:-mock-model}" \
            --arg effort "${REVIEW_PR_EFFORT:-}" \
            --argjson total "$total_tokens" \
            --argjson output "$output_tokens" \
            --argjson stop "$stop_json" \
            '{
                schema_version: 1,
                agent: $agent,
                phase: $phase,
                model: $model,
                effort: (if $effort == "" then null else $effort end),
                reasoning_effort: (if $effort == "" then null else $effort end),
                available: true,
                source: "mock_runner",
                reported_total_tokens: $total,
                input_tokens: 100,
                output_tokens: $output,
                reasoning_tokens: 10,
                cache_read_tokens: 0,
                cache_write_tokens: 0,
                stop_reason: $stop,
                raw_stop_reason: $stop,
                output_limit_reached: ($stop == "length")
            }' >"$REVIEW_PR_USAGE_JSON"
    fi
}

emit_valid_output() {
    case "$phase" in
        'primary review')
            printf '## Findings\n\nNo actionable findings.\n'
            ;;
        cross-review)
            printf '## Classification table\n\n'
            printf '| # | Source | Claim | Classification | Severity | Verification |\n'
            printf '|---|---|---|---|---|---|\n'
            printf '| 1 | Mock source | No defect | REJECTED | — | Fixture evidence |\n'
            ;;
        'final synthesis')
            printf '## Classification table\n\n'
            printf '| # | Source | Claim | Classification | Severity | Verification |\n'
            printf '|---|---|---|---|---|---|\n'
            printf '| 1 | Mock cross-review | No defect | REJECTED | — | Fixture evidence |\n'
            printf '\n## Rejected findings\n\nNo important rejected findings.\n'
            ;;
        'comparison synthesis')
            cat <<'EOF'
<!-- review-pr:comparison:conclusion -->
## Conclusion

The mock reports agree.

<!-- review-pr:comparison:sources -->
## Sources

| Short name | File | Verdict |
|---|---|---|
| Alpha | alpha.md | No findings |

<!-- review-pr:comparison:attribution -->
## Who found, accepted, or missed what

| Risk / candidate | Alpha | Beta | Summary |
|---|---|---|---|
| No defect | found | accepted | Rejected |

<!-- review-pr:comparison:review -->
## Review comparison

<!-- review-pr:comparison:agreements -->
### Agreements

No actionable findings.

<!-- review-pr:comparison:disagreements -->
### Disagreements

None.

<!-- review-pr:comparison:depth -->
## Review-depth comparison

| Report | Strongest aspect | What it missed or overstated |
|---|---|---|
| Alpha | Deterministic | Nothing |

<!-- review-pr:comparison:actions -->
## Agreed actions

None.
EOF
            ;;
        *)
            printf 'valid mock output for %s\n' "$phase"
            ;;
    esac
}

emit_valid_ndjson_primary() {
    jq -nc --arg agent "$agent" '{
        record: "finding",
        schema_version: 1,
        source_id: ($agent + ":F-001"),
        title: "Fixture changed-line defect",
        claim: "The fixture changed branch can fail.",
        anchor: {kind: "changed-line", file: "fixture odd [name].txt", start: 1, end: 1},
        evidence: ["The exact changed branch is present in the supplied diff."],
        failure_scenario: "The fixture request reaches the changed branch and fails.",
        recommendation: "Correct the changed branch.",
        classification: null,
        severity: "P1",
        category: "correctness",
        contributing_agents: [$agent],
        verification_limitations: [],
        existing_feedback: {state: "new", thread_ids: []}
    }'
    jq -nc '{
        record: "complete",
        schema_version: 1,
        finding_count: 1,
        summary: "One actionable fixture finding.",
        verification_limitations: [],
        positive_evidence: ["The fixture remains intentionally small."]
    }'
}

emit_valid_ndjson_cross() {
    local source_agent=alpha
    if [[ "$agent" == alpha ]]; then
        source_agent=beta
    fi
    jq -nc --arg agent "$agent" --arg source_agent "$source_agent" '{
        record: "finding",
        schema_version: 1,
        source_id: ($agent + ":C-001"),
        source_refs: [{agent: $source_agent, source_id: ($source_agent + ":F-001")}],
        title: "Fixture changed-line defect",
        claim: "The fixture changed branch can fail.",
        anchor: {kind: "changed-line", file: "fixture odd [name].txt", start: 1, end: 1},
        evidence: ["The exact changed branch confirms the supplied finding."],
        failure_scenario: "The fixture request reaches the changed branch and fails.",
        recommendation: "Correct the changed branch.",
        classification: "CONFIRMED",
        severity: "P1",
        category: "correctness",
        contributing_agents: [$source_agent],
        verification_limitations: [],
        existing_feedback: {state: "new", thread_ids: []}
    }'
    jq -nc '{
        record: "complete",
        schema_version: 1,
        finding_count: 1,
        summary: "The supplied fixture finding is confirmed.",
        verification_limitations: [],
        positive_evidence: []
    }'
}

emit_anchor_output() {
    local anchor_line=$1
    local problem_text=${2:-The fixture finding remains byte-for-byte stable.}

    cat <<EOF
## Classification table

| # | Source | Claim | Classification | Severity | Verification |
|---|---|---|---|---|---|
| 1 | Alpha | Fixture changed-line defect | CONFIRMED | P1 | Fixture evidence. |

<!-- review-pr:anchor:changed-line -->
### [P1] Fixture changed-line defect

File: \`fixture odd [name].txt\`
Line: \`${anchor_line}\`

Problem:
${problem_text}

Failure scenario:
The fixture request fails.

Evidence:
The exact changed branch is present in the supplied evidence.

Recommendation:
Correct the changed branch.
EOF
}

case "$behavior" in
    valid)
        sleep "${REVIEW_PR_MOCK_DELAY_SECONDS:-0}"
        emit_valid_output
        write_usage null 41
        ;;
    valid-ndjson)
        sleep "${REVIEW_PR_MOCK_DELAY_SECONDS:-0}"
        if [[ "$phase" == 'primary review' || "$phase" == 'primary findings repair' ]]; then
            if [[ "${REVIEW_PR_OUTPUT_CONTRACT:-}" != ndjson-v1 ]]; then
                printf 'structured primary mock received the wrong output contract: %s\n' "${REVIEW_PR_OUTPUT_CONTRACT:-unset}" >&2
                exit 65
            fi
            emit_valid_ndjson_primary
        elif [[ "$phase" == 'cross-review' ]]; then
            if [[ "${REVIEW_PR_OUTPUT_CONTRACT:-}" == ndjson-v1 ]]; then
                emit_valid_ndjson_cross
            else
                emit_valid_output
            fi
        else
            emit_valid_output
        fi
        write_usage null 55
        ;;
    ndjson-preamble)
        printf '%s\n' 'Here is the requested structured review:'
        emit_valid_ndjson_primary
        write_usage null 58
        ;;
    unsafe-ndjson-repair)
        emit_valid_ndjson_primary | sed '0,/The fixture changed branch can fail\./s//The repair rewrote the finding claim./'
        write_usage null 59
        ;;
    fail-once)
        if (( attempt == 1 )); then
            printf 'mock attempt one failure\n' >&2
            write_usage null 7
            exit 17
        fi
        emit_valid_output
        write_usage null 41
        ;;
    empty)
        write_usage null 0
        ;;
    truncated)
        printf 'partial output without a completed contract\n'
        write_usage length 256
        ;;
    invalid)
        printf 'This response does not follow the requested schema.\n'
        write_usage null 12
        ;;
    malformed-comparison)
        cat <<'EOF'
<!-- review-pr:comparison:conclusion -->

## Agreement

The draft contains useful comparison content but omits the remaining required markers.

## Material disagreements

| Finding | Alpha | Beta | Resolution |
|---|---|---|---|
| Example severity | P1 | P2 | Evidence supports P1. |
EOF
        write_usage null 80
        ;;
    repair-anchor | unsafe-anchor-repair)
        repair_state="${scenario_directory}/.${agent}-${phase_key}-anchor-repair"
        if [[ ! -e "$repair_state" ]]; then
            : >"$repair_state"
            emit_anchor_output 99
        elif [[ "$behavior" == unsafe-anchor-repair ]]; then
            emit_anchor_output 1 'The repair improperly rewrote substantive content.'
        else
            emit_anchor_output 1
        fi
        write_usage null 67
        ;;
    nonzero)
        printf 'partial response before the runner failed\n'
        printf 'mock runner failed\n' >&2
        write_usage null 12
        exit 23
        ;;
    hang)
        trap 'exit 143' TERM INT
        printf 'partial response while waiting for termination\n'
        write_usage null 5
        sleep 30
        ;;
    *)
        printf 'Unknown mock behavior: %s\n' "$behavior" >&2
        exit 64
        ;;
esac

if [[ -n "${REVIEW_PR_MOCK_EVENT_LOG:-}" ]]; then
    printf 'end\t%s\t%s\t%s\t%s\n' "$agent" "$phase_key" "$attempt" "$(date +%s)" >>"$REVIEW_PR_MOCK_EVENT_LOG"
fi
