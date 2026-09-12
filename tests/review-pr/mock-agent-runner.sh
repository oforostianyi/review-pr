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

# Replaces the first literal occurrence of $1 with $2 on stdin. Portable across
# GNU and BSD tools, unlike sed's GNU-only "0,/re/" address.
replace_first_literal() {
    awk -v needle="$1" -v replacement="$2" '
        !done { position = index($0, needle); if (position > 0) { $0 = substr($0, 1, position - 1) replacement substr($0, position + length(needle)); done = 1 } }
        { print }'
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
        anchor: {kind: "changed-line", file: "fixture odd [name].txt", start: 1, "end": 1},
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
    jq -nc --arg limitation "${REVIEW_PR_MOCK_PRIMARY_LIMITATION:-}" '{
        record: "complete",
        schema_version: 1,
        finding_count: 1,
        summary: "One actionable fixture finding.",
        verification_limitations: (if $limitation == "" then [] else [$limitation] end),
        positive_evidence: ["The fixture remains intentionally small."]
    }'
}

# Emits the structured or Markdown output the current phase and contract expect.
emit_valid_for_phase() {
    if [[ "$phase" == 'primary review' || "$phase" == 'primary findings repair' ]]; then
        if [[ "${REVIEW_PR_OUTPUT_CONTRACT:-}" != ndjson-v1 ]]; then
            printf 'structured primary mock received the wrong output contract: %s\n' "${REVIEW_PR_OUTPUT_CONTRACT:-unset}" >&2
            exit 65
        fi
        emit_valid_ndjson_primary
    elif [[ "$phase" == 'cross-review' || "$phase" == 'cross-review findings repair' || "$phase" == 'cross-review findings continuation' ]]; then
        if [[ "${REVIEW_PR_OUTPUT_CONTRACT:-}" == ndjson-v1 ]]; then
            emit_valid_ndjson_cross
        else
            emit_valid_output
        fi
    elif [[ "$phase" == 'final synthesis' || "$phase" == 'final findings repair' || "$phase" == 'final findings continuation' ]]; then
        if [[ "${REVIEW_PR_OUTPUT_CONTRACT:-}" == ndjson-v1 ]]; then
            emit_valid_ndjson_final
        else
            emit_valid_output
        fi
    else
        emit_valid_output
    fi
}

emit_valid_ndjson_cross() {
    # One record per required source ref. With "reject-first" the first listed
    # ref is REJECTED and the rest CONFIRMED, which creates exactly one dispute
    # when another cross-reviewer confirms that same primary finding. A
    # continuation prompt carries PENDING SOURCE REFS instead, and its records
    # are numbered after the findings the interrupted pass already produced.
    local mode=${1:-confirm}
    local refs_json source_agent pending_json kept=0
    refs_json=$(prompt_block_lines 'REQUIRED SOURCE REFS' | jq -s '.')
    pending_json=$(prompt_block_lines 'PENDING SOURCE REFS' | jq -s '.')
    if [[ "$(jq 'length' <<<"$pending_json")" != 0 ]]; then
        refs_json=$pending_json
        kept=$(sed -n 's/.*kept the \([0-9][0-9]*\) finding record.*/\1/p' <<<"$prompt_text" | head -n 1)
        [[ -n "$kept" ]] || kept=0
    fi
    if [[ "$(jq 'length' <<<"$refs_json")" == 0 ]]; then
        source_agent=alpha
        [[ "$agent" != alpha ]] || source_agent=beta
        refs_json=$(jq -nc --arg a "$source_agent" '[{agent: $a, source_id: ($a + ":F-001")}]')
    fi
    jq -c --arg agent "$agent" --arg mode "$mode" --argjson kept "$kept" '
        to_entries
        | map(if .key == 0 and $mode == "split-first" then (., {key: .key, value: .value, split: true}) else . end)
        | to_entries[] | .value + {ordinal: .key} |
        (.key == 0 and $mode == "reject-first") as $rejected |
        (.split // false) as $split |
        {
        record: "finding",
        schema_version: 1,
        source_id: ($agent + ":C-" + (("00" + ((.ordinal + 1 + $kept) | tostring))[-3:])),
        source_refs: [.value],
        title: "Fixture changed-line defect",
        claim: "The fixture changed branch can fail.",
        anchor: {kind: "changed-line", file: "fixture odd [name].txt", start: 1, "end": 1},
        evidence: ["The exact changed branch confirms the supplied finding."],
        failure_scenario: (if $rejected then null else "The fixture request reaches the changed branch and fails." end),
        recommendation: "Correct the changed branch.",
        classification: (if $rejected then "REJECTED" else "CONFIRMED" end),
        severity: (if $rejected then null elif $split then "P3" else "P1" end),
        category: "correctness",
        contributing_agents: [.value.agent],
        verification_limitations: [],
        existing_feedback: {state: "new", thread_ids: []}
    }' <<<"$refs_json"
    jq -c --arg mode "$mode" --argjson kept "$kept" '{
        record: "complete",
        schema_version: 1,
        finding_count: (length + $kept + (if $mode == "split-first" then 1 else 0 end)),
        summary: "The supplied fixture findings were classified.",
        verification_limitations: [],
        positive_evidence: []
    }' <<<"$refs_json"
}

emit_resolution_records() {
    local status=${1:-resolved} method=${2:-source} command_json=${3:-null} basis=${4:-general_engineering} basis_source=${5:-} kind=${6:-factual}
    prompt_block_lines 'REQUIRED RESOLUTIONS' | jq -c --arg status "$status" --arg method "$method" --argjson command "$command_json" \
        --arg basis "$basis" --arg basis_source "$basis_source" --arg kind "$kind" '{
        record: "resolution", schema_version: 1, dispute_id, primary_ref,
        conflicting_refs: [.conflicting_refs[] | {agent, source_id}],
        final_source_id: "FINAL-001", dispute_kind: $kind, resolution_status: $status,
        verification_method: $method, command: $command,
        observed: (if $status == "resolved" then "The changed branch was read directly; the disputed premise holds." else null end),
        basis: $basis, basis_source: (if $basis_source == "" then null else $basis_source end), limitations: []}'
}

# One record for the first required source ref and no terminal record: the final
# synthesis equivalent of an agent that treats its first answer as the whole turn.
emit_truncated_ndjson_final() {
    prompt_block_lines 'REQUIRED SOURCE REFS' | jq -s -c '.[0:1] | {
        record: "finding", schema_version: 1, source_id: "FINAL-001", source_refs: .,
        title: "Fixture changed-line defect", claim: "The fixture changed branch can fail.",
        anchor: {kind: "changed-line", file: "fixture odd [name].txt", start: 1, "end": 1},
        evidence: ["The canonical cross-review confirms the exact changed branch."],
        failure_scenario: "The fixture request reaches the changed branch and fails.",
        recommendation: "Correct the changed branch.", classification: "CONFIRMED", severity: "P1",
        category: "correctness", contributing_agents: ([.[].agent] | unique),
        verification_limitations: [], existing_feedback: {state: "new", thread_ids: []},
        include_in_rejected_summary: false
    }'
}

emit_valid_ndjson_final() {
    local resolution_status=${1:-resolved} resolution_method=${2:-source} command_json=${3:-null}
    local basis=${4:-general_engineering} basis_source=${5:-} classification=${6:-CONFIRMED} split=${7:-false} kind=${8:-factual}
    local refs_json pending_json kept=0 primary_id=FINAL-001
    refs_json=$(prompt_block_lines 'REQUIRED SOURCE REFS' | jq -s '.')
    pending_json=$(prompt_block_lines 'PENDING SOURCE REFS' | jq -s '.')
    if [[ "$(jq 'length' <<<"$pending_json")" != 0 ]]; then
        refs_json=$pending_json
        primary_id=FINAL-002
        kept=$(sed -n 's/.*kept the \([0-9][0-9]*\) finding record.*/\1/p' <<<"$prompt_text" | head -n 1)
        [[ -n "$kept" ]] || kept=0
    fi
    if [[ "$(jq 'length' <<<"$refs_json")" == 0 ]]; then
        refs_json='[{"agent":"alpha","source_id":"alpha:C-001"},{"agent":"beta","source_id":"beta:C-001"}]'
    fi
    if [[ "$split" == true ]]; then
        # Keep the last ref in its own final record so a dispute spans two final records.
        jq -c '.[-1:] | {
            record: "finding", schema_version: 1, source_id: "FINAL-002", source_refs: .,
            title: "Fixture split topic", claim: "The split topic of the compound claim also holds.",
            anchor: {kind: "changed-line", file: "fixture odd [name].txt", start: 1, "end": 1},
            evidence: ["The split cross-review record confirms the second topic."],
            failure_scenario: "The fixture request reaches the second topic.", recommendation: "Correct the second topic.",
            classification: "CONFIRMED", severity: "P3", category: "correctness",
            contributing_agents: ([.[].agent] | unique), verification_limitations: [],
            existing_feedback: {state: "new", thread_ids: []}, include_in_rejected_summary: false
        }' <<<"$refs_json"
        refs_json=$(jq -c '.[:-1]' <<<"$refs_json")
    fi
    jq -c --arg classification "$classification" --arg primary_id "$primary_id" '{
        record: "finding",
        schema_version: 1,
        source_id: $primary_id,
        source_refs: .,
        title: "Fixture changed-line defect",
        claim: "The fixture changed branch can fail.",
        anchor: {kind: "changed-line", file: "fixture odd [name].txt", start: 1, "end": 1},
        evidence: ["Both canonical cross-reviews confirm the exact changed branch."],
        failure_scenario: "The fixture request reaches the changed branch and fails.",
        recommendation: "Correct the changed branch.",
        classification: $classification,
        severity: (if $classification == "CONFIRMED" then "P1" else null end),
        category: "correctness",
        contributing_agents: ([.[].agent] | unique),
        verification_limitations: [],
        existing_feedback: {state: "new", thread_ids: []},
        include_in_rejected_summary: false
    }' <<<"$refs_json"
    emit_resolution_records "$resolution_status" "$resolution_method" "$command_json" "$basis" "$basis_source" "$kind"
    jq -nc --argjson count "$(if [[ "$split" == true ]]; then printf 2; else printf 1; fi)" --argjson kept "$kept" '{
        record: "complete",
        schema_version: 1,
        finding_count: ($count + $kept),
        summary: "The canonical cross-review finding is confirmed.",
        verification_limitations: [],
        positive_evidence: []
    }'
}

emit_contract_ndjson() {
    case "$phase" in
        'primary review')
            jq -nc --arg agent "$agent" '{record:"finding",schema_version:1,source_id:"FIX-PRIMARY-001",title:"Fixture contract finding",claim:"The fixture changed branch can fail.",anchor:{kind:"changed-line",file:"fixture/Changed.php",start:10,"end":10},evidence:["The fixture line is explicitly changed."],failure_scenario:"A fixture request reaches the changed branch.",recommendation:"Correct the fixture branch.",classification:null,severity:"P2",category:"correctness",contributing_agents:[$agent],verification_limitations:[],existing_feedback:{state:"new",thread_ids:[]}}'
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
        emit_valid_for_phase
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
    cross-ndjson-stops-early)
        # Ends the turn after the first record, with no terminal record: the
        # failure the real agents produce when they treat one record as a whole
        # answer. awk, not head, so the producing jq never sees SIGPIPE.
        emit_valid_ndjson_cross | awk 'NR == 1'
        write_usage null 31
        ;;
    final-ndjson-stops-early)
        emit_truncated_ndjson_final
        write_usage null 29
        ;;
    cross-ndjson-ignores-pending)
        # Answers the original required refs instead of the pending ones, which
        # duplicates a kept source_id once the orchestrator merges the streams.
        prompt_text=${prompt_text//PENDING SOURCE REFS/SUPERSEDED SOURCE REFS}
        emit_valid_ndjson_cross
        write_usage null 33
        ;;
    cross-ndjson-split)
        emit_valid_ndjson_cross split-first
        write_usage null 57
        ;;
    final-resolution-uncertain)
        emit_valid_ndjson_final uncertain manual
        write_usage null 57
        ;;
    final-resolution-measured)
        emit_valid_ndjson_final resolved command '["grep","-n","fixture","fixture odd [name].txt"]' explicit_repository_rule AGENTS.md
        write_usage null 57
        ;;
    final-resolution-unavailable)
        emit_valid_ndjson_final uncertain command '["docker","compose","exec","db","mysql"]' general_engineering '' UNCERTAIN
        write_usage null 57
        ;;
    final-split-refs)
        emit_valid_ndjson_final not_applicable source null general_engineering '' CONFIRMED true severity
        write_usage null 57
        ;;
    final-diagnostic-only)
        emit_valid_ndjson_final | jq -c 'if .record == "finding" then .evidence = ["CI check phpunit failed", "Pipeline status: pending"] else . end'
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
        emit_valid_ndjson_final | replace_first_literal '"classification":"CONFIRMED"' '"classification":"UNCERTAIN"' | replace_first_literal '"severity":"P1"' '"severity":null'
        write_usage null 59
        ;;
    unsafe-cross-ndjson-repair)
        emit_valid_ndjson_cross | replace_first_literal '"classification":"CONFIRMED"' '"classification":"UNCERTAIN"'
        write_usage null 59
        ;;
    unsafe-ndjson-repair)
        emit_valid_ndjson_primary | replace_first_literal 'The fixture changed branch can fail.' 'The repair rewrote the finding claim.'
        write_usage null 59
        ;;
    fail-once)
        if (( attempt == 1 )); then
            printf 'mock attempt one failure\n' >&2
            write_usage null 7
            exit 17
        fi
        if [[ "${REVIEW_PR_OUTPUT_CONTRACT:-}" == ndjson-v1 ]]; then
            emit_valid_for_phase
        else
            emit_valid_output
        fi
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
