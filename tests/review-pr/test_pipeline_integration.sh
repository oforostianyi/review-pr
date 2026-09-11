#!/usr/bin/env bash

set -euo pipefail

test_dir=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo_root=$(cd -P -- "$test_dir/../.." && pwd -P)
source "$test_dir/lib/assert.sh"

suite_root=$(portable_mktemp_dir review-pr-pipeline)
cleanup_suite() {
    if [[ "${REVIEW_PR_TEST_PRESERVE_TMP:-false}" == true ]]; then
        printf 'Preserved integration fixture: %s\n' "$suite_root" >&2
    else
        rm -rf -- "$suite_root"
    fi
}
trap cleanup_suite EXIT

make_repository() {
    local case_dir=$1
    local origin="$case_dir/origin.git"
    local seed="$case_dir/seed"
    local checkout="$case_dir/review"

    git init --bare --quiet "$origin"
    git init --quiet "$seed"
    git -C "$seed" switch --quiet -c main
    git -C "$seed" config user.name 'Review PR Tests'
    git -C "$seed" config user.email 'review-pr-tests@example.test'
    cp -- "$test_dir/fixtures/repository-base.txt" "$seed/fixture odd [name].txt"
    git -C "$seed" add -- 'fixture odd [name].txt'
    git -C "$seed" commit --quiet -m 'base fixture'
    git -C "$seed" remote add origin "$origin"
    git -C "$seed" push --quiet origin main
    git -C "$seed" push --quiet origin HEAD:refs/heads/stack/base
    git -C "$seed" switch --quiet -c fixture/test
    cp -- "$test_dir/fixtures/repository-head.txt" "$seed/fixture odd [name].txt"
    git -C "$seed" add -- 'fixture odd [name].txt'
    git -C "$seed" commit --quiet -m 'head fixture'
    git -C "$seed" push --quiet origin HEAD:refs/pull/123/head
    git -C "$seed" push --quiet origin HEAD:refs/pull/122/head
    git --git-dir="$origin" symbolic-ref HEAD refs/heads/main
    git clone --quiet --branch main "$origin" "$checkout"
    printf '%s\n' "$checkout"
}

write_config() {
    local config_file=$1
    local checkout=$2
    local reviews=$3
    local max_concurrency=${4:-2}

    jq -n \
        --arg checkout "$checkout" \
        --arg reviews "$reviews" \
        --arg runner "$test_dir/mock-agent-runner.sh" \
        --argjson concurrency "$max_concurrency" \
        '{
            agents: {
                alpha: {label: "Alpha", enabled: true, model: "mock-alpha", effort: "low", timeout_seconds: 2700, runner: $runner},
                beta: {label: "Beta", enabled: true, model: "mock-beta", effort: "medium", runner: $runner}
            },
            reviewers: ["alpha", "beta"],
            synthesizer: "alpha",
            default_repository: "fixture",
            repositories: {
                fixture: {github: "example/repository", checkout: $checkout}
            },
            reviews_directory: $reviews,
            language: "EN",
            finalization: {model: "mock-final", effort: "low"},
            reporting: {comparison_sections: {cross_review: "none", final: "standalone"}},
            status: {mode: "log", color: "never", refresh_interval_seconds: 1, log_interval_seconds: 30, show_pid: false},
            execution: {max_concurrency: $concurrency, retry: {max_attempts: 1, delay_seconds: 0}}
        }' >"$config_file"
}

latest_manifest() {
    local reviews=$1
    find "$reviews" -type f -name '*-manifest.json' ! -name '*rerun*' -print | sort | tail -n 1
}

run_full_success_case() {
    local case_dir="$suite_root/success"
    local reviews="$case_dir/reviews"
    local fake_bin="$case_dir/bin"
    local scenarios="$case_dir/scenarios"
    local capture="$case_dir/captured-prompts"
    local gh_log="$case_dir/gh.log"
    local output="$case_dir/output.txt"
    local checkout
    local config="$case_dir/config.json"
    local manifest
    local report_dir
    local work_dir
    local stem
    local timestamp
    local cross_alpha_checksum
    local gh_calls_before
    local rerun_manifest
    local primary_alpha_prompt
    local alpha_cross_prompt
    local rerun_final_prompt
    local legacy_manifest_temp

    mkdir -p -- "$case_dir" "$reviews" "$fake_bin" "$capture" "$scenarios"
    checkout=$(make_repository "$case_dir")
    export REVIEW_PR_FAKE_REFERENCE_SHA
    REVIEW_PR_FAKE_REFERENCE_SHA=$(git -C "$checkout" rev-parse main)
    export REVIEW_PR_FAKE_PULL_HEAD_SHA
    REVIEW_PR_FAKE_PULL_HEAD_SHA=$(git --git-dir="$case_dir/origin.git" rev-parse refs/pull/122/head)
    export REVIEW_PR_FAKE_BASE_REF=main
    export REVIEW_PR_FAKE_DEFAULT_BRANCH=main
    unset REVIEW_PR_FAKE_DEFAULT_BRANCH_FAILURE
    export REVIEW_PR_FAKE_PR_BODY="Depends on #122 and commit ${REVIEW_PR_FAKE_REFERENCE_SHA}."
    write_config "$config" "$checkout" "$reviews" 2
    ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"
    : >"$gh_log"

    PATH="$fake_bin:$PATH" \
        REVIEW_PR_FAKE_GH_LOG="$gh_log" \
        REVIEW_PR_MOCK_CAPTURE_DIR="$capture" \
        "$repo_root/bin/review-pr" --config "$config" 123 >"$output" 2>"$case_dir/stderr.log"

    manifest=$(latest_manifest "$reviews")
    assert_file_exists "$manifest" 'full mock pipeline writes a manifest'
    assert_eq 'complete' "$(jq -r '.status.pipeline' "$manifest")" 'full mock pipeline reaches complete status'
    assert_eq 'complete' "$(jq -r '.status.comparison' "$manifest")" 'standalone comparison reaches complete status'
    assert_eq '2700' "$(jq -r '.execution.agent_timeout_seconds.alpha' "$manifest")" \
        'manifest records the configured per-agent timeout'
    assert_eq '0' "$(jq -r '.execution.agent_timeout_seconds.beta' "$manifest")" \
        'manifest records a disabled timeout explicitly'

    work_dir=${manifest%/*}
    report_dir=${work_dir%/*}
    stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")
    timestamp=$(jq -r '.timestamp' "$manifest")
    assert_file_exists "$report_dir/${stem}-final.md" 'final core report remains in the review directory root'
    assert_file_exists "$report_dir/${stem}-comparison.md" 'comparison report remains in the review directory root'
    assert_file_exists "$work_dir/${stem}-alpha.md" 'primary artifacts are kept under work/'
    assert_file_exists "$work_dir/${stem}-cross-beta.md" 'cross-review artifacts are kept under work/'
    assert_file_exists "$work_dir/${stem}-repo-facts.json" 'machine-readable repository facts are preserved under work/'
    assert_file_exists "$work_dir/${stem}-repo-facts.md" 'model-facing repository facts are preserved under work/'
    assert_eq 'main' "$(jq -r '.repository.default_branch' "$work_dir/${stem}-repo-facts.json")" \
        'repository facts resolve the actual default branch'
    assert_eq 'false' "$(jq -r '.pull_request.stacked_by_base_branch' "$work_dir/${stem}-repo-facts.json")" \
        'repository facts distinguish a default-branch PR from a stacked PR'
    assert_eq 'true' "$(jq -r '.description_references[] | select(.kind == "pull_request") | .github.merged' "$work_dir/${stem}-repo-facts.json")" \
        'repository facts retain the referenced PR GitHub merged state as context'
    assert_eq 'false' "$(jq -r '.description_references[] | select(.kind == "pull_request") | .ancestry_on_current_default.value' "$work_dir/${stem}-repo-facts.json")" \
        'GitHub merged state is not treated as proof of default-branch ancestry'
    assert_eq 'true' "$(jq -r '.description_references[] | select(.kind == "commit") | .ancestry_on_current_default.value' "$work_dir/${stem}-repo-facts.json")" \
        'referenced commit ancestry is measured independently'
    assert_eq 'fixture odd [name].txt' "$(jq -r '.diff.files[0]' "$work_dir/${stem}-repo-facts.json")" \
        'changed-file collection preserves spaces and shell metacharacters'
    assert_eq "${stem}-repo-facts.json" "$(jq -r '.artifacts.repository_facts.json' "$manifest")" \
        'manifest records the repository-facts JSON artifact'
    assert_file_contains "$work_dir/${stem}-alpha.md" '| **Model** | `mock-alpha` |' \
        'primary report records the producing model'

    primary_alpha_prompt="$capture/primary-review-alpha-attempt-1.prompt"
    assert_file_contains "$primary_alpha_prompt" '===== BEGIN AUTHORITATIVE REPOSITORY FACTS =====' \
        'primary reviewers receive the shared facts snapshot'
    assert_file_contains "$primary_alpha_prompt" 'Database-migration verification rule:' \
        'primary reviewers receive the migration certainty rule'
    assert_file_contains "$primary_alpha_prompt" 'Existing-feedback rule:' \
        'primary reviewers receive the duplicate-feedback rule'

    alpha_cross_prompt="$capture/cross-review-alpha-attempt-1.prompt"
    assert_file_contains "$alpha_cross_prompt" "${stem}-beta.md" \
        'cross-review receives the other primary report'
    assert_false 'cross-review does not receive its own primary report' \
        grep -Fq -- "${stem}-alpha.md" "$alpha_cross_prompt"
    assert_file_contains "$alpha_cross_prompt" '===== BEGIN AUTHORITATIVE REPOSITORY FACTS =====' \
        'cross-reviewers receive the same shared facts snapshot'
    assert_file_contains "$alpha_cross_prompt" 'Database-migration verification rule:' \
        'cross-reviewers receive the migration certainty rule'
    assert_file_contains "$alpha_cross_prompt" 'Existing-feedback rule:' \
        'cross-reviewers receive the duplicate-feedback rule'
    assert_file_contains "$capture/final-synthesis-alpha-attempt-1.prompt" \
        'Database-migration verification rule:' \
        'final synthesizer receives the migration certainty rule'
    assert_file_contains "$capture/final-synthesis-alpha-attempt-1.prompt" \
        'Existing-feedback rule:' \
        'final synthesizer receives the duplicate-feedback rule'

    cross_alpha_checksum=$(cksum "$work_dir/${stem}-cross-alpha.md")
    gh_calls_before=$(wc -l <"$gh_log")
    PATH="$fake_bin:$PATH" \
        REVIEW_PR_FAKE_GH_LOG="$gh_log" \
        REVIEW_PR_MOCK_CAPTURE_DIR="$capture" \
        "$repo_root/bin/review-pr" --config "$config" --rerun-final --run "$timestamp" 123 \
        >"$case_dir/rerun-output.txt" 2>"$case_dir/rerun-stderr.log"
    assert_eq "$cross_alpha_checksum" "$(cksum "$work_dir/${stem}-cross-alpha.md")" \
        'artifact-only final rerun does not overwrite a source cross-review'
    assert_eq "$gh_calls_before" "$(wc -l <"$gh_log")" \
        'artifact-only final rerun performs no GitHub calls'
    rerun_final_prompt=$(find "$capture" -type f -name 'final-synthesis-alpha-attempt-1.prompt' -print | sort | tail -n 1)
    assert_file_contains "$rerun_final_prompt" '===== BEGIN AUTHORITATIVE REPOSITORY FACTS =====' \
        'artifact-only final rerun reuses preserved repository facts'
    rerun_manifest=$(find "$work_dir" -type f -name '*-final-rerun-*-manifest.json' -print | sed -n '1p')
    [[ -n "$rerun_manifest" ]] || fail 'artifact-only final rerun did not create a separate manifest'
    pass 'artifact-only final rerun creates a separate manifest'

    legacy_manifest_temp="${manifest}.legacy.tmp"
    jq 'del(.artifacts.repository_facts, .artifacts.changed_lines)' "$manifest" >"$legacy_manifest_temp"
    mv -- "$legacy_manifest_temp" "$manifest"
    gh_calls_before=$(wc -l <"$gh_log")
    sleep 1
    PATH="$fake_bin:$PATH" \
        REVIEW_PR_FAKE_GH_LOG="$gh_log" \
        REVIEW_PR_MOCK_CAPTURE_DIR="$capture" \
        "$repo_root/bin/review-pr" --config "$config" --rerun-final --run "$timestamp" 123 \
        >"$case_dir/legacy-rerun-output.txt" 2>"$case_dir/legacy-rerun-stderr.log"
    assert_eq "$gh_calls_before" "$(wc -l <"$gh_log")" \
        'historical manifest without repository facts remains artifact-only'
    assert_file_contains "$capture/final-synthesis-alpha-attempt-1.prompt" \
        'AUTHORITATIVE REPOSITORY FACTS UNAVAILABLE' \
        'historical manifest without facts gives the finalizer an explicit unknown-facts contract'
    assert_file_contains "$capture/final-synthesis-alpha-attempt-1.prompt" \
        'RIGHT-SIDE CHANGED-LINE MAP UNAVAILABLE' \
        'historical manifest without a line map makes anchor validation limits explicit'
}

run_resume_case() {
    local case_dir="$suite_root/resume"
    local reviews="$case_dir/reviews"
    local fake_bin="$case_dir/bin"
    local scenarios="$case_dir/scenarios"
    local checkout
    local config="$case_dir/config.json"
    local manifest
    local work_dir
    local stem
    local timestamp
    local alpha_checksum

    mkdir -p -- "$case_dir" "$reviews" "$fake_bin" "$scenarios"
    checkout=$(make_repository "$case_dir")
    export REVIEW_PR_FAKE_REFERENCE_SHA
    REVIEW_PR_FAKE_REFERENCE_SHA=$(git -C "$checkout" rev-parse main)
    export REVIEW_PR_FAKE_PULL_HEAD_SHA
    REVIEW_PR_FAKE_PULL_HEAD_SHA=$(git --git-dir="$case_dir/origin.git" rev-parse refs/pull/122/head)
    export REVIEW_PR_FAKE_BASE_REF=stack/base
    export REVIEW_PR_FAKE_DEFAULT_BRANCH=main
    unset REVIEW_PR_FAKE_DEFAULT_BRANCH_FAILURE
    export REVIEW_PR_FAKE_PR_BODY="Depends on #122 and commit ${REVIEW_PR_FAKE_REFERENCE_SHA}."
    write_config "$config" "$checkout" "$reviews" 2
    ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"
    printf 'nonzero\n' >"$scenarios/beta-cross-review"

    if PATH="$fake_bin:$PATH" REVIEW_PR_MOCK_SCENARIO_DIR="$scenarios" \
        "$repo_root/bin/review-pr" --config "$config" 123 \
        >"$case_dir/first-output.txt" 2>"$case_dir/first-stderr.log"; then
        fail 'pipeline with a failed cross-review must stop before synthesis'
    fi
    pass 'pipeline stops when one cross-review fails'

    manifest=$(latest_manifest "$reviews")
    work_dir=${manifest%/*}
    stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")
    timestamp=$(jq -r '.timestamp' "$manifest")
    assert_eq 'true' "$(jq -r '.pull_request.stacked_by_base_branch' "$work_dir/${stem}-repo-facts.json")" \
        'repository facts identify a PR whose configured base differs from the default branch as stacked'
    alpha_checksum=$(cksum "$work_dir/${stem}-cross-alpha.md")
    assert_file_not_exists "$work_dir/${stem}-cross-beta.md" 'failed cross-review has no canonical artifact'

    rm -- "$scenarios/beta-cross-review"
    PATH="$fake_bin:$PATH" REVIEW_PR_MOCK_SCENARIO_DIR="$scenarios" \
        "$repo_root/bin/review-pr" --config "$config" --run "$timestamp" 123 \
        >"$case_dir/resume-output.txt" 2>"$case_dir/resume-stderr.log"
    assert_eq "$alpha_checksum" "$(cksum "$work_dir/${stem}-cross-alpha.md")" \
        'resume keeps an already successful cross-review byte-for-byte'
    assert_file_exists "$work_dir/${stem}-cross-beta.md" 'resume reruns only the missing cross-review'
    assert_eq 'complete' "$(jq -r '.status.pipeline' "$manifest")" 'resumed pipeline completes synthesis'
    assert_eq 'complete' "$(jq -r '.agent_status.cross_review.alpha' "$manifest")" \
        'resume preserves the manifest status of an agent that was not rerun'
    assert_eq '1' "$(jq -r '.attempts.cross_review.alpha' "$manifest")" \
        'resume preserves the attempt count of an agent that was not rerun'
    assert_eq 'complete' "$(jq -r '.agent_status.cross_review.beta' "$manifest")" \
        'resume records the rerun agent as complete'
}

run_comparison_failure_case() {
    local case_dir="$suite_root/comparison-failure"
    local reviews="$case_dir/reviews"
    local fake_bin="$case_dir/bin"
    local scenarios="$case_dir/scenarios"
    local checkout
    local config="$case_dir/config.json"
    local manifest
    local work_dir
    local report_dir
    local stem
    local invalid_comparison

    mkdir -p -- "$case_dir" "$reviews" "$fake_bin" "$scenarios"
    checkout=$(make_repository "$case_dir")
    export REVIEW_PR_FAKE_REFERENCE_SHA
    REVIEW_PR_FAKE_REFERENCE_SHA=$(git -C "$checkout" rev-parse main)
    export REVIEW_PR_FAKE_PULL_HEAD_SHA
    REVIEW_PR_FAKE_PULL_HEAD_SHA=$(git --git-dir="$case_dir/origin.git" rev-parse refs/pull/122/head)
    export REVIEW_PR_FAKE_BASE_REF=main
    export REVIEW_PR_FAKE_DEFAULT_BRANCH=main
    unset REVIEW_PR_FAKE_DEFAULT_BRANCH_FAILURE
    export REVIEW_PR_FAKE_PR_BODY='Unknown dependency #999.'
    write_config "$config" "$checkout" "$reviews" 2
    ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"
    printf 'malformed-comparison\n' >"$scenarios/alpha-comparison-synthesis"

    if PATH="$fake_bin:$PATH" REVIEW_PR_MOCK_SCENARIO_DIR="$scenarios" \
        "$repo_root/bin/review-pr" --config "$config" 123 \
        >"$case_dir/output.txt" 2>"$case_dir/stderr.log"; then
        fail 'malformed standalone comparison must fail the overall run'
    fi
    pass 'malformed standalone comparison fails after its bounded repair pass'

    manifest=$(latest_manifest "$reviews")
    work_dir=${manifest%/*}
    report_dir=${work_dir%/*}
    stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")
    assert_eq 'complete_with_unknowns' "$(jq -r '.status' "$work_dir/${stem}-repo-facts.json")" \
        'an unresolved description reference is recorded without aborting otherwise valid fact collection'
    assert_eq 'unknown' "$(jq -r '.description_references[0].resolution_status' "$work_dir/${stem}-repo-facts.json")" \
        'unresolvable references remain explicit unknowns'
    assert_file_exists "$report_dir/${stem}-final.md" \
        'comparison failure preserves the valid core final report'
    assert_file_not_exists "$report_dir/${stem}-comparison.md" \
        'malformed comparison never becomes a canonical report'
    invalid_comparison=$(find "$work_dir" -type f -name '*comparison-error-invalid.md' -print | sed -n '1p')
    [[ -n "$invalid_comparison" ]] || fail 'malformed repair output was not preserved'
    pass 'malformed repair output is preserved as a diagnostic artifact'
    assert_eq 'failed' "$(jq -r '.status.comparison' "$manifest")" \
        'manifest records comparison failure separately from final synthesis'
    assert_eq 'complete' "$(jq -r '.status.final' "$manifest")" \
        'manifest keeps final synthesis complete when comparison fails'
}

run_interrupt_case() {
    local case_dir="$suite_root/interrupt"
    local reviews="$case_dir/reviews"
    local fake_bin="$case_dir/bin"
    local scenarios="$case_dir/scenarios"
    local events="$case_dir/events.log"
    local checkout
    local config="$case_dir/config.json"
    local pid
    local attempts=0
    local canonical_primary
    local temp_artifact

    mkdir -p -- "$case_dir" "$reviews" "$fake_bin" "$scenarios"
    checkout=$(make_repository "$case_dir")
    export REVIEW_PR_FAKE_REFERENCE_SHA
    REVIEW_PR_FAKE_REFERENCE_SHA=$(git -C "$checkout" rev-parse main)
    export REVIEW_PR_FAKE_PULL_HEAD_SHA
    REVIEW_PR_FAKE_PULL_HEAD_SHA=$(git --git-dir="$case_dir/origin.git" rev-parse refs/pull/122/head)
    export REVIEW_PR_FAKE_BASE_REF=main
    export REVIEW_PR_FAKE_DEFAULT_BRANCH=main
    unset REVIEW_PR_FAKE_DEFAULT_BRANCH_FAILURE
    export REVIEW_PR_FAKE_PR_BODY="Depends on #122 and commit ${REVIEW_PR_FAKE_REFERENCE_SHA}."
    write_config "$config" "$checkout" "$reviews" 2
    ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"
    printf 'hang\n' >"$scenarios/alpha-primary-review"
    printf 'hang\n' >"$scenarios/beta-primary-review"
    : >"$events"

    PATH="$fake_bin:$PATH" \
        REVIEW_PR_MOCK_SCENARIO_DIR="$scenarios" \
        REVIEW_PR_MOCK_EVENT_LOG="$events" \
        "$repo_root/bin/review-pr" --config "$config" 123 \
        >"$case_dir/output.txt" 2>"$case_dir/stderr.log" &
    pid=$!

    while ! grep -q '^start' "$events"; do
        attempts=$((attempts + 1))
        if (( attempts > 100 )); then
            kill -TERM "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            fail 'interrupted-run fixture did not start an agent'
        fi
        sleep 0.05
    done
    kill -TERM "$pid"
    if wait "$pid"; then
        fail 'terminated pipeline unexpectedly exited successfully'
    fi
    pass 'SIGTERM interrupts the pipeline with a non-zero status'

    canonical_primary=$(find "$reviews" -type f -name '*-alpha.md' -print | sed -n '1p')
    [[ -z "$canonical_primary" ]] || fail 'interrupted runner published a partial canonical report'
    pass 'interrupted runner does not publish partial canonical reports'
    temp_artifact=$(find "$reviews" -type f -name '*.tmp.*' -print | sed -n '1p')
    [[ -z "$temp_artifact" ]] || fail "interrupted run left temporary artifact ${temp_artifact}"
    pass 'termination cleanup removes temporary artifacts'
}

run_facts_collection_failure_case() {
    local case_dir="$suite_root/facts-failure"
    local reviews="$case_dir/reviews"
    local fake_bin="$case_dir/bin"
    local events="$case_dir/events.log"
    local checkout
    local config="$case_dir/config.json"
    local canonical_facts
    local temp_facts

    mkdir -p -- "$case_dir" "$reviews" "$fake_bin"
    checkout=$(make_repository "$case_dir")
    write_config "$config" "$checkout" "$reviews" 2
    ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"
    : >"$events"

    if PATH="$fake_bin:$PATH" \
        REVIEW_PR_FAKE_DEFAULT_BRANCH_FAILURE=true \
        REVIEW_PR_MOCK_EVENT_LOG="$events" \
        "$repo_root/bin/review-pr" --config "$config" 123 \
        >"$case_dir/output.txt" 2>"$case_dir/stderr.log"; then
        fail 'default-branch lookup failure must stop fact collection'
    fi
    pass 'repository-facts collection failure is visible'
    assert_file_contains "$case_dir/stderr.log" 'could not determine the default branch' \
        'repository-facts failure identifies the failed measurement'
    canonical_facts=$(find "$reviews" -type f \( -name '*-repo-facts.json' -o -name '*-repo-facts.md' \) -print | sed -n '1p')
    [[ -z "$canonical_facts" ]] || fail "failed collection published a partial canonical artifact: ${canonical_facts}"
    pass 'failed repository-facts collection publishes no canonical facts artifact'
    temp_facts=$(find "$reviews" -type f -name '*repo-facts*.tmp.*' -print | sed -n '1p')
    [[ -z "$temp_facts" ]] || fail "failed collection left temporary facts artifact: ${temp_facts}"
    pass 'failed repository-facts collection cleans up temporary artifacts'
    assert_eq '0' "$(wc -l <"$events" | tr -d ' ')" \
        'agents do not start when authoritative fact collection fails'
}

run_anchor_repair_case() {
    local case_dir="$suite_root/anchor-repair"
    local reviews="$case_dir/reviews"
    local fake_bin="$case_dir/bin"
    local scenarios="$case_dir/scenarios"
    local capture="$case_dir/captured-prompts"
    local checkout
    local config="$case_dir/config.json"
    local config_temp="$case_dir/config.tmp.json"
    local manifest
    local work_dir
    local report_dir
    local stem
    local invalid_draft

    mkdir -p -- "$case_dir" "$reviews" "$fake_bin" "$scenarios" "$capture"
    checkout=$(make_repository "$case_dir")
    export REVIEW_PR_FAKE_REFERENCE_SHA
    REVIEW_PR_FAKE_REFERENCE_SHA=$(git -C "$checkout" rev-parse main)
    export REVIEW_PR_FAKE_PULL_HEAD_SHA
    REVIEW_PR_FAKE_PULL_HEAD_SHA=$(git --git-dir="$case_dir/origin.git" rev-parse refs/pull/122/head)
    export REVIEW_PR_FAKE_BASE_REF=main
    export REVIEW_PR_FAKE_DEFAULT_BRANCH=main
    unset REVIEW_PR_FAKE_DEFAULT_BRANCH_FAILURE
    export REVIEW_PR_FAKE_PR_BODY='Fixture anchor repair.'
    write_config "$config" "$checkout" "$reviews" 2
    jq '.reporting.comparison_sections.final = "none"' "$config" >"$config_temp"
    mv -- "$config_temp" "$config"
    ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"
    printf 'repair-anchor\n' >"$scenarios/alpha-final-synthesis"

    PATH="$fake_bin:$PATH" \
        REVIEW_PR_MOCK_SCENARIO_DIR="$scenarios" \
        REVIEW_PR_MOCK_CAPTURE_DIR="$capture" \
        "$repo_root/bin/review-pr" --config "$config" 123 \
        >"$case_dir/output.txt" 2>"$case_dir/stderr.log"

    manifest=$(latest_manifest "$reviews")
    work_dir=${manifest%/*}
    report_dir=${work_dir%/*}
    stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")
    assert_file_exists "$work_dir/${stem}-changed-lines.json" \
        'full run publishes the exact changed-line map'
    assert_eq 'true' "$(jq -r '.files[] | select(.path == "fixture odd [name].txt") | any(.right_side_ranges[]; .start <= 1 and .end >= 1)' "$work_dir/${stem}-changed-lines.json")" \
        'integration map contains the actual modified RIGHT-side line'
    assert_file_exists "$report_dir/${stem}-final.md" \
        'bounded anchor repair can publish an otherwise unchanged valid final report'
    assert_file_contains "$report_dir/${stem}-final.md" 'Line: `1`' \
        'anchor repair selects a line present in the exact map'
    invalid_draft=$(find "$work_dir" -type f -name '*anchor-invalid-draft.md' -print | sed -n '1p')
    [[ -n "$invalid_draft" ]] || fail 'invalid pre-repair anchor draft was not preserved'
    pass 'invalid pre-repair anchor draft is preserved for diagnosis'
    assert_file_contains "$invalid_draft" 'Line: `99`' \
        'diagnostic draft retains the rejected line'
    assert_eq 'complete' "$(jq -r '.status' "$work_dir/${stem}-final-anchor-validation.json")" \
        'successful repair publishes complete anchor validation'
    assert_eq '2' "$(jq -r '.passes | length' "$work_dir/${stem}-final-usage.json")" \
        'final usage includes synthesis and bounded anchor-repair passes'
    assert_eq "${stem}-changed-lines.json" "$(jq -r '.artifacts.changed_lines' "$manifest")" \
        'manifest records the exact changed-line map'
    assert_eq "${stem}-final-anchor-validation.json" "$(jq -r '.artifacts.final_anchor_validation' "$manifest")" \
        'manifest records final anchor validation'
    assert_file_contains "$capture/final-synthesis-alpha-attempt-1.prompt" \
        'BEGIN RIGHT-SIDE CHANGED-LINE MAP' \
        'repair prompt receives the authoritative map'
}

run_unsafe_anchor_repair_case() {
    local case_dir="$suite_root/unsafe-anchor-repair"
    local reviews="$case_dir/reviews"
    local fake_bin="$case_dir/bin"
    local scenarios="$case_dir/scenarios"
    local checkout
    local config="$case_dir/config.json"
    local config_temp="$case_dir/config.tmp.json"
    local manifest
    local work_dir
    local report_dir
    local stem
    local failed_validation
    local timestamp

    mkdir -p -- "$case_dir" "$reviews" "$fake_bin" "$scenarios"
    checkout=$(make_repository "$case_dir")
    export REVIEW_PR_FAKE_REFERENCE_SHA
    REVIEW_PR_FAKE_REFERENCE_SHA=$(git -C "$checkout" rev-parse main)
    export REVIEW_PR_FAKE_PULL_HEAD_SHA
    REVIEW_PR_FAKE_PULL_HEAD_SHA=$(git --git-dir="$case_dir/origin.git" rev-parse refs/pull/122/head)
    export REVIEW_PR_FAKE_BASE_REF=main
    export REVIEW_PR_FAKE_DEFAULT_BRANCH=main
    unset REVIEW_PR_FAKE_DEFAULT_BRANCH_FAILURE
    export REVIEW_PR_FAKE_PR_BODY='Fixture unsafe anchor repair.'
    write_config "$config" "$checkout" "$reviews" 2
    jq '.reporting.comparison_sections.final = "none"' "$config" >"$config_temp"
    mv -- "$config_temp" "$config"
    ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"
    printf 'unsafe-anchor-repair\n' >"$scenarios/alpha-final-synthesis"

    if PATH="$fake_bin:$PATH" REVIEW_PR_MOCK_SCENARIO_DIR="$scenarios" \
        "$repo_root/bin/review-pr" --config "$config" 123 \
        >"$case_dir/output.txt" 2>"$case_dir/stderr.log"; then
        fail 'anchor repair that rewrites substantive content must fail'
    fi
    pass 'unsafe anchor repair is rejected'

    manifest=$(latest_manifest "$reviews")
    work_dir=${manifest%/*}
    report_dir=${work_dir%/*}
    stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")
    assert_file_not_exists "$report_dir/${stem}-final.md" \
        'unsafe repair cannot publish a canonical final report'
    assert_file_not_exists "$work_dir/${stem}-final-anchor-validation.json" \
        'failed repair does not reserve the canonical validation artifact needed by a retry'
    failed_validation=$(find "$work_dir" -type f -name '*-final-error*-anchor-validation.json' -print | sed -n '1p')
    [[ -n "$failed_validation" ]] || fail 'failed repair did not preserve machine-readable anchor diagnostics'
    pass 'failed repair keeps attempt-scoped machine-readable anchor diagnostics'
    assert_eq 'invalid' "$(jq -r '.status' "$failed_validation")" \
        'failed repair diagnostics preserve the original invalid status'
    assert_file_contains "$case_dir/stderr.log" 'repair attempted to change non-anchor report content' \
        'unsafe repair failure explains the byte-stability violation'

    timestamp=$(jq -r '.timestamp' "$manifest")
    printf 'repair-anchor\n' >"$scenarios/alpha-final-synthesis"
    PATH="$fake_bin:$PATH" REVIEW_PR_MOCK_SCENARIO_DIR="$scenarios" \
        "$repo_root/bin/review-pr" --config "$config" --run "$timestamp" 123 \
        >"$case_dir/resume-output.txt" 2>"$case_dir/resume-stderr.log"
    assert_file_exists "$report_dir/${stem}-final.md" \
        'resume can publish the final report after a failed anchor repair'
    assert_eq 'complete' "$(jq -r '.status' "$work_dir/${stem}-final-anchor-validation.json")" \
        'resume publishes the canonical validation artifact after the failed attempt diagnostic'
}

run_ndjson_primary_case() {
    local case_dir="$suite_root/ndjson-primary"
    local reviews="$case_dir/reviews"
    local fake_bin="$case_dir/bin"
    local capture="$case_dir/captured-prompts"
    local checkout
    local config="$case_dir/config.json"
    local config_temp="$case_dir/config.tmp.json"
    local manifest
    local work_dir
    local stem
    local alpha_raw
    local alpha_findings
    local alpha_report
    local alpha_cross_prompt

    mkdir -p -- "$case_dir" "$reviews" "$fake_bin" "$capture"
    checkout=$(make_repository "$case_dir")
    export REVIEW_PR_FAKE_REFERENCE_SHA
    REVIEW_PR_FAKE_REFERENCE_SHA=$(git -C "$checkout" rev-parse main)
    export REVIEW_PR_FAKE_PULL_HEAD_SHA
    REVIEW_PR_FAKE_PULL_HEAD_SHA=$(git --git-dir="$case_dir/origin.git" rev-parse refs/pull/122/head)
    export REVIEW_PR_FAKE_BASE_REF=main
    export REVIEW_PR_FAKE_DEFAULT_BRANCH=main
    unset REVIEW_PR_FAKE_DEFAULT_BRANCH_FAILURE
    export REVIEW_PR_FAKE_PR_BODY='Fixture structured primary review.'
    write_config "$config" "$checkout" "$reviews" 2
    jq '.reporting.finding_contract = {primary: "ndjson-v1"} | .reporting.comparison_sections.final = "none"' \
        "$config" >"$config_temp"
    mv -- "$config_temp" "$config"
    ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"

    PATH="$fake_bin:$PATH" \
        REVIEW_PR_MOCK_BEHAVIOR=valid-ndjson \
        REVIEW_PR_MOCK_CAPTURE_DIR="$capture" \
        "$repo_root/bin/review-pr" --config "$config" 123 \
        >"$case_dir/output.txt" 2>"$case_dir/stderr.log"

    manifest=$(latest_manifest "$reviews")
    work_dir=${manifest%/*}
    stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")
    alpha_raw="$work_dir/${stem}-alpha-raw.ndjson"
    alpha_findings="$work_dir/${stem}-alpha-findings.json"
    alpha_report="$work_dir/${stem}-alpha.md"
    alpha_cross_prompt="$capture/cross-review-alpha-attempt-1.prompt"

    assert_eq 'ndjson-v1' "$(jq -r '.reporting.finding_contract.primary' "$manifest")" \
        'manifest records the opt-in primary finding contract'
    assert_file_exists "$alpha_raw" 'structured primary run preserves the raw NDJSON response'
    assert_file_exists "$alpha_findings" 'structured primary run publishes canonical findings JSON'
    assert_file_exists "$alpha_report" 'structured primary run still publishes readable Markdown'
    assert_eq 'ndjson-v1' "$(jq -r '.contract' "$alpha_findings")" \
        'canonical findings identify their contract version'
    assert_eq 'alpha' "$(jq -r '.agent' "$alpha_findings")" \
        'canonical findings retain the producing agent identity'
    assert_eq "${stem}-alpha-raw.ndjson" "$(jq -r '.artifacts.primary_raw.alpha' "$manifest")" \
        'manifest points to the raw primary response'
    assert_eq "${stem}-alpha-findings.json" "$(jq -r '.artifacts.primary_findings.alpha' "$manifest")" \
        'manifest points to canonical primary findings'
    assert_file_contains "$alpha_report" '### [P1] Fixture changed-line defect' \
        'deterministic renderer creates the readable finding'
    assert_file_contains "$capture/primary-review-alpha-attempt-1.prompt" 'BEGIN RIGHT-SIDE CHANGED-LINE MAP' \
        'structured primary prompt receives the authoritative changed-line map'
    assert_file_contains "$capture/primary-review-alpha-attempt-1.prompt" 'Output contract: ndjson-v1' \
        'structured primary prompt requests the machine contract explicitly'
    assert_file_contains "$capture/primary-review-alpha-attempt-1.prompt" 'Use pr-level for a finding about code the change affects but does not touch' \
        'structured primary prompt allows anchoring consumer, flow, and coverage findings at PR level'
    assert_false 'structured primary prompt no longer restricts pr-level anchors to PR-wide omissions' \
        grep -Fq -- 'Use pr-level only for a genuine PR-wide omission' "$capture/primary-review-alpha-attempt-1.prompt"
    assert_file_contains "$alpha_cross_prompt" 'Fixture changed-line defect' \
        'cross-review receives rendered primary content'
    assert_false 'cross-review does not receive raw NDJSON transport records' \
        grep -Fq -- '"record":"finding"' "$alpha_cross_prompt"
}

run_ndjson_cross_case() {
    local case_dir="$suite_root/ndjson-cross"
    local reviews="$case_dir/reviews"
    local fake_bin="$case_dir/bin"
    local scenarios="$case_dir/scenarios"
    local capture="$case_dir/captured-prompts"
    local checkout
    local config="$case_dir/config.json"
    local config_temp="$case_dir/config.tmp.json"
    local manifest work_dir stem timestamp alpha_raw alpha_findings alpha_report alpha_prompt final_raw final_findings final_report final_prompt rerun_manifest

    mkdir -p -- "$case_dir" "$reviews" "$fake_bin" "$capture" "$scenarios"
    checkout=$(make_repository "$case_dir")
    export REVIEW_PR_FAKE_REFERENCE_SHA
    REVIEW_PR_FAKE_REFERENCE_SHA=$(git -C "$checkout" rev-parse main)
    export REVIEW_PR_FAKE_PULL_HEAD_SHA
    REVIEW_PR_FAKE_PULL_HEAD_SHA=$(git --git-dir="$case_dir/origin.git" rev-parse refs/pull/122/head)
    export REVIEW_PR_FAKE_BASE_REF=main
    export REVIEW_PR_FAKE_DEFAULT_BRANCH=main
    unset REVIEW_PR_FAKE_DEFAULT_BRANCH_FAILURE
    export REVIEW_PR_FAKE_PR_BODY='Fixture structured cross-review.'
    write_config "$config" "$checkout" "$reviews" 2
    jq '.reporting.finding_contract = {primary: "ndjson-v1", cross_review: "ndjson-v1", final: "ndjson-v1"} |
        .reporting.comparison_sections = {cross_review: "none", final: "none"}' \
        "$config" >"$config_temp"
    mv -- "$config_temp" "$config"
    ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"
    printf '%s\n' cross-ndjson-preamble >"$scenarios/beta-cross-review"
    printf '%s\n' valid-ndjson >"$scenarios/beta-cross-review-findings-repair"
    printf '%s\n' final-ndjson-preamble >"$scenarios/alpha-final-synthesis"
    printf '%s\n' valid-ndjson >"$scenarios/alpha-final-findings-repair"

    PATH="$fake_bin:$PATH" \
        REVIEW_PR_MOCK_BEHAVIOR=valid-ndjson \
        REVIEW_PR_MOCK_SCENARIO_DIR="$scenarios" \
        REVIEW_PR_MOCK_CAPTURE_DIR="$capture" \
        "$repo_root/bin/review-pr" --config "$config" 123 \
        >"$case_dir/output.txt" 2>"$case_dir/stderr.log"

    manifest=$(latest_manifest "$reviews")
    work_dir=${manifest%/*}
    stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")
    timestamp=$(jq -r '.timestamp' "$manifest")
    alpha_raw="$work_dir/${stem}-cross-alpha-raw.ndjson"
    alpha_findings="$work_dir/${stem}-cross-alpha-findings.json"
    alpha_report="$work_dir/${stem}-cross-alpha.md"
    alpha_prompt="$capture/cross-review-alpha-attempt-1.prompt"
    final_raw="$work_dir/${stem}-final-raw.ndjson"
    final_findings="$work_dir/${stem}-final-findings.json"
    final_report="${work_dir%/work}/${stem}-final.md"
    final_prompt="$capture/final-synthesis-alpha-attempt-1.prompt"

    assert_eq complete "$(jq -r '.status.pipeline' "$manifest")" \
        'structured cross-review pipeline completes'
    assert_eq ndjson-v1 "$(jq -r '.reporting.finding_contract.cross_review' "$manifest")" \
        'manifest records the cross-review finding contract'
    assert_file_exists "$alpha_raw" 'structured cross-review preserves exact raw NDJSON'
    assert_file_exists "$alpha_findings" 'structured cross-review publishes canonical findings JSON'
    assert_file_exists "$alpha_report" 'structured cross-review publishes deterministic Markdown'
    assert_eq 'cross-review' "$(jq -r '.phase' "$alpha_findings")" \
        'cross-review sidecar records its phase'
    assert_eq 'beta:beta:F-001' "$(jq -r '.input_refs[0] | .agent + ":" + .source_id' "$alpha_findings")" \
        'cross-review sidecar preserves namespaced primary provenance'
    assert_eq "${stem}-cross-alpha-raw.ndjson" "$(jq -r '.artifacts.cross_review_raw.alpha' "$manifest")" \
        'manifest points to cross-review raw output'
    assert_eq "${stem}-cross-alpha-findings.json" "$(jq -r '.artifacts.cross_review_findings.alpha' "$manifest")" \
        'manifest points to canonical cross-review findings'
    assert_file_contains "$alpha_report" '### [CONFIRMED/P1] Fixture changed-line defect' \
        'cross-review Markdown is rendered from canonical classifications'
    assert_file_contains "$alpha_prompt" '"source_id": "beta:F-001"' \
        'structured cross-review receives the other canonical primary report'
    assert_false 'structured cross-review does not receive its own canonical primary report' \
        grep -Fq -- '"source_id": "alpha:F-001"' "$alpha_prompt"
    assert_file_contains "$alpha_prompt" 'BEGIN RIGHT-SIDE CHANGED-LINE MAP' \
        'structured cross-review receives the authoritative changed-line map'
    assert_eq '2' "$(jq -r '.passes | length' "$work_dir/${stem}-cross-beta-usage.json")" \
        'structured cross-review usage includes generation and bounded repair passes'
    assert_file_exists "$work_dir/${stem}-cross-beta-error-schema-repair-attempt-1-source-raw.ndjson" \
        'structured cross-review repair preserves original invalid response'
    assert_eq ndjson-v1 "$(jq -r '.reporting.finding_contract.final' "$manifest")" \
        'manifest records the final-synthesis finding contract'
    assert_file_exists "$final_raw" 'structured final synthesis preserves exact raw NDJSON'
    assert_file_exists "$final_findings" 'structured final synthesis publishes canonical findings JSON'
    assert_file_exists "$final_report" 'structured final synthesis publishes deterministic Markdown in the report root'
    assert_eq final-synthesis "$(jq -r '.phase' "$final_findings")" \
        'final sidecar records its phase'
    assert_eq 'alpha:alpha:F-001,beta:beta:F-001' "$(jq -r '[.findings[0].primary_refs[] | .agent + ":" + .source_id] | join(",")' "$final_findings")" \
        'final sidecar derives transitive primary provenance from cross-review refs'
    assert_eq "${stem}-final-raw.ndjson" "$(jq -r '.artifacts.final_raw' "$manifest")" \
        'manifest points to final raw output'
    assert_eq "${stem}-final-findings.json" "$(jq -r '.artifacts.final_findings' "$manifest")" \
        'manifest points to canonical final findings'
    assert_file_contains "$final_report" '# Code Review: [PR #123]' \
        'deterministic final renderer owns the linked PR header'
    assert_file_contains "$final_report" '<!-- review-pr:anchor:changed-line -->' \
        'deterministic final renderer emits validated anchor markers'
    assert_file_contains "$final_prompt" 'BEGIN CANONICAL CROSS-REVIEW FINDINGS: alpha' \
        'structured final synthesis receives canonical cross-review inputs'
    assert_false 'structured final synthesis does not receive localized cross-review Markdown' \
        grep -Fq -- '### [CONFIRMED/P1]' "$final_prompt"
    assert_file_contains "$final_prompt" '===== BEGIN REQUIRED SOURCE REFS =====' \
        'structured final synthesis receives the explicit list of required source refs'
    assert_file_contains "$final_prompt" '{"agent":"alpha","source_id":"alpha:C-001"}' \
        'the required refs name every canonical cross-review record exactly'
    assert_file_contains "$final_prompt" '"primary_provenance"' \
        'cross-review records are presented with their primary refs renamed to provenance'
    assert_false 'cross-review records no longer expose primary refs under the source_refs key' \
        grep -Fq -- '"source_refs":' "$final_prompt"
    assert_file_contains "$alpha_prompt" '===== BEGIN REQUIRED SOURCE REFS =====' \
        'structured cross-review receives the explicit list of required source refs'
    assert_file_contains "$alpha_prompt" '{"agent":"beta","source_id":"beta:F-001"}' \
        'the cross-review required refs name every peer primary finding exactly'
    assert_eq '2' "$(jq -r '.passes | length' "$work_dir/${stem}-final-usage.json")" \
        'structured final usage includes generation and bounded repair passes'
    assert_file_exists "$work_dir/${stem}-final-error-schema-repair-source-raw.ndjson" \
        'structured final repair preserves the original invalid response'

    sleep 1
    PATH="$fake_bin:$PATH" \
        REVIEW_PR_MOCK_BEHAVIOR=valid-ndjson \
        REVIEW_PR_MOCK_CAPTURE_DIR="$capture" \
        "$repo_root/bin/review-pr" --config "$config" --rerun-final --run "$timestamp" 123 \
        >"$case_dir/rerun-output.txt" 2>"$case_dir/rerun-stderr.log"
    rerun_manifest=$(find "$work_dir" -type f -name '*-final-rerun-*-manifest.json' -print | sort | tail -n 1)
    [[ -n "$rerun_manifest" ]] || fail 'structured final rerun did not create a manifest'
    pass 'structured final rerun creates a separate manifest'
    assert_eq ndjson-v1 "$(jq -r '.reporting.finding_contract.final' "$rerun_manifest")" \
        'structured final rerun records its contract'
    assert_file_exists "$work_dir/$(jq -r '.final_raw' "$rerun_manifest")" \
        'structured final rerun preserves its own raw NDJSON'
    assert_file_exists "$work_dir/$(jq -r '.final_findings' "$rerun_manifest")" \
        'structured final rerun publishes its own canonical sidecar'
}

run_ndjson_cross_resume_case() {
    local case_dir="$suite_root/ndjson-cross-resume"
    local reviews="$case_dir/reviews"
    local fake_bin="$case_dir/bin"
    local scenarios="$case_dir/scenarios"
    local checkout
    local config="$case_dir/config.json"
    local config_temp="$case_dir/config.tmp.json"
    local manifest work_dir stem timestamp alpha_report_checksum alpha_raw_checksum alpha_findings_checksum

    mkdir -p -- "$case_dir" "$reviews" "$fake_bin" "$scenarios"
    checkout=$(make_repository "$case_dir")
    export REVIEW_PR_FAKE_REFERENCE_SHA
    REVIEW_PR_FAKE_REFERENCE_SHA=$(git -C "$checkout" rev-parse main)
    export REVIEW_PR_FAKE_PULL_HEAD_SHA
    REVIEW_PR_FAKE_PULL_HEAD_SHA=$(git --git-dir="$case_dir/origin.git" rev-parse refs/pull/122/head)
    export REVIEW_PR_FAKE_BASE_REF=main
    export REVIEW_PR_FAKE_DEFAULT_BRANCH=main
    unset REVIEW_PR_FAKE_DEFAULT_BRANCH_FAILURE
    export REVIEW_PR_FAKE_PR_BODY='Fixture structured cross-review resume.'
    write_config "$config" "$checkout" "$reviews" 2
    jq '.reporting.finding_contract = {primary: "ndjson-v1", cross_review: "ndjson-v1"} |
        .reporting.comparison_sections = {cross_review: "none", final: "none"}' \
        "$config" >"$config_temp"
    mv -- "$config_temp" "$config"
    ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"
    printf '%s\n' nonzero >"$scenarios/beta-cross-review"

    if PATH="$fake_bin:$PATH" \
        REVIEW_PR_MOCK_BEHAVIOR=valid-ndjson \
        REVIEW_PR_MOCK_SCENARIO_DIR="$scenarios" \
        "$repo_root/bin/review-pr" --config "$config" 123 \
        >"$case_dir/first-output.txt" 2>"$case_dir/first-stderr.log"; then
        fail 'failed structured cross-review must pause final synthesis'
    fi
    pass 'failed structured cross-review pauses final synthesis'

    manifest=$(latest_manifest "$reviews")
    work_dir=${manifest%/*}
    stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")
    timestamp=$(jq -r '.timestamp' "$manifest")
    alpha_report_checksum=$(cksum "$work_dir/${stem}-cross-alpha.md")
    alpha_raw_checksum=$(cksum "$work_dir/${stem}-cross-alpha-raw.ndjson")
    alpha_findings_checksum=$(cksum "$work_dir/${stem}-cross-alpha-findings.json")
    assert_file_not_exists "$work_dir/${stem}-cross-beta.md" \
        'failed structured cross-review publishes no Markdown artifact'
    assert_file_not_exists "$work_dir/${stem}-cross-beta-findings.json" \
        'failed structured cross-review publishes no canonical sidecar'

    rm -- "$scenarios/beta-cross-review"
    jq '.reporting.finding_contract = {primary: "markdown", cross_review: "markdown"}' \
        "$config" >"$config_temp"
    mv -- "$config_temp" "$config"
    PATH="$fake_bin:$PATH" \
        REVIEW_PR_MOCK_BEHAVIOR=valid-ndjson \
        REVIEW_PR_MOCK_SCENARIO_DIR="$scenarios" \
        "$repo_root/bin/review-pr" --config "$config" --run "$timestamp" 123 \
        >"$case_dir/resume-output.txt" 2>"$case_dir/resume-stderr.log"

    assert_eq "$alpha_report_checksum" "$(cksum "$work_dir/${stem}-cross-alpha.md")" \
        'structured resume preserves successful cross-review Markdown byte-for-byte'
    assert_eq "$alpha_raw_checksum" "$(cksum "$work_dir/${stem}-cross-alpha-raw.ndjson")" \
        'structured resume preserves successful cross-review raw NDJSON byte-for-byte'
    assert_eq "$alpha_findings_checksum" "$(cksum "$work_dir/${stem}-cross-alpha-findings.json")" \
        'structured resume preserves successful canonical cross-review findings'
    assert_file_exists "$work_dir/${stem}-cross-beta-raw.ndjson" \
        'structured resume publishes the missing cross-review raw response'
    assert_file_exists "$work_dir/${stem}-cross-beta-findings.json" \
        'structured resume publishes the missing canonical cross-review findings'
    assert_eq ndjson-v1 "$(jq -r '.reporting.finding_contract.cross_review' "$manifest")" \
        'structured resume honors the manifest cross-review contract'
    assert_eq complete "$(jq -r '.status.pipeline' "$manifest")" \
        'structured cross-review resume completes the remaining pipeline'
}

run_ndjson_schema_repair_case() {
    local case_dir="$suite_root/ndjson-schema-repair"
    local reviews="$case_dir/reviews"
    local fake_bin="$case_dir/bin"
    local scenarios="$case_dir/scenarios"
    local capture="$case_dir/captured-prompts"
    local checkout
    local config="$case_dir/config.json"
    local config_temp="$case_dir/config.tmp.json"
    local manifest
    local work_dir
    local stem
    local source_diagnostic

    mkdir -p -- "$case_dir" "$reviews" "$fake_bin" "$scenarios" "$capture"
    checkout=$(make_repository "$case_dir")
    export REVIEW_PR_FAKE_REFERENCE_SHA
    REVIEW_PR_FAKE_REFERENCE_SHA=$(git -C "$checkout" rev-parse main)
    export REVIEW_PR_FAKE_PULL_HEAD_SHA
    REVIEW_PR_FAKE_PULL_HEAD_SHA=$(git --git-dir="$case_dir/origin.git" rev-parse refs/pull/122/head)
    export REVIEW_PR_FAKE_BASE_REF=main
    export REVIEW_PR_FAKE_DEFAULT_BRANCH=main
    unset REVIEW_PR_FAKE_DEFAULT_BRANCH_FAILURE
    export REVIEW_PR_FAKE_PR_BODY='Fixture structured primary schema repair.'
    write_config "$config" "$checkout" "$reviews" 2
    jq '.reporting.finding_contract = {primary: "ndjson-v1"} | .reporting.comparison_sections.final = "none"' \
        "$config" >"$config_temp"
    mv -- "$config_temp" "$config"
    ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"
    printf '%s\n' 'ndjson-preamble' >"$scenarios/beta-primary-review"
    printf '%s\n' 'valid-ndjson' >"$scenarios/beta-primary-findings-repair"

    PATH="$fake_bin:$PATH" \
        REVIEW_PR_MOCK_BEHAVIOR=valid-ndjson \
        REVIEW_PR_MOCK_SCENARIO_DIR="$scenarios" \
        REVIEW_PR_MOCK_CAPTURE_DIR="$capture" \
        "$repo_root/bin/review-pr" --config "$config" 123 \
        >"$case_dir/output.txt" 2>"$case_dir/stderr.log"

    manifest=$(latest_manifest "$reviews")
    work_dir=${manifest%/*}
    stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")
    source_diagnostic=$(find "$work_dir" -type f -name '*primary-beta-error-schema-repair-attempt-1-source-raw.ndjson' -print | sed -n '1p')
    assert_eq complete "$(jq -r '.status.pipeline' "$manifest")" \
        'bounded primary schema repair lets the pipeline complete'
    assert_file_exists "$capture/primary-findings-repair-beta-attempt-1.prompt" \
        'repair pass receives a dedicated no-new-review prompt'
    [[ -n "$source_diagnostic" ]] || fail 'schema repair did not preserve the rejected source response'
    pass 'schema repair preserves the rejected source response'
    assert_file_contains "$source_diagnostic" 'Here is the requested structured review:' \
        'preserved source response retains the invalid transport prose'
    assert_false 'canonical raw response excludes repaired transport prose' \
        grep -Fq -- 'Here is the requested structured review:' "$work_dir/${stem}-beta-raw.ndjson"
    assert_eq '2' "$(jq -r '.passes | length' "$work_dir/${stem}-beta-usage.json")" \
        'primary usage includes generation and bounded repair passes'
    assert_eq 'The fixture changed branch can fail.' \
        "$(jq -r '.findings[0].claim' "$work_dir/${stem}-beta-findings.json")" \
        'schema repair preserves substantive finding content'
}

run_ndjson_unsafe_schema_repair_case() {
    local case_dir="$suite_root/ndjson-unsafe-schema-repair"
    local reviews="$case_dir/reviews"
    local fake_bin="$case_dir/bin"
    local scenarios="$case_dir/scenarios"
    local checkout
    local config="$case_dir/config.json"
    local config_temp="$case_dir/config.tmp.json"
    local manifest
    local work_dir
    local stem
    local rejected_source
    local rejected_repair

    mkdir -p -- "$case_dir" "$reviews" "$fake_bin" "$scenarios"
    checkout=$(make_repository "$case_dir")
    export REVIEW_PR_FAKE_REFERENCE_SHA
    REVIEW_PR_FAKE_REFERENCE_SHA=$(git -C "$checkout" rev-parse main)
    export REVIEW_PR_FAKE_PULL_HEAD_SHA
    REVIEW_PR_FAKE_PULL_HEAD_SHA=$(git --git-dir="$case_dir/origin.git" rev-parse refs/pull/122/head)
    export REVIEW_PR_FAKE_BASE_REF=main
    export REVIEW_PR_FAKE_DEFAULT_BRANCH=main
    unset REVIEW_PR_FAKE_DEFAULT_BRANCH_FAILURE
    export REVIEW_PR_FAKE_PR_BODY='Fixture unsafe structured repair.'
    write_config "$config" "$checkout" "$reviews" 2
    jq '.reporting.finding_contract = {primary: "ndjson-v1"} | .reporting.comparison_sections.final = "none"' \
        "$config" >"$config_temp"
    mv -- "$config_temp" "$config"
    ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"
    printf '%s\n' 'ndjson-preamble' >"$scenarios/beta-primary-review"
    printf '%s\n' 'unsafe-ndjson-repair' >"$scenarios/beta-primary-findings-repair"

    if PATH="$fake_bin:$PATH" \
        REVIEW_PR_MOCK_BEHAVIOR=valid-ndjson \
        REVIEW_PR_MOCK_SCENARIO_DIR="$scenarios" \
        "$repo_root/bin/review-pr" --config "$config" 123 \
        >"$case_dir/output.txt" 2>"$case_dir/stderr.log"; then
        fail 'content-changing primary schema repair must fail closed'
    fi
    pass 'content-changing primary schema repair fails closed'

    manifest=$(latest_manifest "$reviews")
    work_dir=${manifest%/*}
    stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")
    rejected_source=$(find "$work_dir" -type f -name '*primary-beta-error-partial-raw.ndjson' -print | sed -n '1p')
    rejected_repair=$(find "$work_dir" -type f -name '*primary-beta-error-schema-repair-attempt-1-invalid-raw.ndjson' -print | sed -n '1p')
    [[ -n "$rejected_source" ]] || fail 'unsafe repair did not preserve the original response'
    pass 'unsafe repair preserves the original response'
    [[ -n "$rejected_repair" ]] || fail 'unsafe repair did not preserve the repair response'
    pass 'unsafe repair preserves the rejected repair response'
    assert_file_contains "$rejected_repair" 'The repair rewrote the finding claim.' \
        'unsafe repair diagnostic exposes the changed substantive field'
    assert_file_not_exists "$work_dir/${stem}-beta.md" \
        'unsafe repair cannot publish primary Markdown'
    assert_file_not_exists "$work_dir/${stem}-beta-findings.json" \
        'unsafe repair cannot publish canonical findings'
}

run_ndjson_resume_case() {
    local case_dir="$suite_root/ndjson-resume"
    local reviews="$case_dir/reviews"
    local fake_bin="$case_dir/bin"
    local scenarios="$case_dir/scenarios"
    local checkout
    local config="$case_dir/config.json"
    local config_temp="$case_dir/config.tmp.json"
    local manifest
    local work_dir
    local stem
    local timestamp
    local alpha_report_checksum
    local alpha_raw_checksum
    local failed_raw

    mkdir -p -- "$case_dir" "$reviews" "$fake_bin" "$scenarios"
    checkout=$(make_repository "$case_dir")
    export REVIEW_PR_FAKE_REFERENCE_SHA
    REVIEW_PR_FAKE_REFERENCE_SHA=$(git -C "$checkout" rev-parse main)
    export REVIEW_PR_FAKE_PULL_HEAD_SHA
    REVIEW_PR_FAKE_PULL_HEAD_SHA=$(git --git-dir="$case_dir/origin.git" rev-parse refs/pull/122/head)
    export REVIEW_PR_FAKE_BASE_REF=main
    export REVIEW_PR_FAKE_DEFAULT_BRANCH=main
    unset REVIEW_PR_FAKE_DEFAULT_BRANCH_FAILURE
    export REVIEW_PR_FAKE_PR_BODY='Fixture structured primary resume.'
    write_config "$config" "$checkout" "$reviews" 2
    jq '.reporting.finding_contract = {primary: "ndjson-v1"} | .reporting.comparison_sections.final = "none"' \
        "$config" >"$config_temp"
    mv -- "$config_temp" "$config"
    ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"
    printf 'invalid\n' >"$scenarios/beta-primary-review"

    if PATH="$fake_bin:$PATH" \
        REVIEW_PR_MOCK_BEHAVIOR=valid-ndjson \
        REVIEW_PR_MOCK_SCENARIO_DIR="$scenarios" \
        "$repo_root/bin/review-pr" --config "$config" 123 \
        >"$case_dir/first-output.txt" 2>"$case_dir/first-stderr.log"; then
        fail 'invalid structured primary output must pause the pipeline'
    fi
    pass 'invalid structured primary output pauses before cross-review'

    manifest=$(latest_manifest "$reviews")
    work_dir=${manifest%/*}
    stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")
    timestamp=$(jq -r '.timestamp' "$manifest")
    alpha_report_checksum=$(cksum "$work_dir/${stem}-alpha.md")
    alpha_raw_checksum=$(cksum "$work_dir/${stem}-alpha-raw.ndjson")
    assert_file_not_exists "$work_dir/${stem}-beta.md" 'invalid structured response has no canonical Markdown report'
    assert_file_not_exists "$work_dir/${stem}-beta-findings.json" 'invalid structured response has no canonical findings sidecar'
    failed_raw=$(find "$work_dir" -type f -name '*primary-beta-error-partial-raw.ndjson' -print | sed -n '1p')
    [[ -n "$failed_raw" ]] || fail 'invalid structured response did not preserve raw attempt diagnostics'
    pass 'invalid structured response preserves raw attempt diagnostics'

    rm -- "$scenarios/beta-primary-review"
    jq '.reporting.finding_contract.primary = "markdown"' "$config" >"$config_temp"
    mv -- "$config_temp" "$config"
    PATH="$fake_bin:$PATH" \
        REVIEW_PR_MOCK_BEHAVIOR=valid-ndjson \
        REVIEW_PR_MOCK_SCENARIO_DIR="$scenarios" \
        "$repo_root/bin/review-pr" --config "$config" --run "$timestamp" 123 \
        >"$case_dir/resume-output.txt" 2>"$case_dir/resume-stderr.log"

    assert_eq "$alpha_report_checksum" "$(cksum "$work_dir/${stem}-alpha.md")" \
        'structured resume keeps successful primary Markdown byte-for-byte'
    assert_eq "$alpha_raw_checksum" "$(cksum "$work_dir/${stem}-alpha-raw.ndjson")" \
        'structured resume keeps successful raw NDJSON byte-for-byte'
    assert_file_exists "$work_dir/${stem}-beta-raw.ndjson" 'structured resume publishes the missing raw response'
    assert_file_exists "$work_dir/${stem}-beta-findings.json" 'structured resume publishes the missing canonical findings'
    assert_eq 'ndjson-v1' "$(jq -r '.reporting.finding_contract.primary' "$manifest")" \
        'resume honors the manifest contract rather than a changed current default'
    assert_eq 'complete' "$(jq -r '.status.pipeline' "$manifest")" 'structured resume completes the remaining pipeline'
}

run_ndjson_unsafe_final_repair_case() {
    local case_dir="$suite_root/ndjson-unsafe-final-repair"
    local reviews="$case_dir/reviews" fake_bin="$case_dir/bin" scenarios="$case_dir/scenarios"
    local checkout config="$case_dir/config.json" config_temp="$case_dir/config.tmp.json"
    local manifest work_dir stem

    mkdir -p -- "$case_dir" "$reviews" "$fake_bin" "$scenarios"
    checkout=$(make_repository "$case_dir")
    export REVIEW_PR_FAKE_REFERENCE_SHA
    REVIEW_PR_FAKE_REFERENCE_SHA=$(git -C "$checkout" rev-parse main)
    export REVIEW_PR_FAKE_PULL_HEAD_SHA
    REVIEW_PR_FAKE_PULL_HEAD_SHA=$(git --git-dir="$case_dir/origin.git" rev-parse refs/pull/122/head)
    export REVIEW_PR_FAKE_BASE_REF=main REVIEW_PR_FAKE_DEFAULT_BRANCH=main
    unset REVIEW_PR_FAKE_DEFAULT_BRANCH_FAILURE
    export REVIEW_PR_FAKE_PR_BODY='Fixture unsafe final schema repair.'
    write_config "$config" "$checkout" "$reviews" 2
    jq '.reporting.finding_contract = {primary: "ndjson-v1", cross_review: "ndjson-v1", final: "ndjson-v1"} |
        .reporting.comparison_sections = {cross_review: "none", final: "none"}' "$config" >"$config_temp"
    mv -- "$config_temp" "$config"
    ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"
    printf '%s\n' final-ndjson-preamble >"$scenarios/alpha-final-synthesis"
    printf '%s\n' unsafe-final-ndjson-repair >"$scenarios/alpha-final-findings-repair"

    if PATH="$fake_bin:$PATH" REVIEW_PR_MOCK_BEHAVIOR=valid-ndjson REVIEW_PR_MOCK_SCENARIO_DIR="$scenarios" \
        "$repo_root/bin/review-pr" --config "$config" 123 >"$case_dir/output.txt" 2>"$case_dir/stderr.log"; then
        fail 'content-changing final schema repair must fail closed'
    fi
    pass 'content-changing final schema repair fails closed'
    manifest=$(latest_manifest "$reviews")
    work_dir=${manifest%/*}
    stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")
    assert_file_not_exists "${work_dir%/work}/${stem}-final.md" \
        'unsafe final repair cannot publish human Markdown'
    assert_file_not_exists "$work_dir/${stem}-final-findings.json" \
        'unsafe final repair cannot publish canonical findings'
    assert_file_not_exists "$work_dir/${stem}-final-raw.ndjson" \
        'unsafe final repair cannot publish canonical raw NDJSON'
    assert_file_exists "$work_dir/${stem}-final-error-schema-repair-source-raw.ndjson" \
        'unsafe final repair preserves the original rejected response'
    assert_file_exists "$work_dir/${stem}-final-error-schema-repair-invalid-raw.ndjson" \
        'unsafe final repair preserves the content-changing repair response'
    assert_file_contains "$case_dir/stderr.log" 'repair_changed_decisions_provenance_or_content' \
        'unsafe final repair reports its stability violation'
}

run_full_success_case
run_ndjson_primary_case
run_ndjson_cross_case
run_ndjson_cross_resume_case
run_ndjson_schema_repair_case
run_ndjson_unsafe_schema_repair_case
run_ndjson_resume_case
run_ndjson_unsafe_final_repair_case
run_resume_case
run_comparison_failure_case
run_facts_collection_failure_case
run_anchor_repair_case
run_unsafe_anchor_repair_case
run_interrupt_case

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
