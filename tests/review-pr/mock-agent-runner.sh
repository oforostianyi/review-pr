#!/usr/bin/env bash

set -euo pipefail

behavior=${REVIEW_PR_MOCK_BEHAVIOR:-valid}
scenario_directory=${REVIEW_PR_MOCK_SCENARIO_DIR:-}
phase=${REVIEW_PR_PHASE:-unknown}
agent=${REVIEW_PR_AGENT:-unknown}
attempt=${REVIEW_PR_ATTEMPT:-1}
phase_key=${phase// /-}
phase_key=${phase_key//\//-}

# The orchestrator supplies the prompt on stdin. Keep it: structured mocks
# derive their required source refs and dispute list from its control blocks.
prompt_text=$(cat)
if [[ -n "${REVIEW_PR_MOCK_CAPTURE_DIR:-}" ]]; then
    mkdir -p -- "$REVIEW_PR_MOCK_CAPTURE_DIR"
    printf '%s\n' "$prompt_text" >"${REVIEW_PR_MOCK_CAPTURE_DIR}/${phase_key}-${agent}-attempt-${attempt}.prompt"
fi

# Prints the JSON lines of one "===== BEGIN <name> =====" ... "===== END <name> =====" prompt block.
prompt_block_lines() {
    local name=$1
    awk -v begin="===== BEGIN ${name} =====" -v end="===== END ${name} =====" '
        $0 == begin {inside = 1; next}
        $0 == end {inside = 0}
        inside && /^\{/ {print}
    ' <<<"$prompt_text"
}

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
    # One record per required source ref. With "reject-first" the first listed
    # ref is REJECTED and the rest CONFIRMED, which creates exactly one dispute
    # when another cross-reviewer confirms that same primary finding.
    local mode=${1:-confirm}
    local refs_json source_agent
    refs_json=$(prompt_block_lines 'REQUIRED SOURCE REFS' | jq -s '.')
    if [[ "$(jq 'length' <<<"$refs_json")" == 0 ]]; then
        source_agent=alpha
        [[ "$agent" != alpha ]] || source_agent=beta
        refs_json=$(jq -nc --arg a "$source_agent" '[{agent: $a, source_id: ($a + ":F-001")}]')
    fi
    jq -c --arg agent "$agent" --arg mode "$mode" '
        to_entries[] |
        (.key == 0 and $mode == "reject-first") as $rejected |
        {
        record: "finding",
        schema_version: 1,
        source_id: ($agent + ":C-" + (("00" + ((.key + 1) | tostring))[-3:])),
        source_refs: [.value],
        title: "Fixture changed-line defect",
        claim: "The fixture changed branch can fail.",
        anchor: {kind: "changed-line", file: "fixture odd [name].txt", start: 1, end: 1},
        evidence: ["The exact changed branch confirms the supplied finding."],
        failure_scenario: (if $rejected then null else "The fixture request reaches the changed branch and fails." end),
        recommendation: "Correct the changed branch.",
        classification: (if $rejected then "REJECTED" else "CONFIRMED" end),
        severity: (if $rejected then null else "P1" end),
        category: "correctness",
        contributing_agents: [.value.agent],
        verification_limitations: [],
        existing_feedback: {state: "new", thread_ids: []}
    }' <<<"$refs_json"
    jq -c '{
        record: "complete",
        schema_version: 1,
        finding_count: length,
        summary: "The supplied fixture findings were classified.",
        verification_limitations: [],
        positive_evidence: []
    }' <<<"$refs_json"
}

emit_resolution_records() {
    local status=${1:-resolved} method=${2:-source}
    prompt_block_lines 'REQUIRED RESOLUTIONS' | jq -c --arg status "$status" --arg method "$method" '{
        record: "resolution", schema_version: 1, dispute_id, primary_ref,
        conflicting_refs: [.conflicting_refs[] | {agent, source_id}],
        final_source_id: "FINAL-001", dispute_kind: "factual", resolution_status: $status,
        verification_method: $method, command: null,
        observed: (if $status == "resolved" then "The changed branch was read directly; the disputed premise holds." else "" end),
        basis: "general_engineering", basis_source: null, limitations: []}'
}

emit_valid_ndjson_final() {
    local resolution_status=${1:-resolved} resolution_method=${2:-source}
    local refs_json
    refs_json=$(prompt_block_lines 'REQUIRED SOURCE REFS' | jq -s '.')
    if [[ "$(jq 'length' <<<"$refs_json")" == 0 ]]; then
        refs_json='[{"agent":"alpha","source_id":"alpha:C-001"},{"agent":"beta","source_id":"beta:C-001"}]'
    fi
    jq -c '{
        record: "finding",
        schema_version: 1,
        source_id: "FINAL-001",
        source_refs: .,
        title: "Fixture changed-line defect",
        claim: "The fixture changed branch can fail.",
        anchor: {kind: "changed-line", file: "fixture odd [name].txt", start: 1, end: 1},
        evidence: ["Both canonical cross-reviews confirm the exact changed branch."],
        failure_scenario: "The fixture request reaches the changed branch and fails.",
        recommendation: "Correct the changed branch.",
        classification: "CONFIRMED",
        severity: "P1",
        category: "correctness",
        contributing_agents: ([.[].agent] | unique),
        verification_limitations: [],
        existing_feedback: {state: "new", thread_ids: []},
        include_in_rejected_summary: false
    }' <<<"$refs_json"
    emit_resolution_records "$resolution_status" "$resolution_method"
    jq -nc '{
        record: "complete",
        schema_version: 1,
        finding_count: 1,
        summary: "The canonical cross-review finding is confirmed.",
        verification_limitations: [],
        positive_evidence: []
    }'
}

emit_contract_ndjson() {
    case "$phase" in
        'primary review')
            jq -nc --arg agent "$agent" '{record:"finding",schema_version:1,source_id:"FIX-PRIMARY-001",title:"Fixture contract finding",claim:"The fixture changed branch can fail.",anchor:{kind:"changed-line",file:"fixture/Changed.php",start:10,end:10},evidence:["The fixture line is explicitly changed."],failure_scenario:"A fixture request reaches the changed branch.",recommendation:"Correct the fixture branch.",classification:null,severity:"P2",category:"correctness",contributing_agents:[$agent],verification_limitations:[],existing_feedback:{state:"new",thread_ids:[]}}'
            ;;
        cross-review)
            printf '%s\n' '{"record":"finding","schema_version":1,"source_id":"FIX-CROSS-001","source_refs":[{"agent":"fixture-primary","source_id":"FIX-PRIMARY-001"}],"title":"Fixture contract finding","claim":"The fixture changed branch can fail.","anchor":{"kind":"changed-line","file":"fixture/Changed.php","start":10,"end":10},"evidence":["The fixture line confirms the supplied claim."],"failure_scenario":"A fixture request reaches the changed branch.","recommendation":"Correct the fixture branch.","classification":"CONFIRMED","severity":"P2","category":"correctness","contributing_agents":["fixture-primary"],"verification_limitations":[],"existing_feedback":{"state":"new","thread_ids":[]}}'
            ;;
        'final synthesis')
            printf '%s\n' '{"record":"finding","schema_version":1,"source_id":"FIX-FINAL-001","source_refs":[{"agent":"fixture-cross","source_id":"FIX-CROSS-001"}],"title":"Fixture contract finding","claim":"The fixture changed branch can fail.","anchor":{"kind":"changed-line","file":"fixture/Changed.php","start":10,"end":10},"evidence":["The canonical fixture cross-review confirms the claim."],"failure_scenario":"A fixture request reaches the changed branch.","recommendation":"Correct the fixture branch.","classification":"CONFIRMED","severity":"P2","category":"correctness","contributing_agents":["fixture-cross"],"verification_limitations":[],"existing_feedback":{"state":"new","thread_ids":[]},"include_in_rejected_summary":false}'
            ;;
        *) printf 'unexpected contract-test phase: %s\n' "$phase" >&2; exit 65 ;;
    esac
    printf '%s\n' '{"record":"complete","schema_version":1,"finding_count":1,"summary":"Fixture contract completed.","verification_limitations":[],"positive_evidence":[]}'
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
    contract-valid)
        [[ "${REVIEW_PR_CONTRACT_TEST:-false}" == true ]] || { printf '%s\n' 'contract-test marker missing' >&2; exit 65; }
        [[ "${REVIEW_PR_OUTPUT_CONTRACT:-}" == ndjson-v1 ]] || { printf '%s\n' 'contract-test output contract missing' >&2; exit 65; }
        [[ "${REVIEW_PR_MAX_ATTEMPTS:-}" == 1 ]] || { printf '%s\n' 'contract-test must request one attempt' >&2; exit 65; }
        emit_contract_ndjson
        write_usage null 33
        ;;
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
        elif [[ "$phase" == 'cross-review' || "$phase" == 'cross-review findings repair' ]]; then
            if [[ "${REVIEW_PR_OUTPUT_CONTRACT:-}" == ndjson-v1 ]]; then
                emit_valid_ndjson_cross
            else
                emit_valid_output
            fi
        elif [[ "$phase" == 'final synthesis' || "$phase" == 'final findings repair' ]]; then
            if [[ "${REVIEW_PR_OUTPUT_CONTRACT:-}" == ndjson-v1 ]]; then
                emit_valid_ndjson_final
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
    cross-ndjson-rejected)
        emit_valid_ndjson_cross reject-first
        write_usage null 57
        ;;
    final-resolution-uncertain)
        emit_valid_ndjson_final uncertain manual
        write_usage null 57
        ;;
    cross-ndjson-preamble)
        printf '%s\n' 'Here is the requested structured cross-review:'
        emit_valid_ndjson_cross
        write_usage null 58
        ;;
    final-ndjson-preamble)
        printf '%s\n' 'Here is the requested structured final synthesis:'
        emit_valid_ndjson_final
        write_usage null 58
        ;;
    unsafe-final-ndjson-repair)
        emit_valid_ndjson_final | sed '0,/"classification":"CONFIRMED"/s//"classification":"UNCERTAIN"/' | sed '0,/"severity":"P1"/s//"severity":null/'
        write_usage null 59
        ;;
    unsafe-cross-ndjson-repair)
        emit_valid_ndjson_cross | sed '0,/"classification":"CONFIRMED"/s//"classification":"UNCERTAIN"/'
        write_usage null 59
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
        # Sleep in the background so TERM reaches the trap immediately instead
        # of after the foreground sleep ends; otherwise the mock outlives the
        # orchestrator by up to 30s and races the suite's temp-dir cleanup.
        sleep 30 &
        hang_sleep_pid=$!
        trap 'kill "$hang_sleep_pid" 2>/dev/null; exit 143' TERM INT
        printf 'partial response while waiting for termination\n'
        write_usage null 5
        wait "$hang_sleep_pid"
        ;;
    *)
        printf 'Unknown mock behavior: %s\n' "$behavior" >&2
        exit 64
        ;;
esac

if [[ -n "${REVIEW_PR_MOCK_EVENT_LOG:-}" ]]; then
    printf 'end\t%s\t%s\t%s\t%s\n' "$agent" "$phase_key" "$attempt" "$(date +%s)" >>"$REVIEW_PR_MOCK_EVENT_LOG"
fi
