# Dispute Resolution Records Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make cross-review disagreements and their resolution machine-readable in the final `ndjson-v1` stream through an opt-in `resolution` record type, without changing how existing runs validate.

**Architecture:** The orchestrator detects disputes deterministically from the canonical cross-review sidecars and lists them in a `REQUIRED RESOLUTIONS` prompt block. The finalizer emits one `resolution` record per dispute in the same NDJSON stream. The orchestrator partitions the stream into finding records (validated exactly as today) and resolution records (validated against the dispute list and the covering final findings), publishes a `*-final-resolutions.json` sidecar, freezes resolution decisions during schema repair, and renders a compact table in the final Markdown. Everything is behind `reporting.dispute_resolution` (default `false`).

**Tech Stack:** Bash 5 (`set -euo pipefail`), `jq`, the existing library-mode test harness (`tests/review-pr/*.sh`, `source bin/review-pr --` with `REVIEW_PR_LIBRARY_MODE=true`), the mock agent runner (`tests/review-pr/mock-agent-runner.sh`).

**Spec:** `docs/review-pr-finding-contract.md`, section "Accepted dispute-resolution design (opt-in `resolution` records)".

## Global Constraints

- No new required field on existing `ndjson-v1` records; a run without the flag validates exactly as before.
- `reporting.dispute_resolution: true` requires `reporting.finding_contract.final = "ndjson-v1"`.
- `dispute_id` is `dispute:<primary agent>:<primary source_id>`.
- A dispute exists when cross-review records referencing the same primary ref disagree in classification, or all say `CONFIRMED` with different severities.
- `command` is an argv array of non-empty strings or `null`; it is recorded, never evaluated.
- Validation failure reasons use the existing granular format: `<token>: resolution[<dispute_id>].<field>`.
- Strict Bash, atomic publication, portable Linux/macOS, `jq` only, no new dependencies.
- Every code change lands with a failing test first, then the implementation, then `bash -n bin/review-pr`, `git diff --check`, and the affected test file green; the full suite (`bash tests/review-pr/run.sh`) before each commit.
- Keep private paths, company names, and ticket IDs out of tracked files (`packaging/private-data-audit.sh` runs in the suite).

---

### Task 1: Configuration flag `reporting.dispute_resolution`

**Files:**
- Modify: `bin/review-pr` (global defaults near line 154 `FINAL_FINDING_CONTRACT_MODE=markdown`; reporting validation near line 527; reporting load near line 715; `--show-config` near the `Final finding contract:` line)
- Modify: `config/review-pr.schema.json` (`properties.reporting.properties`)
- Test: `tests/review-pr/test_config.sh`

**Interfaces:**
- Produces: global `DISPUTE_RESOLUTION_ENABLED` (`true`/`false`, default `false`), set by `load_config`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/review-pr/test_config.sh` before the final `printf '%s assertions passed.\n'` line:

```bash
dispute_config="$test_root/dispute.json"
dispute_output="$test_root/dispute-show-config.txt"
jq '.reporting.finding_contract = {primary: "ndjson-v1", cross_review: "ndjson-v1", final: "ndjson-v1"} |
    .reporting.comparison_sections = {cross_review: "none", final: "none"} |
    .reporting.dispute_resolution = true' "$config_file" >"$dispute_config"
"$repo_root/bin/review-pr" --config "$dispute_config" --show-config >"$dispute_output"
assert_file_contains "$dispute_output" 'Dispute resolution: enabled' \
    'dispute resolution can be enabled on top of a structured final contract'
assert_file_contains "$show_output" 'Dispute resolution: disabled' \
    'dispute resolution is disabled by default'

dispute_without_final="$test_root/dispute-without-final.json"
jq '.reporting.dispute_resolution = true' "$config_file" >"$dispute_without_final"
if "$repo_root/bin/review-pr" --config "$dispute_without_final" --show-config >/dev/null 2>&1; then
    fail 'dispute resolution must require a structured final contract'
fi
pass 'dispute resolution is rejected without final=ndjson-v1'

dispute_wrong_type="$test_root/dispute-wrong-type.json"
jq '.reporting.dispute_resolution = "yes"' "$config_file" >"$dispute_wrong_type"
if "$repo_root/bin/review-pr" --config "$dispute_wrong_type" --show-config >/dev/null 2>&1; then
    fail 'non-boolean dispute_resolution must fail validation'
fi
pass 'non-boolean dispute_resolution is rejected'
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/review-pr/test_config.sh 2>&1 | grep -E 'not ok' | head -1`
Expected: `not ok - dispute resolution can be enabled ...` (the configuration is rejected because `dispute_resolution` is an unknown reporting key).

- [ ] **Step 3: Implement**

In `bin/review-pr`:

1. Global default, next to `FINAL_FINDING_CONTRACT_MODE=markdown`:
   ```bash
   DISPUTE_RESOLUTION_ENABLED=false
   ```
2. Reporting key validation (the jq around line 527): extend the allowed list to
   `["comparison_sections", "dispute_resolution", "finding_contract", "include_comparison_sections"]` and add
   ```jq
   (if has("dispute_resolution") then (.dispute_resolution | type == "boolean") else true end) and
   ```
3. After `FINAL_FINDING_CONTRACT_MODE=$(jq -r '.reporting.finding_contract.final // "markdown"' "$CONFIG_FILE")` and its dependency checks:
   ```bash
   DISPUTE_RESOLUTION_ENABLED=$(jq -r '.reporting.dispute_resolution // false' "$CONFIG_FILE")
   if [[ "$DISPUTE_RESOLUTION_ENABLED" == true ]]; then
       [[ "$FINAL_FINDING_CONTRACT_MODE" == ndjson-v1 ]] \
           || die 'reporting.dispute_resolution=true requires reporting.finding_contract.final=ndjson-v1'
   fi
   ```
4. `--show-config`, after `printf 'Final finding contract: %s\n'`:
   ```bash
   printf 'Dispute resolution: %s\n' "$(if [[ "$DISPUTE_RESOLUTION_ENABLED" == true ]]; then printf enabled; else printf disabled; fi)"
   ```

In `config/review-pr.schema.json`, inside `properties.reporting.properties` add:
```json
"dispute_resolution": {
  "type": "boolean",
  "default": false,
  "description": "Emit and validate opt-in resolution records for cross-review disagreements in the final ndjson-v1 stream. Requires finding_contract.final = ndjson-v1."
}
```
Keep the file's existing two-space formatting; edit textually, do not re-serialize the whole file.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash -n bin/review-pr && bash tests/review-pr/test_config.sh 2>&1 | grep -E 'not ok|assertions passed'`
Expected: `20 assertions passed.` (16 before + 4).

- [ ] **Step 5: Commit**

```bash
git add bin/review-pr config/review-pr.schema.json tests/review-pr/test_config.sh
git commit -m "Add the reporting.dispute_resolution flag"
```

---

### Task 2: Deterministic dispute detection

**Files:**
- Modify: `bin/review-pr` (new function next to `build_final_expected_refs`, currently near line 3177)
- Test: `tests/review-pr/test_finding_contract.sh` (after the `build_final_expected_refs` assertions, before `final_records=`)

**Interfaces:**
- Produces: `build_final_disputes <output_file>` — reads `CROSS_FINDINGS_OUTPUTS[agent]` for every agent in `REVIEW_AGENTS`, writes a sorted JSON array; returns 1 when any canonical cross-review sidecar is missing. Each element:
  ```json
  {"dispute_id":"dispute:beta:beta:F-001",
   "primary_ref":{"agent":"beta","source_id":"beta:F-001"},
   "kind_hint":"factual",
   "conflicting_refs":[{"agent":"alpha","source_id":"alpha:C-001","classification":"CONFIRMED","severity":"P1"},
                       {"agent":"gamma","source_id":"gamma:C-001","classification":"REJECTED","severity":null}]}
  ```
  `kind_hint` is `factual` when classifications differ and `severity` when all are `CONFIRMED` with different severities. It is informational for the model; the model decides `dispute_kind`.

- [ ] **Step 1: Write the failing tests**

Insert after the `build_final_expected_refs` assertions in `tests/review-pr/test_finding_contract.sh`:

```bash
gamma_cross_canonical="$test_root/cross-gamma-canonical.json"
jq '.agent = "gamma" | .findings[0].source_id = "gamma:C-001" | .findings[0].classification = "REJECTED" | .findings[0].severity = null' \
    "$cross_canonical" >"$gamma_cross_canonical"
REVIEW_AGENTS=(alpha gamma)
CROSS_FINDINGS_OUTPUTS[gamma]="$gamma_cross_canonical"
disputes_file="$test_root/disputes.json"
assert_true 'dispute detection reads every canonical cross-review sidecar' \
    build_final_disputes "$disputes_file"
assert_eq '1' "$(jq 'length' "$disputes_file")" \
    'a primary ref classified CONFIRMED and REJECTED by different cross-reviewers is one dispute'
assert_eq 'dispute:beta:beta:F-001' "$(jq -r '.[0].dispute_id' "$disputes_file")" \
    'dispute ids derive from the primary ref'
assert_eq 'factual' "$(jq -r '.[0].kind_hint' "$disputes_file")" \
    'differing classifications hint at a factual dispute'
assert_eq 'alpha:alpha:C-001,gamma:gamma:C-001' \
    "$(jq -r '[.[0].conflicting_refs[] | .agent + ":" + .source_id] | join(",")' "$disputes_file")" \
    'conflicting refs list every cross-review record of the disputed primary ref in stable order'

severity_cross_canonical="$test_root/cross-gamma-severity.json"
jq '.findings[0].classification = "CONFIRMED" | .findings[0].severity = "P3"' "$gamma_cross_canonical" >"$severity_cross_canonical"
CROSS_FINDINGS_OUTPUTS[gamma]="$severity_cross_canonical"
assert_true 'dispute detection handles severity-only disagreement' build_final_disputes "$disputes_file"
assert_eq 'severity' "$(jq -r '.[0].kind_hint' "$disputes_file")" \
    'agreeing CONFIRMED classifications with different severities hint at a severity dispute'

CROSS_FINDINGS_OUTPUTS[gamma]="$cross_canonical"
assert_true 'dispute detection runs on agreeing cross-reviews' build_final_disputes "$disputes_file"
assert_eq '0' "$(jq 'length' "$disputes_file")" 'agreeing cross-reviews produce no dispute'

unset 'CROSS_FINDINGS_OUTPUTS[gamma]'
REVIEW_AGENTS=(alpha)
```

Note: `$cross_canonical` (agent `alpha`, one `CONFIRMED P1` record covering `beta:beta:F-001`) already exists earlier in the file. The gamma copy keeps the same primary ref, so both reviewers judge the same primary finding.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/review-pr/test_finding_contract.sh 2>&1 | grep -E 'not ok|command not found' | head -2`
Expected: `build_final_disputes: command not found` followed by a `not ok` line.

- [ ] **Step 3: Implement**

Add to `bin/review-pr` directly after `build_final_expected_refs()`:

```bash
build_final_disputes() {
    local output_file=$1
    local agent
    local -a input_files=()

    for agent in "${REVIEW_AGENTS[@]}"; do
        [[ -s "${CROSS_FINDINGS_OUTPUTS[$agent]:-}" ]] || return 1
        input_files+=("${CROSS_FINDINGS_OUTPUTS[$agent]}")
    done
    (( ${#input_files[@]} > 0 )) || return 1
    jq -s '
        [ .[] as $report |
          $report.findings[] as $finding |
          $finding.source_refs[] |
          {
            primary: {agent: .agent, source_id: .source_id},
            cross: {agent: $report.agent, source_id: $finding.source_id,
                    classification: $finding.classification, severity: $finding.severity}
          }
        ]
        | group_by(.primary.agent, .primary.source_id)
        | map(
            (map(.cross) | sort_by(.agent, .source_id)) as $refs |
            ($refs | map(.classification) | unique) as $classes |
            ($refs | map(.severity) | unique) as $severities |
            if ($classes | length) > 1 then
                {dispute_id: ("dispute:" + .[0].primary.agent + ":" + .[0].primary.source_id),
                 primary_ref: .[0].primary, kind_hint: "factual", conflicting_refs: $refs}
            elif $classes == ["CONFIRMED"] and ($severities | length) > 1 then
                {dispute_id: ("dispute:" + .[0].primary.agent + ":" + .[0].primary.source_id),
                 primary_ref: .[0].primary, kind_hint: "severity", conflicting_refs: $refs}
            else empty end)
        | sort_by(.dispute_id)
    ' "${input_files[@]}" >"$output_file"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash -n bin/review-pr && bash tests/review-pr/test_finding_contract.sh 2>&1 | grep -E 'not ok|assertions passed'`
Expected: `assertions passed.` with the count increased by 8 (no `not ok`).

- [ ] **Step 5: Commit**

```bash
git add bin/review-pr tests/review-pr/test_finding_contract.sh
git commit -m "Detect cross-review disputes deterministically"
```

---

### Task 3: `REQUIRED RESOLUTIONS` prompt block and resolution contract text

**Files:**
- Modify: `bin/review-pr` (`append_required_source_refs_to_prompt` neighbourhood; the ndjson branch of `write_final_prompt`, the `final_format_block` heredoc that starts with `Output contract: ndjson-v1. This orchestrator contract overrides every Markdown format`)
- Test: `tests/review-pr/test_finding_contract.sh`

**Interfaces:**
- Consumes: `build_final_disputes` (Task 2), `DISPUTE_RESOLUTION_ENABLED` (Task 1).
- Produces: `append_required_resolutions_to_prompt <prompt_file> <disputes_file>` which appends:
  ```
  ===== BEGIN REQUIRED RESOLUTIONS =====
  <one explanatory paragraph>
  {"dispute_id":...,"primary_ref":...,"kind_hint":...,"conflicting_refs":[...]}   (one per line, or the literal line "none")
  ===== END REQUIRED RESOLUTIONS =====
  ```
  and the constant `FINAL_RESOLUTION_CONTRACT_BLOCK` (text inserted into the final ndjson contract when the flag is on).

- [ ] **Step 1: Write the failing tests**

Append to `tests/review-pr/test_finding_contract.sh` right after the Task 2 block:

```bash
resolutions_prompt="$test_root/required-resolutions-prompt.md"
printf 'Prompt body\n' >"$resolutions_prompt"
printf '%s\n' '[{"dispute_id":"dispute:beta:beta:F-001","primary_ref":{"agent":"beta","source_id":"beta:F-001"},"kind_hint":"factual","conflicting_refs":[{"agent":"alpha","source_id":"alpha:C-001","classification":"CONFIRMED","severity":"P1"},{"agent":"gamma","source_id":"gamma:C-001","classification":"REJECTED","severity":null}]}]' >"$disputes_file"
append_required_resolutions_to_prompt "$resolutions_prompt" "$disputes_file"
assert_file_contains "$resolutions_prompt" '===== BEGIN REQUIRED RESOLUTIONS =====' \
    'the final prompt gets a required-resolutions block'
assert_file_contains "$resolutions_prompt" '"dispute_id":"dispute:beta:beta:F-001"' \
    'each detected dispute is listed as one compact JSON line'
assert_file_contains "$resolutions_prompt" 'exactly one resolution record per listed dispute' \
    'the block states the one-record-per-dispute rule'
printf '[]\n' >"$disputes_file"
printf 'Prompt body\n' >"$resolutions_prompt"
append_required_resolutions_to_prompt "$resolutions_prompt" "$disputes_file"
assert_file_contains "$resolutions_prompt" 'none' \
    'an empty dispute list is stated explicitly so the model emits no resolution records'
assert_true 'the resolution contract text names every record key' \
    grep -Fq -- 'dispute_id, primary_ref, conflicting_refs, final_source_id, dispute_kind, resolution_status, verification_method, command, observed, basis, basis_source, limitations' <<<"$FINAL_RESOLUTION_CONTRACT_BLOCK"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/review-pr/test_finding_contract.sh 2>&1 | grep -E 'not ok|command not found' | head -2`
Expected: `append_required_resolutions_to_prompt: command not found`.

- [ ] **Step 3: Implement**

Add after `append_required_source_refs_to_prompt()` in `bin/review-pr`:

```bash
readonly FINAL_RESOLUTION_CONTRACT_BLOCK='Dispute resolutions: when the prompt contains a REQUIRED RESOLUTIONS block, emit exactly one resolution record per listed dispute, before the complete record, and no other resolution records. A resolution record has exactly these keys: record, schema_version, dispute_id, primary_ref, conflicting_refs, final_source_id, dispute_kind, resolution_status, verification_method, command, observed, basis, basis_source, limitations.
- record is "resolution", schema_version is 1; dispute_id, primary_ref, and conflicting_refs ({"agent","source_id"} pairs) are copied exactly from the block.
- final_source_id names the finding record in this stream that covers the dispute; its source_refs must include every conflicting ref.
- dispute_kind is factual (the reviewers disagree about what the code does or whether something exists), severity (they agree on the fact and disagree on impact), or mixed.
- resolution_status is resolved, uncertain, or not_applicable; not_applicable is allowed only for a severity dispute.
- verification_method is source, command, test, repository_rule, runtime, or manual. A factual or mixed dispute is resolved only by a method other than manual, and its covering finding may be CONFIRMED only when the dispute is resolved. When the fact could not be measured, set resolution_status to uncertain and classify the covering finding UNCERTAIN: the number of reviewers never settles a fact.
- command is null or an argv array of non-empty strings describing the measurement (no shell string). It is required when verification_method is command or test. The orchestrator records it and does not execute it.
- observed states what the measurement or source read showed; required when resolution_status is resolved.
- basis is explicit_repository_rule, skill_rule, inferred_convention, or general_engineering. basis_source is a repository path (optionally path:line) for explicit_repository_rule, the configured skill name for skill_rule, and null otherwise. A finding whose only basis is inferred_convention cannot carry P0 or P1.
- limitations is a string array of what remains unverified.'

append_required_resolutions_to_prompt() {
    local prompt_file=$1
    local disputes_file=$2

    {
        printf '\n===== BEGIN REQUIRED RESOLUTIONS =====\n'
        printf '%s\n' 'The cross-reviewers disagree about the primary findings listed below. Emit exactly one resolution record per listed dispute, copying dispute_id, primary_ref, and conflicting_refs exactly; emit no resolution record for anything else. When the list is "none", emit no resolution records.'
        if [[ "$(jq 'length' "$disputes_file")" == 0 ]]; then
            printf 'none\n'
        else
            jq -c '.[]' "$disputes_file"
        fi
        printf '===== END REQUIRED RESOLUTIONS =====\n'
    } >>"$prompt_file"
}
```

In `write_final_prompt`, inside `if [[ "$FINAL_FINDING_CONTRACT_MODE" == ndjson-v1 ]]; then` after `append_required_source_refs_to_prompt "$prompt_file" final`, add:

```bash
        if [[ "$DISPUTE_RESOLUTION_ENABLED" == true ]]; then
            new_temp_file 'final-disputes'
            build_final_disputes "$NEW_TEMP_FILE" || die "Cannot detect cross-review disputes for final synthesis"
            append_required_resolutions_to_prompt "$prompt_file" "$NEW_TEMP_FILE"
        fi
```

In the ndjson `final_format_block` heredoc, after the bullet that begins `- All reader-facing string values must use ${FINAL_LANGUAGE_NAME}`, add a line that expands `${dispute_contract_block}`; before the heredoc set:

```bash
        local dispute_contract_block=''
        [[ "$DISPUTE_RESOLUTION_ENABLED" != true ]] || dispute_contract_block=$FINAL_RESOLUTION_CONTRACT_BLOCK
```
(`write_final_prompt` already declares locals at its top; add `dispute_contract_block` there instead of mid-function if the function uses a single `local` block.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash -n bin/review-pr && bash tests/review-pr/test_finding_contract.sh 2>&1 | grep -E 'not ok|assertions passed'`
Expected: no `not ok`, count increased by 5.

- [ ] **Step 5: Commit**

```bash
git add bin/review-pr tests/review-pr/test_finding_contract.sh
git commit -m "List required dispute resolutions in the final prompt"
```

---

### Task 4: Resolution record validation and canonical sidecar

**Files:**
- Modify: `bin/review-pr` (new functions after `validate_final_ndjson_records`)
- Modify: `config/review-pr-findings-v1.schema.json` (add `#/$defs/resolution` and reference it from the top-level `oneOf`)
- Create: `tests/review-pr/fixtures/final-resolution-valid.ndjson`
- Test: `tests/review-pr/test_finding_contract.sh`

**Interfaces:**
- Produces:
  - `validate_final_resolutions <resolutions_records_file> <final_canonical_file> <disputes_file> <output_canonical_file>` — `resolutions_records_file` is a JSON array of the `record == "resolution"` objects; returns 0 and writes `{"contract":"ndjson-v1","schema_version":1,"phase":"final-synthesis","disputes":[...],"resolutions":[...]}`; returns 1 otherwise.
  - `describe_resolution_validation_failure <resolutions_records_file> <final_canonical_file> <disputes_file>` — prints comma-separated details such as `resolution[dispute:beta:beta:F-001].verification_method`, `resolutions.missing[dispute:...]`, `resolutions.unknown[...]`, `resolution[...].final_source_id`, `resolution[...].confirmed_over_unresolved_factual`, `resolution[...].inferred_convention_severity`.

- [ ] **Step 1: Create the positive fixture**

`tests/review-pr/fixtures/final-resolution-valid.ndjson` (three physical lines):

```jsonl
{"record":"finding","schema_version":1,"source_id":"FINAL-001","source_refs":[{"agent":"alpha","source_id":"alpha:C-001"},{"agent":"gamma","source_id":"gamma:C-001"}],"title":"Fixture final finding","claim":"The changed branch can fail.","anchor":{"kind":"changed-line","file":"src/Changed.php","start":10,"end":10},"evidence":["The canonical cross-review confirms the changed failure path."],"failure_scenario":"The request reaches the changed branch.","recommendation":"Correct the branch.","classification":"CONFIRMED","severity":"P1","category":"correctness","contributing_agents":["alpha","gamma"],"verification_limitations":[],"existing_feedback":{"state":"new","thread_ids":[]},"include_in_rejected_summary":false}
{"record":"resolution","schema_version":1,"dispute_id":"dispute:beta:beta:F-001","primary_ref":{"agent":"beta","source_id":"beta:F-001"},"conflicting_refs":[{"agent":"alpha","source_id":"alpha:C-001"},{"agent":"gamma","source_id":"gamma:C-001"}],"final_source_id":"FINAL-001","dispute_kind":"factual","resolution_status":"resolved","verification_method":"command","command":["rg","-n","changedBranch","src/Changed.php"],"observed":"Line 10 calls changedBranch() before the guard, so the failure path is reachable.","basis":"general_engineering","basis_source":null,"limitations":[]}
{"record":"complete","schema_version":1,"finding_count":1,"summary":"One finding confirmed after measuring the disputed premise.","verification_limitations":[],"positive_evidence":[]}
```

- [ ] **Step 2: Write the failing tests**

Append to `tests/review-pr/test_finding_contract.sh` after the Task 3 block (the variables `final_expected_refs`, `disputes_file` exist; `REVIEW_AGENTS` is `(alpha)` again):

```bash
printf '%s\n' '[{"dispute_id":"dispute:beta:beta:F-001","primary_ref":{"agent":"beta","source_id":"beta:F-001"},"kind_hint":"factual","conflicting_refs":[{"agent":"alpha","source_id":"alpha:C-001","classification":"CONFIRMED","severity":"P1"},{"agent":"gamma","source_id":"gamma:C-001","classification":"REJECTED","severity":null}]}]' >"$disputes_file"
resolution_fixture="$test_dir/fixtures/final-resolution-valid.ndjson"
resolution_records="$test_root/resolution-records.json"
resolution_final_canonical="$test_root/resolution-final-canonical.json"
resolution_canonical="$test_root/resolutions-canonical.json"
jq -s '[.[] | select(.record == "resolution")]' "$resolution_fixture" >"$resolution_records"
jq -s '{findings: [.[] | select(.record == "finding")]}' "$resolution_fixture" >"$resolution_final_canonical"
assert_true 'a measured factual resolution covering its dispute is valid' \
    validate_final_resolutions "$resolution_records" "$resolution_final_canonical" "$disputes_file" "$resolution_canonical"
assert_eq 'ndjson-v1' "$(jq -r '.contract' "$resolution_canonical")" 'the resolutions sidecar records its contract'
assert_eq '1' "$(jq '.disputes | length' "$resolution_canonical")" 'the resolutions sidecar keeps the detected dispute list'
assert_eq '' "$(describe_resolution_validation_failure "$resolution_records" "$resolution_final_canonical" "$disputes_file")" \
    'a valid resolution set has no diagnostics'

check_invalid_resolution() {
    local label=$1 filter=$2 expected_detail=$3
    local candidate="$test_root/resolution-${label}.json"
    jq "$filter" "$resolution_records" >"$candidate"
    assert_false "$label is rejected" \
        validate_final_resolutions "$candidate" "$resolution_final_canonical" "$disputes_file" "$test_root/resolution-${label}-canonical.json"
    assert_eq "$expected_detail" "$(describe_resolution_validation_failure "$candidate" "$resolution_final_canonical" "$disputes_file")" \
        "$label has a stable diagnostic"
}
check_invalid_resolution manual-factual '.[0].verification_method = "manual"' \
    'resolution[dispute:beta:beta:F-001].verification_method'
check_invalid_resolution command-without-observed '.[0].observed = ""' \
    'resolution[dispute:beta:beta:F-001].observed'
check_invalid_resolution unknown-dispute '.[0].dispute_id = "dispute:beta:beta:F-999"' \
    'resolutions.missing[dispute:beta:beta:F-001], resolutions.unknown[dispute:beta:beta:F-999]'
check_invalid_resolution wrong-refs '.[0].conflicting_refs = [{agent: "alpha", source_id: "alpha:C-001"}]' \
    'resolution[dispute:beta:beta:F-001].conflicting_refs'
check_invalid_resolution wrong-final-link '.[0].final_source_id = "FINAL-404"' \
    'resolution[dispute:beta:beta:F-001].final_source_id'
check_invalid_resolution explicit-rule-without-source '.[0].basis = "explicit_repository_rule"' \
    'resolution[dispute:beta:beta:F-001].basis_source'
check_invalid_resolution shell-string-command '.[0].command = "rg -n changedBranch src/Changed.php"' \
    'resolution[dispute:beta:beta:F-001].command'
check_invalid_resolution not-applicable-factual '.[0].resolution_status = "not_applicable"' \
    'resolution[dispute:beta:beta:F-001].resolution_status'

uncertain_resolution="$test_root/resolution-uncertain.json"
jq '.[0].resolution_status = "uncertain" | .[0].verification_method = "manual" | .[0].command = null | .[0].observed = ""' "$resolution_records" >"$uncertain_resolution"
assert_false 'a CONFIRMED finding over an unresolved factual dispute is rejected' \
    validate_final_resolutions "$uncertain_resolution" "$resolution_final_canonical" "$disputes_file" "$test_root/resolution-uncertain-canonical.json"
assert_eq 'resolution[dispute:beta:beta:F-001].confirmed_over_unresolved_factual' \
    "$(describe_resolution_validation_failure "$uncertain_resolution" "$resolution_final_canonical" "$disputes_file")" \
    'the diagnostic names the count-over-measurement violation'
uncertain_final="$test_root/resolution-uncertain-final.json"
jq '.findings[0].classification = "UNCERTAIN" | .findings[0].severity = null' "$resolution_final_canonical" >"$uncertain_final"
assert_true 'an UNCERTAIN finding over an unresolved factual dispute is valid' \
    validate_final_resolutions "$uncertain_resolution" "$uncertain_final" "$disputes_file" "$test_root/resolution-uncertain-ok-canonical.json"

inferred_resolution="$test_root/resolution-inferred.json"
jq '.[0].basis = "inferred_convention"' "$resolution_records" >"$inferred_resolution"
assert_false 'a P1 finding whose only basis is an inferred convention is rejected' \
    validate_final_resolutions "$inferred_resolution" "$resolution_final_canonical" "$disputes_file" "$test_root/resolution-inferred-canonical.json"
assert_eq 'resolution[dispute:beta:beta:F-001].inferred_convention_severity' \
    "$(describe_resolution_validation_failure "$inferred_resolution" "$resolution_final_canonical" "$disputes_file")" \
    'the diagnostic names the inferred-convention severity rule'

severity_disputes="$test_root/severity-disputes.json"
jq '.[0].kind_hint = "severity" | .[0].conflicting_refs[1].classification = "CONFIRMED" | .[0].conflicting_refs[1].severity = "P3"' "$disputes_file" >"$severity_disputes"
severity_resolution="$test_root/resolution-severity.json"
jq '.[0].dispute_kind = "severity" | .[0].resolution_status = "not_applicable" | .[0].verification_method = "manual" | .[0].command = null | .[0].observed = ""' "$resolution_records" >"$severity_resolution"
assert_true 'a severity-only dispute may be reconciled without a measurement' \
    validate_final_resolutions "$severity_resolution" "$resolution_final_canonical" "$severity_disputes" "$test_root/resolution-severity-canonical.json"
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash tests/review-pr/test_finding_contract.sh 2>&1 | grep -E 'not ok|command not found' | head -2`
Expected: `validate_final_resolutions: command not found`.

- [ ] **Step 4: Implement the validator and the diagnostics**

Add after `validate_final_ndjson_records()` in `bin/review-pr`:

```bash
# Shared jq definitions for resolution records. $disputes, $findings are bound by the caller.
readonly RESOLUTION_JQ_DEFS='
    def ref_key: .agent + ":" + .source_id;
    def valid_ref: type == "object" and ((keys - ["agent", "source_id"]) | length) == 0 and
        (.agent | type == "string" and length > 0) and (.source_id | type == "string" and length > 0);
    def expected_refs($dispute): [$dispute.conflicting_refs[] | {agent, source_id}] | sort_by(.agent, .source_id);
    def covering($r): [$findings[] | select(.source_id == $r.final_source_id)] | first // null;
    def string_array: type == "array" and all(.[]; type == "string");
    def argv_or_null: . == null or (type == "array" and length > 0 and all(.[]; type == "string" and length > 0));
    def dispute_for($r): [$disputes[] | select(.dispute_id == $r.dispute_id)] | first // null;
    def resolution_problems:
        . as $r | dispute_for($r) as $d | covering($r) as $f |
        [
          (if ((keys - ["basis", "basis_source", "command", "conflicting_refs", "dispute_id", "dispute_kind", "final_source_id", "limitations", "observed", "primary_ref", "record", "resolution_status", "schema_version", "verification_method"]) | length) > 0 or ((["basis", "basis_source", "command", "conflicting_refs", "dispute_id", "dispute_kind", "final_source_id", "limitations", "observed", "primary_ref", "record", "resolution_status", "schema_version", "verification_method"] - keys) | length) > 0 then "keys" else empty end),
          (if $r.record != "resolution" then "record" else empty end),
          (if $r.schema_version != 1 then "schema_version" else empty end),
          (if $d == null then empty
           elif ($r.primary_ref | valid_ref | not) or ($r.primary_ref | {agent, source_id}) != ($d.primary_ref | {agent, source_id}) then "primary_ref" else empty end),
          (if $d == null then empty
           elif ($r.conflicting_refs | type == "array" and all(.[]; valid_ref)) | not then "conflicting_refs"
           elif ($r.conflicting_refs | map({agent, source_id}) | sort_by(.agent, .source_id)) != expected_refs($d) then "conflicting_refs" else empty end),
          (if $f == null then "final_source_id"
           elif $d != null and (($f.source_refs | map(ref_key)) | contains(expected_refs($d) | map(ref_key)) | not) then "final_source_id" else empty end),
          (if ($r.dispute_kind | IN("factual", "severity", "mixed")) | not then "dispute_kind" else empty end),
          (if ($r.resolution_status | IN("resolved", "uncertain", "not_applicable")) | not then "resolution_status"
           elif $r.resolution_status == "not_applicable" and $r.dispute_kind != "severity" then "resolution_status" else empty end),
          (if ($r.verification_method | IN("source", "command", "test", "repository_rule", "runtime", "manual")) | not then "verification_method"
           elif $r.resolution_status == "resolved" and $r.dispute_kind != "severity" and $r.verification_method == "manual" then "verification_method" else empty end),
          (if ($r.command | argv_or_null | not) then "command"
           elif ($r.verification_method | IN("command", "test")) and $r.command == null then "command" else empty end),
          (if ($r.observed | type == "string") | not then "observed"
           elif $r.resolution_status == "resolved" and ($r.observed | length) == 0 then "observed" else empty end),
          (if ($r.basis | IN("explicit_repository_rule", "skill_rule", "inferred_convention", "general_engineering")) | not then "basis" else empty end),
          (if ($r.basis | IN("explicit_repository_rule", "skill_rule")) then (if ($r.basis_source | type == "string" and length > 0) | not then "basis_source" else empty end)
           else (if $r.basis_source != null then "basis_source" else empty end) end),
          (if ($r.limitations | string_array | not) then "limitations" else empty end),
          (if $f != null and $r.dispute_kind != "severity" and $r.resolution_status != "resolved" and $f.classification == "CONFIRMED" then "confirmed_over_unresolved_factual" else empty end),
          (if $f != null and $r.basis == "inferred_convention" and $f.classification == "CONFIRMED" and ($f.severity | IN("P0", "P1")) then "inferred_convention_severity" else empty end)
        ];
    def stream_problems:
        ([.[].dispute_id | strings]) as $seen |
        ([$disputes[].dispute_id]) as $expected |
        (if (($expected - $seen) | length) > 0 then ["resolutions.missing[" + (($expected - $seen) | join(",")) + "]"] else [] end)
        + (if (($seen - $expected) | length) > 0 then ["resolutions.unknown[" + (($seen - $expected) | unique | join(",")) + "]"] else [] end)
        + (if ($seen | length) != ($seen | unique | length) then ["resolutions.duplicate"] else [] end);
'

describe_resolution_validation_failure() {
    local resolutions_file=$1
    local final_canonical_file=$2
    local disputes_file=$3

    jq -r --slurpfile disputes_wrapper "$disputes_file" --slurpfile canonical "$final_canonical_file" "
        \$disputes_wrapper[0] as \$disputes | \$canonical[0].findings as \$findings |
        ${RESOLUTION_JQ_DEFS}
        ([.[] | objects] ) as \$records |
        (\$records | stream_problems)
        + [\$records[] | . as \$r | (resolution_problems[]) | \"resolution[\" + (\$r.dispute_id | tostring) + \"].\" + .]
        | join(\", \")
    " "$resolutions_file" 2>/dev/null || printf 'diagnostics_unavailable'
}

validate_final_resolutions() {
    local resolutions_file=$1
    local final_canonical_file=$2
    local disputes_file=$3
    local output_file=$4
    local detail

    detail=$(describe_resolution_validation_failure "$resolutions_file" "$final_canonical_file" "$disputes_file")
    [[ -z "$detail" ]] || return 1
    jq --slurpfile disputes "$disputes_file" '{
        contract: "ndjson-v1",
        schema_version: 1,
        phase: "final-synthesis",
        disputes: $disputes[0],
        resolutions: .
    }' "$resolutions_file" >"$output_file"
}
```

Note on the `unknown-dispute` expectation: `stream_problems` lists `resolutions.missing[...]` before `resolutions.unknown[...]`; the per-record check for a record whose dispute is unknown emits nothing extra because `dispute_for` returns `null` and the ref checks are skipped, while `final_source_id` still validates (the covering record exists). Run the test; if the actual output differs only in ordering, fix the function, not the test.

Also add the resolution record to `config/review-pr-findings-v1.schema.json`: a new `#/$defs/resolution` object (`additionalProperties: false`, the 14 required keys, enums as listed in the spec, `command` as `["array","null"]` of non-empty strings, `basis_source` as `["string","null"]`) and a third `$ref` in the top-level `oneOf`. Edit textually and verify with `jq empty config/review-pr-findings-v1.schema.json`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash -n bin/review-pr && bash tests/review-pr/test_finding_contract.sh 2>&1 | grep -E 'not ok|assertions passed'`
Expected: no `not ok`.

- [ ] **Step 6: Commit**

```bash
git add bin/review-pr config/review-pr-findings-v1.schema.json tests/review-pr/fixtures/final-resolution-valid.ndjson tests/review-pr/test_finding_contract.sh
git commit -m "Validate resolution records against detected disputes"
```

---

### Task 5: Wire resolutions through final processing, repair, and publication

**Files:**
- Modify: `bin/review-pr`:
  - `process_final_ndjson_output` (near line 3480)
  - `build_final_repair_baseline`, `validate_final_repair_stability`, `write_final_finding_repair_prompt` (near lines 3540-3610)
  - final publication in `run_final_synthesis` (the block around `mv -- "$FINAL_PROCESSED_FINDINGS_FILE" "$FINAL_FINDINGS_OUTPUT"`, near line 8327) and the rerun variant
  - `FINAL_*` path globals (near line 183) and their assignments (near lines 6875 and the fresh-run block near 8798-8805)
  - `create_full_manifest` artifacts (near line 6375) and the rerun manifest (near line 7242)
  - `describe_ndjson_validation_failure` (final branch must ignore resolution records)
- Test: `tests/review-pr/test_finding_contract.sh`

**Interfaces:**
- Consumes: Tasks 2-4.
- Produces: globals `FINAL_RESOLUTIONS_OUTPUT` (canonical path `${WORK_DIR}/${REPORT_STEM}-final-resolutions.json`, rerun: `${WORK_DIR}/${rerun_stem}-resolutions.json`), `FINAL_PROCESSED_RESOLUTIONS_FILE`; manifest key `artifacts.final_resolutions` (null when disabled); `process_final_ndjson_output` failure reasons `unexpected_resolution_records` and `dispute_resolution_validation_failed: <details>`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/review-pr/test_finding_contract.sh` after the Task 4 block. This exercises `process_final_ndjson_output` end to end in library mode, which needs the same globals the earlier final tests set (`REVIEW_AGENTS=(alpha)`, `CROSS_FINDINGS_OUTPUTS[alpha]`, `FINALIZATION_LANGUAGE`, header variables). The fixture's finding covers `alpha:alpha:C-001` and `gamma:gamma:C-001`, so provide the gamma sidecar again:

```bash
REVIEW_AGENTS=(alpha gamma)
CROSS_FINDINGS_OUTPUTS[gamma]="$gamma_cross_canonical"
DISPUTE_RESOLUTION_ENABLED=true
WORK_DIR=$test_root
REPORT_STEM=resolution-run
FINAL_FINDING_CONTRACT_MODE=ndjson-v1
processed_final="$test_root/processed-final.md"
cp -- "$resolution_fixture" "$processed_final"
assert_true 'a final stream with valid resolution records is processed' \
    process_final_ndjson_output "$processed_final"
assert_file_exists "$FINAL_PROCESSED_RESOLUTIONS_FILE" 'processing produces a resolutions sidecar candidate'
assert_eq '1' "$(jq '.resolutions | length' "$FINAL_PROCESSED_RESOLUTIONS_FILE")" \
    'the resolutions sidecar candidate holds the validated records'
assert_eq '1' "$(jq '.finding_count' "$FINAL_PROCESSED_FINDINGS_FILE")" \
    'resolution records are not counted as findings'
assert_file_contains "$processed_final" '<!-- review-pr:dispute-resolutions -->' \
    'the rendered final report carries the dispute-resolution marker'

DISPUTE_RESOLUTION_ENABLED=false
cp -- "$resolution_fixture" "$processed_final"
assert_false 'resolution records are rejected when the feature is disabled' \
    process_final_ndjson_output "$processed_final"
assert_eq 'unexpected_resolution_records' "$FINDING_CONTRACT_FAILURE_REASON" \
    'the disabled feature reports a stable reason'

DISPUTE_RESOLUTION_ENABLED=true
broken_resolution_stream="$test_root/broken-resolution.ndjson"
jq -c 'if .record == "resolution" then .verification_method = "manual" else . end' "$resolution_fixture" >"$broken_resolution_stream"
cp -- "$broken_resolution_stream" "$processed_final"
assert_false 'an unmeasured factual resolution fails final processing' \
    process_final_ndjson_output "$processed_final"
assert_eq 'dispute_resolution_validation_failed: resolution[dispute:beta:beta:F-001].verification_method' \
    "$FINDING_CONTRACT_FAILURE_REASON" 'final processing exposes the resolution diagnostic'

resolution_baseline="$test_root/resolution-baseline.json"
assert_true 'a stream with resolution records produces a repair baseline' \
    build_final_repair_baseline "$resolution_fixture" "$resolution_baseline"
assert_eq '1' "$(jq '.resolutions | length' "$resolution_baseline")" 'the repair baseline preserves resolution decisions'
cp -- "$resolution_fixture" "$processed_final"
process_final_ndjson_output "$processed_final"
assert_true 'unchanged resolutions satisfy repair stability' \
    validate_final_repair_stability "$resolution_baseline" "$FINAL_PROCESSED_FINDINGS_FILE" "$FINAL_PROCESSED_RESOLUTIONS_FILE"
changed_resolutions="$test_root/changed-resolutions.json"
jq '.resolutions[0].resolution_status = "uncertain"' "$FINAL_PROCESSED_RESOLUTIONS_FILE" >"$changed_resolutions"
assert_false 'repair stability rejects a changed resolution decision' \
    validate_final_repair_stability "$resolution_baseline" "$FINAL_PROCESSED_FINDINGS_FILE" "$changed_resolutions"
assert_true 'a stream without resolution records still satisfies the two-argument stability check' \
    validate_final_repair_stability "$final_repair_baseline" "$final_canonical"
DISPUTE_RESOLUTION_ENABLED=false
REVIEW_AGENTS=(alpha)
unset 'CROSS_FINDINGS_OUTPUTS[gamma]'
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/review-pr/test_finding_contract.sh 2>&1 | grep -E 'not ok' | head -1`
Expected: `not ok - a final stream with valid resolution records is processed` (the current validator rejects the unknown record type).

- [ ] **Step 3: Implement**

1. Globals near line 183: add `FINAL_RESOLUTIONS_OUTPUT=""` and `FINAL_PROCESSED_RESOLUTIONS_FILE=""`. Where `FINAL_FINDINGS_OUTPUT` is assigned for the fresh run and the rerun, assign `FINAL_RESOLUTIONS_OUTPUT="${WORK_DIR}/${REPORT_STEM}-final-resolutions.json"` and `"${WORK_DIR}/${rerun_stem}-resolutions.json"` respectively; add `assert_new_target "$FINAL_RESOLUTIONS_OUTPUT"` beside the existing `assert_new_target "$FINAL_FINDINGS_OUTPUT"` guarded by `[[ "$DISPUTE_RESOLUTION_ENABLED" == true ]]`.

2. `process_final_ndjson_output`: after the records array is built and before `validate_final_ndjson_records`, partition:
   ```bash
   new_temp_file 'final-resolution-records'; resolutions_file=$NEW_TEMP_FILE
   new_temp_file 'final-disputes'; disputes_file=$NEW_TEMP_FILE
   new_temp_file 'final-resolutions-canonical'; resolutions_canonical_file=$NEW_TEMP_FILE
   jq '[.[] | select(.record == "resolution")]' "$records_file" >"$resolutions_file"
   jq '[.[] | select(.record != "resolution")]' "$records_file" >"$records_array_file"
   mv -- "$records_array_file" "$records_file"
   if [[ "$DISPUTE_RESOLUTION_ENABLED" != true ]] && (( $(jq 'length' "$resolutions_file") > 0 )); then
       FINDING_CONTRACT_FAILURE_REASON=unexpected_resolution_records; return 1
   fi
   ```
   (declare the new locals in the function's `local` line). After `validate_final_ndjson_records` succeeds and before rendering:
   ```bash
   FINAL_PROCESSED_RESOLUTIONS_FILE=""
   if [[ "$DISPUTE_RESOLUTION_ENABLED" == true ]]; then
       build_final_disputes "$disputes_file" || { FINDING_CONTRACT_FAILURE_REASON=missing_canonical_cross_inputs; return 1; }
       if ! validate_final_resolutions "$resolutions_file" "$canonical_file" "$disputes_file" "$resolutions_canonical_file"; then
           detail=$(describe_resolution_validation_failure "$resolutions_file" "$canonical_file" "$disputes_file")
           FINDING_CONTRACT_FAILURE_REASON="dispute_resolution_validation_failed${detail:+: $detail}"
           return 1
       fi
       FINAL_PROCESSED_RESOLUTIONS_FILE=$resolutions_canonical_file
   fi
   ```
   Pass `"$FINAL_PROCESSED_RESOLUTIONS_FILE"` as a third argument to `render_final_findings_markdown` (Task 6 makes the renderer accept it; until then it ignores extra arguments, so add the argument now).

3. `describe_ndjson_validation_failure`: in the final branch, records with `record == "resolution"` must be excluded from `$findings` so an unknown record type is not reported when the feature is on. Change `([$records[] | select(.record != "complete")]) as $findings` to `([$records[] | select(.record != "complete" and .record != "resolution")]) as $findings`.

4. `build_final_repair_baseline`: allow `resolution` records in the record-type check (`.record == "finding" or .record == "complete" or .record == "resolution"`) and add to the output object
   ```jq
   resolutions: [.[] | select(.record == "resolution") |
       {dispute_id, primary_ref, conflicting_refs, final_source_id, dispute_kind, resolution_status,
        verification_method, command, observed, basis, basis_source, limitations}]
   ```
   `validate_final_repair_stability` gains an optional third argument (resolutions canonical file). Compare `{findings, completion}` with `$baseline[0] | {findings, completion}`; when the third argument is given, additionally compare `[.resolutions[] | <same 12 keys>]` of that file with `$baseline[0].resolutions`. Extend the repair prompt sentence "The orchestrator structurally compares ..." with: "Resolution records are preserved exactly as well: dispute_id, primary_ref, conflicting_refs, final_source_id, dispute_kind, resolution_status, verification_method, command, observed, basis, basis_source, and limitations are frozen." Update the repair call sites (`validate_final_repair_stability "$baseline_file" "$FINAL_PROCESSED_FINDINGS_FILE"`) to pass `"$FINAL_PROCESSED_RESOLUTIONS_FILE"` when it is non-empty.

5. Publication: where `mv -- "$FINAL_PROCESSED_FINDINGS_FILE" "$FINAL_FINDINGS_OUTPUT"` happens, add
   ```bash
   if [[ -n "$FINAL_PROCESSED_RESOLUTIONS_FILE" ]]; then
       assert_new_target "$FINAL_RESOLUTIONS_OUTPUT"
       mv -- "$FINAL_PROCESSED_RESOLUTIONS_FILE" "$FINAL_RESOLUTIONS_OUTPUT"
   fi
   ```
   Also reset `FINAL_PROCESSED_RESOLUTIONS_FILE=""` wherever `FINAL_PROCESSED_FINDINGS_FILE=""` is reset.

6. Manifests: add `final_resolutions: (if $final_finding_contract == "ndjson-v1" and $dispute_resolution then $final_resolutions else null end)` next to `final_findings` in both manifest builders, with `--arg final_resolutions "${FINAL_RESOLUTIONS_OUTPUT##*/}"` and `--argjson dispute_resolution "$DISPUTE_RESOLUTION_ENABLED"`; record `dispute_resolution: $dispute_resolution` under the manifest `reporting` object.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash -n bin/review-pr && bash tests/review-pr/test_finding_contract.sh 2>&1 | grep -E 'not ok|assertions passed'`
Expected: no `not ok` (the marker assertion passes only after Task 6; if it is the sole failure, proceed to Task 6 before committing, then commit both tasks together).

- [ ] **Step 5: Commit**

```bash
git add bin/review-pr tests/review-pr/test_finding_contract.sh
git commit -m "Process, repair, and publish dispute resolutions"
```

---

### Task 6: Render the dispute-resolution table

**Files:**
- Modify: `bin/review-pr` (`render_final_findings_markdown`, near line 3294; heading globals near lines 106-108 and their UA counterparts in `configure_finalization_language`)
- Test: `tests/review-pr/test_finding_contract.sh`

**Interfaces:**
- Consumes: the resolutions canonical file from Task 5.
- Produces: `render_final_findings_markdown <canonical> <output> [resolutions_canonical]`; heading globals `FINAL_DISPUTE_RESOLUTIONS_HEADING` (`## Dispute resolutions` / `## Вирішення суперечок`) and the marker line `<!-- review-pr:dispute-resolutions -->`.

- [ ] **Step 1: Write the failing tests**

Append after the Task 5 block:

```bash
FINALIZATION_LANGUAGE=EN
configure_finalization_language
rendered_with_resolutions="$test_root/final-with-resolutions.md"
assert_true 'the final renderer accepts a resolutions sidecar' \
    render_final_findings_markdown "$resolution_final_canonical_full" "$rendered_with_resolutions" "$resolution_canonical"
assert_file_contains "$rendered_with_resolutions" '## Dispute resolutions' 'the English final report gets a dispute-resolution section'
assert_file_contains "$rendered_with_resolutions" '<!-- review-pr:dispute-resolutions -->' 'the section carries a language-independent marker'
assert_file_contains "$rendered_with_resolutions" '| `dispute:beta:beta:F-001` | factual | resolved | command |' \
    'each resolution is one table row with kind, status, and method'
assert_file_contains "$rendered_with_resolutions" '`rg -n changedBranch src/Changed.php`' \
    'a recorded argv command is shown joined by spaces inside code formatting'
FINALIZATION_LANGUAGE=UA
configure_finalization_language
render_final_findings_markdown "$resolution_final_canonical_full" "$rendered_with_resolutions" "$resolution_canonical"
assert_file_contains "$rendered_with_resolutions" '## Вирішення суперечок' 'the Ukrainian final report localizes the heading'
assert_file_contains "$rendered_with_resolutions" '| `dispute:beta:beta:F-001` | factual | resolved | command |' \
    'enum values stay language-independent in the Ukrainian table'
FINALIZATION_LANGUAGE=EN
configure_finalization_language
render_final_findings_markdown "$final_canonical" "$rendered_with_resolutions"
assert_false 'a final report without resolutions has no dispute section' \
    grep -Fq -- 'review-pr:dispute-resolutions' "$rendered_with_resolutions"
```

`$resolution_final_canonical_full` must be a canonical final findings file with `primary_refs`; build it right before these assertions with:
```bash
resolution_final_canonical_full="$test_root/resolution-final-canonical-full.json"
jq -s '[.[] | select(.record != "resolution")]' "$resolution_fixture" >"$test_root/resolution-final-records.json"
validate_final_ndjson_records "$test_root/resolution-final-records.json" "$resolution_final_canonical_full" "$final_expected_refs_gamma"
```
where `$final_expected_refs_gamma` is produced by `build_final_expected_refs` while `REVIEW_AGENTS=(alpha gamma)` and `CROSS_FINDINGS_OUTPUTS[gamma]="$gamma_cross_canonical"` are set (reuse the Task 5 setup before it resets `REVIEW_AGENTS`).

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/review-pr/test_finding_contract.sh 2>&1 | grep -E 'not ok' | head -1`
Expected: `not ok - the English final report gets a dispute-resolution section`.

- [ ] **Step 3: Implement**

Globals: `FINAL_DISPUTE_RESOLUTIONS_HEADING='## Dispute resolutions'` next to `FINAL_REJECTED_FINDINGS_HEADING`; in `configure_finalization_language` set the EN value in the EN branch and `'## Вирішення суперечок'` in the UA branch.

In `render_final_findings_markdown` add `local resolutions_file=${3:-}` and, after the rejected-findings block inside the `{ ... } >"$output_file"` group:

```bash
        if [[ -n "$resolutions_file" && -s "$resolutions_file" ]] && (( $(jq '.resolutions | length' "$resolutions_file") > 0 )); then
            printf '\n%s\n\n%s\n\n' '<!-- review-pr:dispute-resolutions -->' "$FINAL_DISPUTE_RESOLUTIONS_HEADING"
            if [[ "$FINALIZATION_LANGUAGE" == UA ]]; then
                printf '%s\n%s\n' '| # | Суперечка | Тип | Статус | Метод | Спостережено | Підстава |' '|---|---|---|---|---|---|---|'
            else
                printf '%s\n%s\n' '| # | Dispute | Kind | Status | Method | Observed | Basis |' '|---|---|---|---|---|---|---|'
            fi
            jq -r '
                def cell: tostring | gsub("\\|"; "\\\\|") | gsub("[\\r\\n]+"; "<br>");
                .resolutions | to_entries[] |
                "| " + ((.key + 1) | tostring) + " | `" + .value.dispute_id + "` | " + .value.dispute_kind + " | " +
                .value.resolution_status + " | " + .value.verification_method + " | " +
                ((if .value.command == null then "" else "`" + (.value.command | join(" ")) + "` " end) + (.value.observed | cell)) + " | " +
                (.value.basis + (if .value.basis_source == null then "" else " (`" + (.value.basis_source | cell) + "`)" end)) + " |"
            ' "$resolutions_file"
        fi
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash -n bin/review-pr && bash tests/review-pr/test_finding_contract.sh 2>&1 | grep -E 'not ok|assertions passed'`
Expected: no `not ok`. Also run `bash tests/review-pr/test_validators.sh` (the legacy final Markdown validator must still accept a report with the new section; if it rejects the extra table, extend `validate_final_markdown` to ignore content after the `review-pr:dispute-resolutions` marker).

- [ ] **Step 5: Commit**

```bash
git add bin/review-pr tests/review-pr/test_finding_contract.sh
git commit -m "Render dispute resolutions in the final report"
```

---

### Task 7: Mock runner scenarios and end-to-end tests

**Files:**
- Modify: `tests/review-pr/mock-agent-runner.sh` (`emit_valid_ndjson_cross`, `emit_valid_ndjson_final`, behaviour `case`)
- Modify: `tests/review-pr/test_pipeline_integration.sh` (new cases `run_dispute_resolution_case`, `run_dispute_resolution_failure_case`, registered next to `run_ndjson_cross_case`)
- Modify: `docs/review-pr.md` (configuration section near `reporting.finding_contract`), `CHANGELOG.md` (Unreleased → Added)

**Interfaces:**
- Consumes: everything above.
- Produces: mock behaviours `cross-ndjson-rejected` (a cross-review that classifies its source `REJECTED`) and `final-resolution-uncertain` (resolution records with `resolution_status: uncertain`, `verification_method: manual`, while the finding stays `CONFIRMED`). The mock reads the prompt from stdin into `prompt_text` at startup (today it is consumed only when a capture directory is set) and derives final `source_refs` from the `REQUIRED SOURCE REFS` block and resolutions from the `REQUIRED RESOLUTIONS` block.

- [ ] **Step 1: Write the failing integration tests**

Add to `tests/review-pr/test_pipeline_integration.sh` (model the structure on `run_ndjson_cross_case`; three agents so that two cross-reviewers judge the same primary finding):

```bash
write_three_agent_config() {
    local config_file=$1 checkout=$2 reviews=$3
    write_config "$config_file" "$checkout" "$reviews" 3
    jq --arg runner "$test_dir/mock-agent-runner.sh" '
        .agents.gamma = {label: "Gamma", enabled: true, model: "mock-gamma", effort: "", runner: $runner} |
        .reviewers = ["alpha", "beta", "gamma"] |
        .reporting.finding_contract = {primary: "ndjson-v1", cross_review: "ndjson-v1", final: "ndjson-v1"} |
        .reporting.comparison_sections = {cross_review: "none", final: "none"} |
        .reporting.dispute_resolution = true' "$config_file" >"$config_file.tmp"
    mv -- "$config_file.tmp" "$config_file"
}

run_dispute_resolution_case() {
    local case_dir="$suite_root/dispute-resolution"
    local reviews="$case_dir/reviews" fake_bin="$case_dir/bin" scenarios="$case_dir/scenarios" capture="$case_dir/captured-prompts"
    local checkout config="$case_dir/config.json" manifest work_dir stem final_prompt

    mkdir -p -- "$case_dir" "$reviews" "$fake_bin" "$scenarios" "$capture"
    checkout=$(make_repository "$case_dir")
    export REVIEW_PR_FAKE_REFERENCE_SHA; REVIEW_PR_FAKE_REFERENCE_SHA=$(git -C "$checkout" rev-parse main)
    export REVIEW_PR_FAKE_PULL_HEAD_SHA; REVIEW_PR_FAKE_PULL_HEAD_SHA=$(git --git-dir="$case_dir/origin.git" rev-parse refs/pull/122/head)
    export REVIEW_PR_FAKE_BASE_REF=main REVIEW_PR_FAKE_DEFAULT_BRANCH=main REVIEW_PR_FAKE_PR_BODY='Fixture dispute resolution.'
    unset REVIEW_PR_FAKE_DEFAULT_BRANCH_FAILURE
    write_three_agent_config "$config" "$checkout" "$reviews"
    ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"
    printf 'cross-ndjson-rejected\n' >"$scenarios/gamma-cross-review"

    PATH="$fake_bin:$PATH" REVIEW_PR_MOCK_BEHAVIOR=valid-ndjson REVIEW_PR_MOCK_SCENARIO_DIR="$scenarios" REVIEW_PR_MOCK_CAPTURE_DIR="$capture" \
        "$repo_root/bin/review-pr" --config "$config" 123 >"$case_dir/output.txt" 2>"$case_dir/stderr.log" \
        || fail "dispute-resolution pipeline failed: $(tail -3 "$case_dir/stderr.log")"
    manifest=$(latest_manifest "$reviews"); work_dir=${manifest%/*}; stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")
    final_prompt="$capture/final-synthesis-alpha-attempt-1.prompt"
    assert_eq complete "$(jq -r '.status.pipeline' "$manifest")" 'a disputed run completes with resolution records'
    assert_file_contains "$final_prompt" '===== BEGIN REQUIRED RESOLUTIONS =====' 'the finalizer receives the detected disputes'
    assert_file_contains "$final_prompt" '"dispute_id":"dispute:alpha:alpha:F-001"' 'the disputed primary finding is listed by its stable id'
    assert_file_exists "$work_dir/${stem}-final-resolutions.json" 'the run publishes a resolutions sidecar'
    assert_eq '1' "$(jq '.resolutions | length' "$work_dir/${stem}-final-resolutions.json")" 'one resolution per detected dispute'
    assert_eq "${stem}-final-resolutions.json" "$(jq -r '.artifacts.final_resolutions' "$manifest")" 'the manifest records the resolutions sidecar'
    assert_eq 'true' "$(jq -r '.reporting.dispute_resolution' "$manifest")" 'the manifest records the enabled feature'
    assert_file_contains "${work_dir%/work}/${stem}-final.md" '<!-- review-pr:dispute-resolutions -->' 'the final report renders the dispute table'
}

run_dispute_resolution_failure_case() {
    local case_dir="$suite_root/dispute-resolution-failure"
    local reviews="$case_dir/reviews" fake_bin="$case_dir/bin" scenarios="$case_dir/scenarios"
    local checkout config="$case_dir/config.json" manifest work_dir stem

    mkdir -p -- "$case_dir" "$reviews" "$fake_bin" "$scenarios"
    checkout=$(make_repository "$case_dir")
    export REVIEW_PR_FAKE_REFERENCE_SHA; REVIEW_PR_FAKE_REFERENCE_SHA=$(git -C "$checkout" rev-parse main)
    export REVIEW_PR_FAKE_PULL_HEAD_SHA; REVIEW_PR_FAKE_PULL_HEAD_SHA=$(git --git-dir="$case_dir/origin.git" rev-parse refs/pull/122/head)
    export REVIEW_PR_FAKE_BASE_REF=main REVIEW_PR_FAKE_DEFAULT_BRANCH=main REVIEW_PR_FAKE_PR_BODY='Fixture dispute resolution failure.'
    unset REVIEW_PR_FAKE_DEFAULT_BRANCH_FAILURE
    write_three_agent_config "$config" "$checkout" "$reviews"
    ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"
    printf 'cross-ndjson-rejected\n' >"$scenarios/gamma-cross-review"
    printf 'final-resolution-uncertain\n' >"$scenarios/alpha-final-synthesis"
    printf 'final-resolution-uncertain\n' >"$scenarios/alpha-final-findings-repair"

    if PATH="$fake_bin:$PATH" REVIEW_PR_MOCK_BEHAVIOR=valid-ndjson REVIEW_PR_MOCK_SCENARIO_DIR="$scenarios" \
        "$repo_root/bin/review-pr" --config "$config" 123 >"$case_dir/output.txt" 2>"$case_dir/stderr.log"; then
        fail 'a CONFIRMED finding over an unmeasured factual dispute must fail final synthesis'
    fi
    pass 'a CONFIRMED finding over an unmeasured factual dispute fails final synthesis'
    manifest=$(latest_manifest "$reviews"); work_dir=${manifest%/*}; stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")
    assert_file_contains "$case_dir/stderr.log" 'dispute_resolution_validation_failed: resolution[dispute:alpha:alpha:F-001].confirmed_over_unresolved_factual' \
        'the failure names the count-over-measurement violation'
    assert_file_not_exists "$work_dir/${stem}-final-resolutions.json" 'no resolutions sidecar is published for an invalid final'
    assert_file_not_exists "${work_dir%/work}/${stem}-final.md" 'no final report is published for an invalid final'
}
```

Register both calls where the other cases run (after `run_ndjson_cross_case`).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/review-pr/test_pipeline_integration.sh 2>&1 | grep -E 'not ok|dispute' | head -3`
Expected: the dispute case fails (the pipeline errors because the mock cross-review for three agents references the wrong peer or the final mock omits gamma's ref).

- [ ] **Step 3: Implement the mock changes**

In `tests/review-pr/mock-agent-runner.sh`:

1. Read the prompt once near the top, replacing the capture-only `cat`:
   ```bash
   prompt_text=$(cat)
   if [[ -n "${REVIEW_PR_MOCK_CAPTURE_DIR:-}" ]]; then
       mkdir -p -- "$REVIEW_PR_MOCK_CAPTURE_DIR"
       printf '%s\n' "$prompt_text" >"${REVIEW_PR_MOCK_CAPTURE_DIR}/${phase_key}-${agent}-attempt-${attempt}.prompt"
   fi
   ```
   Check every other place that reads stdin (`grep -n 'cat\b\|read -r' tests/review-pr/mock-agent-runner.sh`) and switch it to `$prompt_text`.

2. `emit_valid_ndjson_cross`: choose the source agent from the `REQUIRED SOURCE REFS` block when present (first listed `agent`), else keep the alpha/beta fallback:
   ```bash
   local source_agent=alpha classification=${1:-CONFIRMED} severity=${2:-P1}
   if [[ "$agent" == alpha ]]; then source_agent=beta; fi
   local listed
   listed=$(awk '/^===== BEGIN REQUIRED SOURCE REFS =====/{f=1; next} /^===== END REQUIRED SOURCE REFS =====/{f=0} f && /^\{/' <<<"$prompt_text" | jq -r '.agent' | sed -n '1p')
   [[ -z "$listed" ]] || source_agent=$listed
   ```
   and use `--arg classification "$classification" --argjson severity "$( [[ "$severity" == null ]] && printf null || printf '"%s"' "$severity")"` in the record. Add behaviour `cross-ndjson-rejected)` that calls `emit_valid_ndjson_cross REJECTED null` (with `failure_scenario` allowed to stay as is; the validator accepts a string) and `write_usage null 57`.

3. `emit_valid_ndjson_final`: build `source_refs` from the `REQUIRED SOURCE REFS` block when present (`jq -s '.'` over its JSON lines), `contributing_agents` as the unique agents, and then, if the prompt contains a `REQUIRED RESOLUTIONS` block whose body is not `none`, emit one resolution record per listed dispute:
   ```bash
   emit_resolution_records() {
       local status=${1:-resolved} method=${2:-source}
       awk '/^===== BEGIN REQUIRED RESOLUTIONS =====/{f=1; next} /^===== END REQUIRED RESOLUTIONS =====/{f=0} f && /^\{/' <<<"$prompt_text" |
       jq -c --arg status "$status" --arg method "$method" '{
           record: "resolution", schema_version: 1, dispute_id, primary_ref,
           conflicting_refs: [.conflicting_refs[] | {agent, source_id}],
           final_source_id: "FINAL-001", dispute_kind: "factual", resolution_status: $status,
           verification_method: $method, command: null,
           observed: (if $status == "resolved" then "The changed branch was read directly; the disputed premise holds." else "" end),
           basis: "general_engineering", basis_source: null, limitations: []}'
   }
   ```
   Call `emit_resolution_records` between the finding and the complete record in `emit_valid_ndjson_final`; add behaviour `final-resolution-uncertain)` that emits the same finding, `emit_resolution_records uncertain manual`, and the complete record.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/review-pr/test_pipeline_integration.sh 2>&1 | grep -E 'not ok|assertions passed'`
Expected: no `not ok`. Then the whole suite: `bash tests/review-pr/run.sh 2>&1 | tail -2` → `All 12 review-pr test files passed.`

- [ ] **Step 5: Document**

`docs/review-pr.md`, after the paragraph describing `reporting.finding_contract`: add a paragraph "Dispute resolutions" explaining the flag, the detection rule, the record, the sidecar, the table, and that commands are recorded but not executed. `CHANGELOG.md` Unreleased → `### Added`: one entry summarizing the feature. Run `packaging/private-data-audit.sh`.

- [ ] **Step 6: Commit**

```bash
git add tests/review-pr/mock-agent-runner.sh tests/review-pr/test_pipeline_integration.sh docs/review-pr.md CHANGELOG.md
git commit -m "Exercise dispute resolutions end to end"
```

---

### Task 8: Real-model check on the local Pi model (no paid quota)

**Files:** none in the repository; scratch files only.

- [ ] **Step 1: Enable the flag locally** — add `"dispute_resolution": true` under `reporting` in the local configuration, then `review-pr --show-config | grep 'Dispute resolution'` → `enabled`.
- [ ] **Step 2: Rerun an existing structured run's final phase** with `review-pr <repository>#<pr> --rerun-final --run <timestamp>` on a run whose cross-reviews disagree (the run from 2026-09-11 for the small pull request has four disputed primary refs). This uses only the local model.
- [ ] **Step 3: Verify** the `*-resolutions.json` sidecar exists, its `disputes` length matches `build_final_disputes` on the same sidecars, the rendered report has the table, and the attempt log has no `dispute_resolution_validation_failed`. If the local model cannot satisfy the contract, keep the diagnostics, do not weaken the validator, and report which rule it failed.
- [ ] **Step 4: Record the outcome** in the development plan (P5.x evidence) and the session handoff.

## Self-review

- Spec coverage: configuration and scope → Task 1, 2, 3; record fields and rules → Task 4; validation, repair, rendering, artifacts → Tasks 5, 6; rollout items 1–3 → Tasks 4, 5, 7; rollout item 4 (executed measurements) is explicitly out of scope.
- Placeholders: none; every step has code or an exact command.
- Consistency: `build_final_disputes <output>`, `append_required_resolutions_to_prompt <prompt> <disputes>`, `validate_final_resolutions <records> <final_canonical> <disputes> <output>`, `describe_resolution_validation_failure <records> <final_canonical> <disputes>`, `validate_final_repair_stability <baseline> <canonical> [resolutions]`, `render_final_findings_markdown <canonical> <output> [resolutions]`, globals `DISPUTE_RESOLUTION_ENABLED`, `FINAL_RESOLUTIONS_OUTPUT`, `FINAL_PROCESSED_RESOLUTIONS_FILE`, `FINAL_DISPUTE_RESOLUTIONS_HEADING`, constant `FINAL_RESOLUTION_CONTRACT_BLOCK` are used with the same names throughout.
