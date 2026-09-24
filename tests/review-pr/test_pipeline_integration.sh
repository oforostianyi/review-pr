#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154 # Tests assign the sourced orchestrator's globals and index its associative arrays.

set -euo pipefail

test_dir=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo_root=$(cd -P -- "$test_dir/../.." && pwd -P)
source "$test_dir/lib/assert.sh"

suite_root=$(portable_mktemp_dir review-pr-pipeline)
cleanup_suite() {
    local attempt

    if [[ "${REVIEW_PR_TEST_PRESERVE_TMP:-false}" == true ]]; then
        printf 'Preserved integration fixture: %s\n' "$suite_root" >&2
        return
    fi
    # A terminated fixture agent may still be flushing files for a moment;
    # a cleanup hiccup must not turn a fully passing suite into a failure.
    for attempt in 1 2 3 4 5; do
        rm -rf -- "$suite_root" 2>/dev/null && return
        sleep 1
    done
    rm -rf -- "$suite_root" || printf 'Warning: could not remove integration fixture %s\n' "$suite_root" >&2
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
                alpha: {"label": "Alpha", enabled: true, model: "mock-alpha", effort: "low", timeout_seconds: 2700, runner: $runner},
                beta: {"label": "Beta", enabled: true, model: "mock-beta", effort: "medium", runner: $runner}
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

# Working files live in <review>/work/<run>; older runs kept them in <review>/work.
# Both resolve to the same review directory, where the reader-facing reports live.
report_root_of() {
    local work_dir=$1
    if [[ "${work_dir%/*}" == */work ]]; then
        printf '%s\n' "${work_dir%/work/*}"
    else
        printf '%s\n' "${work_dir%/work}"
    fi
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
    local history
    local forced_rerun_status
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
    report_dir=$(report_root_of "$work_dir")
    stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")
    timestamp=$(jq -r '.timestamp' "$manifest")
    assert_file_exists "$report_dir/${stem}-final.md" 'final core report remains in the review directory root'
    assert_eq "$timestamp" "${work_dir##*/}" \
        'working files of a run live in their own directory named after the run'
    assert_eq "$report_dir/work" "${work_dir%/*}" \
        'run directories sit directly under the review work directory'
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
    # Cross-review has already checked every finding against the code. The
    # finalizer is told where checking again is the work -- a factual dispute, the
    # premise of a P0 or P1 -- and where it is only duplication.
    assert_file_contains "$capture/final-synthesis-alpha-attempt-1.prompt" \
        'Verify in proportion to what is at stake, not everything again.' \
        'the finalizer is told to check in proportion to the stakes'
    assert_file_contains "$capture/final-synthesis-alpha-attempt-1.prompt" \
        'agreement is not evidence' \
        'and that reviewers who agree can still share one blind spot'
    assert_false 'a run with its checkout is not told the source is only what the reports quote' \
        grep -Fq 'artifact-only rerun the source is the code the reports quote' \
            "$capture/final-synthesis-alpha-attempt-1.prompt"

    # Finding out what ran last night should not mean reading through review
    # directories. One appended line per launch and per outcome, next to the
    # reviews themselves, answers it.
    history="$reviews/run-history.jsonl"
    assert_file_exists "$history" 'a run records itself in the history log'
    assert_eq 'started finished' \
        "$(jq -r 'select(.pr == 123) | .event' "$history" | tr '\n' ' ' | sed 's/ $//')" \
        'the log carries the launch and the outcome of the run'
    assert_eq '123' "$(jq -r 'select(.event == "started") | .pr | tostring' "$history" | head -1)" \
        'the launch record names the pull request'
    assert_eq 'full' "$(jq -r 'select(.event == "started") | .mode' "$history" | head -1)" \
        'the launch record says what kind of run it was'
    assert_eq 'example/repository' "$(jq -r 'select(.event == "started") | .repository' "$history" | head -1)" \
        'the launch record names the repository, since one log covers them all'
    assert_eq '0' "$(jq -r 'select(.event == "finished") | .exit_status | tostring' "$history" | head -1)" \
        'the outcome record carries the exit status'
    assert_eq "$timestamp" "$(jq -r 'select(.event == "finished") | .run' "$history" | head -1)" \
        'the outcome record points at the run directory it produced'
    assert_true 'the outcome record measures how long the run took' \
        jq -e 'select(.event == "finished") | .duration_seconds | type == "number"' "$history"

    cross_alpha_checksum=$(cksum "$work_dir/${stem}-cross-alpha.md")
    gh_calls_before=$(wc -l <"$gh_log" | tr -d ' ')
    PATH="$fake_bin:$PATH" \
        REVIEW_PR_FAKE_GH_LOG="$gh_log" \
        REVIEW_PR_MOCK_CAPTURE_DIR="$capture" \
        "$repo_root/bin/review-pr" --config "$config" --rerun-final --run "$timestamp" 123 \
        >"$case_dir/rerun-output.txt" 2>"$case_dir/rerun-stderr.log"
    assert_eq "$cross_alpha_checksum" "$(cksum "$work_dir/${stem}-cross-alpha.md")" \
        'artifact-only final rerun does not overwrite a source cross-review'
    assert_eq "$gh_calls_before" "$(wc -l <"$gh_log" | tr -d ' ')" \
        'artifact-only final rerun performs no GitHub calls'
    rerun_final_prompt=$(find "$capture" -type f -name 'final-synthesis-alpha-attempt-1.prompt' -print | sort | tail -n 1)
    assert_file_contains "$rerun_final_prompt" '===== BEGIN AUTHORITATIVE REPOSITORY FACTS =====' \
        'artifact-only final rerun reuses preserved repository facts'
    assert_file_contains "$rerun_final_prompt" 'In this artifact-only rerun the source is the code the reports quote' \
        'an artifact-only rerun is told its only source is the code the reports quote'
    rerun_manifest=$(find "$work_dir" -type f -name '*-final-rerun-*-manifest.json' -print | sed -n '1p')
    [[ -n "$rerun_manifest" ]] || fail 'artifact-only final rerun did not create a separate manifest'
    pass 'artifact-only final rerun creates a separate manifest'

    # The rerun manifest names its source, but nothing pointed the other way: a run
    # whose final phase failed and was later rescued read as a dead end.
    assert_eq 1 "$(jq '.final_reruns | length' "$manifest")" \
        'the source run records the rerun that was made from it'
    assert_eq "$(jq -r '.timestamp' "$rerun_manifest")" "$(jq -r '.final_reruns[0].timestamp' "$manifest")" \
        'the record names the rerun by its own timestamp'
    assert_eq 'complete' "$(jq -r '.final_reruns[0].status' "$manifest")" \
        'the record carries the outcome of the rerun'
    assert_eq "${rerun_manifest##*/}" "$(jq -r '.final_reruns[0].manifest' "$manifest")" \
        'the record points at the manifest that holds the rest'
    assert_eq "$(jq -r '.artifact' "$rerun_manifest")" "$(jq -r '.final_reruns[0].final' "$manifest")" \
        'the record points at the report the rerun published'
    assert_eq 'complete' "$(jq -r '.status.pipeline' "$manifest")" \
        'recording a rerun does not rewrite what the source run itself did'

    forced_rerun_status=0
    PATH="$fake_bin:$PATH" \
        REVIEW_PR_FAKE_GH_LOG="$gh_log" \
        REVIEW_PR_MOCK_CAPTURE_DIR="$capture" \
        "$repo_root/bin/review-pr" --config "$config" --rerun-final --force --run "$timestamp" 123 \
        >"$case_dir/forced-rerun-output.txt" 2>"$case_dir/forced-rerun-stderr.log" || forced_rerun_status=$?
    assert_eq 0 "$forced_rerun_status" \
        'a forced final rerun finds the cross-reviews of a run kept in its own work directory'
    assert_false 'a forced final rerun does not report the cross-reviews as missing' \
        grep -q 'needs at least two completed cross-review reports' "$case_dir/forced-rerun-stderr.log"
    assert_eq 1 "$(jq '.final_reruns | length' "$manifest")" \
        'a forced rerun, which deliberately ignores the manifest, records nothing in it'

    legacy_manifest_temp="${manifest}.legacy.tmp"
    jq 'del(.artifacts.repository_facts, .artifacts.changed_lines)' "$manifest" >"$legacy_manifest_temp"
    mv -- "$legacy_manifest_temp" "$manifest"
    gh_calls_before=$(wc -l <"$gh_log" | tr -d ' ')
    sleep 1
    PATH="$fake_bin:$PATH" \
        REVIEW_PR_FAKE_GH_LOG="$gh_log" \
        REVIEW_PR_MOCK_CAPTURE_DIR="$capture" \
        "$repo_root/bin/review-pr" --config "$config" --rerun-final --run "$timestamp" 123 \
        >"$case_dir/legacy-rerun-output.txt" 2>"$case_dir/legacy-rerun-stderr.log"
    assert_eq "$gh_calls_before" "$(wc -l <"$gh_log" | tr -d ' ')" \
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
    report_dir=$(report_root_of "$work_dir")
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

    # The orchestrator fetches, reads GitHub context, collects repository facts and
    # builds the changed-line map before its first agent starts. Five seconds is
    # enough on an idle machine and not enough while the rest of the suite runs.
    while ! grep -q '^start' "$events"; do
        attempts=$((attempts + 1))
        if (( attempts > 1200 )); then
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
    # Termination must take the agent processes down with the orchestrator, not
    # leave them running (and spending quota) until they finish on their own.
    attempts=0
    while pgrep -f "REVIEW_PR_MOCK_SCENARIO_DIR=${scenarios}" >/dev/null 2>&1 || pgrep -f "$case_dir/" >/dev/null 2>&1; do
        attempts=$((attempts + 1))
        (( attempts <= 100 )) || break
        sleep 0.05
    done
    if pgrep -f "REVIEW_PR_MOCK_SCENARIO_DIR=${scenarios}" >/dev/null 2>&1; then
        fail 'terminated pipeline left its agent processes running'
    fi
    pass 'termination also stops the agent processes the pipeline started'

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
    report_dir=$(report_root_of "$work_dir")
    stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")
    assert_file_exists "$work_dir/${stem}-changed-lines.json" \
        'full run publishes the exact changed-line map'
    assert_eq 'true' "$(jq -r '.files[] | select(.path == "fixture odd [name].txt") | any(.right_side_ranges[]; .start <= 1 and .["end"] >= 1)' "$work_dir/${stem}-changed-lines.json")" \
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
    report_dir=$(report_root_of "$work_dir")
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
    assert_file_contains "$capture/primary-review-alpha-attempt-1.prompt" 'to the changed line that creates the exposure' \
        'structured primary prompt anchors affected consumers and flows to the exposing changed line'
    assert_file_contains "$capture/primary-review-alpha-attempt-1.prompt" 'Use pr-level only when no changed line causes the finding' \
        'structured primary prompt keeps pr-level as the fallback for coverage, migration, and documentation gaps'
    assert_file_contains "$capture/primary-review-alpha-attempt-1.prompt" 'never silently dropped' \
        'structured primary prompt maps plausible skill findings onto records instead of dropping them'
    assert_file_contains "$capture/primary-review-alpha-attempt-1.prompt" 'refuted candidates are not emitted' \
        'structured primary prompt maps the skill report sections onto the record contract'
    assert_file_contains "$capture/primary-review-alpha-attempt-1.prompt" 'an explicit repository rule with its path' \
        'structured primary prompt requires rule-based findings to name their basis in evidence'
    assert_file_contains "$capture/primary-review-alpha-attempt-1.prompt" 'inferred convention' \
        'structured primary prompt distinguishes inferred conventions from explicit rules'
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
    local manifest work_dir stem timestamp alpha_raw alpha_findings alpha_report alpha_prompt final_raw final_findings final_report final_prompt rerun_manifest contract_prompt findings_export
    local forced_rerun_status forced_rerun_manifest mislabelled_status mislabelled_manifest
    local contract_prompt

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
        .reporting.comparison_sections = {cross_review: "none", final: "none"} |
        .prompts.cross_review = ["Start with exactly this table:", "## Classification ledger", "| # | Source | Claim |"]' \
        "$config" >"$config_temp"
    mv -- "$config_temp" "$config"
    ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"
    printf '%s\n' cross-ndjson-trailing-prose >"$scenarios/beta-cross-review"
    printf '%s\n' valid-ndjson >"$scenarios/beta-cross-review-findings-repair"
    printf '%s\n' final-ndjson-trailing-prose >"$scenarios/alpha-final-synthesis"
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
    final_report="$(report_root_of "$work_dir")/${stem}-final.md"
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
    assert_eq 'beta:r02' "$(jq -r '.input_refs[0] | .agent + ":" + .source_id' "$alpha_findings")" \
        'cross-review sidecar preserves namespaced primary provenance, by the handle the reviewer was given'
    assert_eq "${stem}-cross-alpha-raw.ndjson" "$(jq -r '.artifacts.cross_review_raw.alpha' "$manifest")" \
        'manifest points to cross-review raw output'
    assert_eq "${stem}-cross-alpha-findings.json" "$(jq -r '.artifacts.cross_review_findings.alpha' "$manifest")" \
        'manifest points to canonical cross-review findings'
    assert_file_contains "$alpha_report" '### [CONFIRMED/P1] Fixture changed-line defect' \
        'cross-review Markdown is rendered from canonical classifications'
    assert_file_contains "$alpha_prompt" '===== BEGIN CANONICAL PRIMARY FINDINGS: beta =====' \
        'structured cross-review receives the other canonical primary report'
    assert_false 'structured cross-review does not receive its own canonical primary report' \
        grep -Fq -- '===== BEGIN CANONICAL PRIMARY FINDINGS: alpha =====' "$alpha_prompt"
    # A reviewer given a long descriptive id rewrote it into a shorter one, and one
    # given two ids for a record may copy either. The record it is handed carries
    # only its short handle; the author's own id stays with the author.
    assert_false "the author's own id never reaches the reviewer" \
        grep -Fq -- 'beta:F-001' "$alpha_prompt"
    assert_file_contains "$alpha_prompt" 'BEGIN RIGHT-SIDE CHANGED-LINE MAP' \
        'structured cross-review receives the authoritative changed-line map'
    # The terminal record's arrays hold plain strings. Saying so is what keeps a
    # reviewer from encoding "the file and the symbol" as an object, which the
    # validator rejects and the bounded repair may not rewrite.
    # Every supplied record carries the exact {agent, source_id} pair to copy when
    # citing it, so a reviewer never has to pair an id from one place with an agent
    # key from another. That join is what mis-attributed two pi records to claude.
    prompt_block() {
        awk -v begin="===== BEGIN $2 =====" -v end="===== END $2 =====" '
            $0 == begin {inside = 1; next}
            $0 == end {inside = 0}
            inside' "$1"
    }
    assert_eq 'beta r02' \
        "$(prompt_block "$capture/cross-review-alpha-attempt-1.prompt" 'CANONICAL PRIMARY FINDINGS: beta' \
            | jq -r '.findings[0].record_ref | .agent + " " + .source_id')" \
        'a cross-reviewer is handed the ready-made ref for each supplied primary record'
    assert_eq 'r02' \
        "$(prompt_block "$capture/cross-review-alpha-attempt-1.prompt" 'CANONICAL PRIMARY FINDINGS: beta' \
            | jq -r '.findings[0].source_id')" \
        'and the record itself shows the same handle as its id, never a second one'
    assert_eq 'null' \
        "$(prompt_block "$capture/cross-review-alpha-attempt-1.prompt" 'CANONICAL PRIMARY FINDINGS: beta' \
            | jq -c '.findings[0].ref_id')" \
        'the bookkeeping field that holds the handle is not shown'
    assert_eq 'alpha x01' \
        "$(prompt_block "$capture/final-synthesis-alpha-attempt-1.prompt" 'CANONICAL CROSS-REVIEW FINDINGS: alpha' \
            | jq -r '.findings[0].record_ref | .agent + " " + .source_id')" \
        'the finalizer is handed the ready-made ref for each supplied cross-review record'
    assert_eq 'beta r02' \
        "$(prompt_block "$capture/final-synthesis-alpha-attempt-1.prompt" 'CANONICAL CROSS-REVIEW FINDINGS: alpha' \
            | jq -r '.findings[0].primary_provenance[0] | .agent + " " + .source_id')" \
        'upstream provenance stays visible and stays distinct from the ref to cite'

    for contract_prompt in primary-review-alpha cross-review-alpha final-synthesis-alpha; do
        assert_file_contains "$capture/${contract_prompt}-attempt-1.prompt" \
            'verification_limitations and positive_evidence are arrays of strings' \
            "the ${contract_prompt%%-*} contract states the terminal record's array element type"
        assert_file_contains "$capture/${contract_prompt}-attempt-1.prompt" \
            'names the file and the symbol inside that string' \
            "the ${contract_prompt%%-*} contract shows how one positive_evidence string carries a file and a symbol"
    done
    assert_eq '2' "$(jq -r '.passes | length' "$work_dir/${stem}-cross-beta-usage.json")" \
        'structured cross-review usage includes generation and bounded repair passes'
    assert_file_exists "$work_dir/${stem}-cross-beta-error-schema-repair-attempt-1-source-raw.ndjson" \
        'structured cross-review repair preserves original invalid response'
    assert_eq ndjson-v1 "$(jq -r '.reporting.finding_contract.final' "$manifest")" \
        'manifest records the final-synthesis finding contract'
    assert_file_exists "$final_raw" 'structured final synthesis preserves exact raw NDJSON'
    assert_file_exists "$final_findings" 'structured final synthesis publishes canonical findings JSON'
    assert_file_exists "$final_report" 'structured final synthesis publishes deterministic Markdown in the report root'
    # The fixing agent's copy is published beside the report a person reads.
    findings_export="$(report_root_of "$work_dir")/${stem}-fix-list.json"
    assert_file_exists "$findings_export" 'a structured run publishes the findings export beside the final report'
    assert_eq 'confirmed' "$(jq -r '.include' "$findings_export")" \
        'the published export carries the configured scope'
    assert_eq "$timestamp" "$(jq -r '.run' "$findings_export")" \
        'the published export names the run it came from'
    assert_eq 'CONFIRMED' "$(jq -r '[.findings[].classification] | unique | join(",")' "$findings_export")" \
        'only confirmed findings are published by default'
    assert_eq "${stem}-fix-list.json" "$(jq -r '.artifacts.final_findings_export' "$manifest")" \
        'the manifest records the findings export'
    assert_eq final-synthesis "$(jq -r '.phase' "$final_findings")" \
        'final sidecar records its phase'
    assert_eq 'alpha:r01,beta:r02' "$(jq -r '[.findings[0].primary_refs[] | .agent + ":" + .source_id] | join(",")' "$final_findings")" \
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
    assert_file_contains "$final_prompt" '{"agent":"alpha","source_id":"x01"}' \
        'the required refs name every canonical cross-review record exactly'
    assert_file_contains "$final_prompt" '"primary_provenance"' \
        'cross-review records are presented with their primary refs renamed to provenance'
    assert_false 'cross-review records no longer expose primary refs under the source_refs key' \
        grep -Fq -- '"source_refs":' "$final_prompt"
    assert_file_contains "$alpha_prompt" '===== BEGIN REQUIRED SOURCE REFS =====' \
        'structured cross-review receives the explicit list of required source refs'
    assert_file_contains "$alpha_prompt" '{"agent":"beta","source_id":"r02"}' \
        'the cross-review required refs name every peer primary finding exactly, by handle'
    assert_false 'structured cross-review does not forward Markdown-oriented config prompt instructions' \
        grep -Fq -- 'Start with exactly this table' "$alpha_prompt"
    assert_file_contains "$alpha_prompt" 'the caller through which it is reachable belong in evidence' \
        'structured cross-review maps the skill cross-review columns onto record fields'
    assert_file_contains "$alpha_prompt" 'inferred convention' \
        'structured cross-review states the explicit-rule versus inferred-convention basis policy'
    for captured in primary-review-alpha-attempt-1 cross-review-alpha-attempt-1 final-synthesis-alpha-attempt-1; do
        assert_file_contains "$capture/${captured}.prompt" 'one single final message' \
            "the ${captured%%-alpha*} contract asks for the whole stream in one final message"
    done
    assert_file_contains "$final_prompt" '===== BEGIN KNOWN LIMITATIONS =====' \
        'structured final synthesis receives the orchestrator-known limitations'
    assert_file_contains "$final_prompt" 'is a verification limitation, never a finding by itself' \
        'structured final synthesis is told that check and tool failures are limitations'
    assert_file_contains "$alpha_prompt" 'is a verification limitation, never a finding by itself' \
        'structured cross-review is told that check and tool failures are limitations'
    # The three contract blocks sit in heredocs with different quoting, so the same
    # source text does not reach the model the same way. An example that teaches the
    # wrong escaping is worse than no example: check what the prompt actually says.
    for contract_prompt in "$capture/primary-review-alpha-attempt-1.prompt" "$alpha_prompt" "$final_prompt"; do
        assert_file_contains "$contract_prompt" \
            'written "GuzzleHttp\\Handler\\MockHandler", never "GuzzleHttp\Handler\MockHandler"' \
            "the escaping rule reaches ${contract_prompt##*/} with one backslash in the wrong example"
    done
    assert_file_contains "$capture/primary-review-alpha-attempt-1.prompt" 'is a verification limitation, never a finding by itself' \
        'structured primary review is told that check and tool failures are limitations'
    assert_file_exists "$work_dir/${stem}-final-diagnostics.json" 'a structured final run publishes the diagnostics sidecar'
    assert_eq 'orchestrator,positive_evidence,reviewers' "$(jq -r '[.orchestrator, .positive_evidence, .reviewers] | length as $n | ["orchestrator","positive_evidence","reviewers"] | join(",")' "$work_dir/${stem}-final-diagnostics.json")" \
        'the diagnostics sidecar carries the three parts'
    assert_eq "${stem}-final-diagnostics.json" "$(jq -r '.artifacts.final_diagnostics' "$manifest")" \
        'the manifest records the diagnostics sidecar'
    assert_eq complete "$(jq -r '.review_threads.status' "$manifest")" 'the manifest records the measured review-thread state'
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

    sleep 1
    forced_rerun_status=0
    PATH="$fake_bin:$PATH" \
        REVIEW_PR_MOCK_BEHAVIOR=valid-ndjson \
        REVIEW_PR_MOCK_CAPTURE_DIR="$capture" \
        "$repo_root/bin/review-pr" --config "$config" --rerun-final --force --run "$timestamp" 123 \
        >"$case_dir/forced-rerun-output.txt" 2>"$case_dir/forced-rerun-stderr.log" || forced_rerun_status=$?
    assert_eq 0 "$forced_rerun_status" \
        'a forced final rerun of a structured run completes'
    forced_rerun_manifest=$(find "$work_dir" -type f -name '*-final-rerun-*-manifest.json' -print | sort | tail -n 1)
    assert_eq ndjson-v1 "$(jq -r '.reporting.finding_contract.final' "$forced_rerun_manifest")" \
        'a forced final rerun keeps the configured structured contract'
    assert_eq 'alpha,beta' \
        "$(jq -r '.inputs.cross_review_findings | keys | join(",")' "$forced_rerun_manifest")" \
        'a forced final rerun records the canonical cross-review sidecars it used'

    sleep 1
    printf '%s\n' final-mislabelled-agent >"$scenarios/alpha-final-synthesis"
    mislabelled_status=0
    PATH="$fake_bin:$PATH" \
        REVIEW_PR_MOCK_BEHAVIOR=valid-ndjson \
        REVIEW_PR_MOCK_SCENARIO_DIR="$scenarios" \
        REVIEW_PR_MOCK_CAPTURE_DIR="$capture" \
        "$repo_root/bin/review-pr" --config "$config" --rerun-final --run "$timestamp" 123 \
        >"$case_dir/mislabelled-output.txt" 2>"$case_dir/mislabelled-stderr.log" || mislabelled_status=$?
    assert_eq 0 "$mislabelled_status" \
        'a synthesis that mislabels the agent key of a known source id still completes'
    mislabelled_manifest=$(find "$work_dir" -type f -name '*-final-rerun-*-manifest.json' -print | sort | tail -n 1)
    assert_eq 'alpha beta' \
        "$(jq -r '[.findings[].source_refs[].agent] | unique | join(" ")' "$work_dir/$(jq -r '.final_findings' "$mislabelled_manifest")")" \
        'the canonical sidecar carries the corrected owners, not the mislabelled keys'
    assert_file_contains "$case_dir/mislabelled-stderr.log" 'Corrected mislabelled source_refs agent keys' \
        'the run says that it corrected the agent keys'
    assert_file_exists "$work_dir/$(jq -r '.final_raw' "$rerun_manifest")" \
        'structured final rerun preserves its own raw NDJSON'
    assert_file_exists "$work_dir/$(jq -r '.final_findings' "$rerun_manifest")" \
        'structured final rerun publishes its own canonical sidecar'
    assert_eq complete "$(jq -r '.review_threads.status' "$rerun_manifest")" \
        'structured final rerun inherits the source run review-thread state'
    assert_eq 'false' "$(jq '[.orchestrator[].type] | index("github_review_threads_unavailable") != null' "$work_dir/$(jq -r '.final_diagnostics' "$rerun_manifest")")" \
        'an artifact-only rerun does not report the inherited thread state as unavailable'
}

write_three_agent_config() {
    local config_file=$1 checkout=$2 reviews=$3
    write_config "$config_file" "$checkout" "$reviews" 3
    jq --arg runner "$test_dir/mock-agent-runner.sh" '
        .agents.gamma = {"label": "Gamma", enabled: true, model: "mock-gamma", effort: "", runner: $runner} |
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
    jq '.reporting.findings_export = "off"' "$config" >"$config.tmp"
    mv -- "$config.tmp" "$config"
    ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"
    printf 'cross-ndjson-rejected\n' >"$scenarios/gamma-cross-review"

    PATH="$fake_bin:$PATH" REVIEW_PR_MOCK_BEHAVIOR=valid-ndjson REVIEW_PR_MOCK_SCENARIO_DIR="$scenarios" REVIEW_PR_MOCK_CAPTURE_DIR="$capture" \
        "$repo_root/bin/review-pr" --config "$config" 123 >"$case_dir/output.txt" 2>"$case_dir/stderr.log" \
        || fail "dispute-resolution pipeline failed: $(tail -3 "$case_dir/stderr.log")"
    manifest=$(latest_manifest "$reviews"); work_dir=${manifest%/*}; stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")
    final_prompt="$capture/final-synthesis-alpha-attempt-1.prompt"
    assert_eq complete "$(jq -r '.status.pipeline' "$manifest")" 'a disputed run completes with resolution records'
    assert_file_contains "$final_prompt" '===== BEGIN REQUIRED RESOLUTIONS =====' 'the finalizer receives the detected disputes'
    assert_file_contains "$final_prompt" '"dispute_id":"dispute:alpha:r01"' 'the disputed primary finding is listed by its stable id'
    assert_file_contains "$final_prompt" 'In its resolution record that is verification_method manual' \
        'a severity judgment is recorded as manual, so the table says what was actually measured'
    assert_file_exists "$work_dir/${stem}-final-resolutions.json" 'the run publishes a resolutions sidecar'
    assert_eq '1' "$(jq '.resolutions | length' "$work_dir/${stem}-final-resolutions.json")" 'one resolution per detected dispute'
    assert_eq "${stem}-final-resolutions.json" "$(jq -r '.artifacts.final_resolutions' "$manifest")" 'the manifest records the resolutions sidecar'
    assert_eq 'true' "$(jq -r '.reporting.dispute_resolution' "$manifest")" 'the manifest records the enabled feature'
    assert_file_contains "$(report_root_of "$work_dir")/${stem}-final.md" '<!-- review-pr:dispute-resolutions -->' 'the final report renders the dispute table'
    assert_file_not_exists "$(report_root_of "$work_dir")/${stem}-fix-list.json" \
        'reporting.findings_export = off publishes no export'
}

run_cross_continuation_case() {
    local case_dir="$suite_root/cross-continuation"
    local reviews="$case_dir/reviews" fake_bin="$case_dir/bin" scenarios="$case_dir/scenarios" capture="$case_dir/captured-prompts"
    local checkout config="$case_dir/config.json" manifest work_dir stem gamma_findings gamma_raw continuation_prompt

    mkdir -p -- "$case_dir" "$reviews" "$fake_bin" "$scenarios" "$capture"
    checkout=$(make_repository "$case_dir")
    export REVIEW_PR_FAKE_REFERENCE_SHA; REVIEW_PR_FAKE_REFERENCE_SHA=$(git -C "$checkout" rev-parse main)
    export REVIEW_PR_FAKE_PULL_HEAD_SHA; REVIEW_PR_FAKE_PULL_HEAD_SHA=$(git --git-dir="$case_dir/origin.git" rev-parse refs/pull/122/head)
    export REVIEW_PR_FAKE_BASE_REF=main REVIEW_PR_FAKE_DEFAULT_BRANCH=main REVIEW_PR_FAKE_PR_BODY='Fixture interrupted cross-review.'
    unset REVIEW_PR_FAKE_DEFAULT_BRANCH_FAILURE
    write_three_agent_config "$config" "$checkout" "$reviews"
    ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"
    printf 'cross-ndjson-stops-early\n' >"$scenarios/gamma-cross-review"

    PATH="$fake_bin:$PATH" REVIEW_PR_MOCK_BEHAVIOR=valid-ndjson REVIEW_PR_MOCK_SCENARIO_DIR="$scenarios" REVIEW_PR_MOCK_CAPTURE_DIR="$capture" \
        "$repo_root/bin/review-pr" --config "$config" 123 >"$case_dir/output.txt" 2>"$case_dir/stderr.log" \
        || fail "interrupted cross-review pipeline failed: $(tail -3 "$case_dir/stderr.log")"
    manifest=$(latest_manifest "$reviews"); work_dir=${manifest%/*}; stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")
    gamma_findings="$work_dir/${stem}-cross-gamma-findings.json"
    gamma_raw="$work_dir/${stem}-cross-gamma-raw.ndjson"
    continuation_prompt="$capture/cross-review-findings-continuation-gamma-attempt-1.prompt"

    assert_eq complete "$(jq -r '.status.pipeline' "$manifest")" \
        'a cross-review that stopped early is continued instead of failing the run'
    assert_eq '2' "$(jq '.findings | length' "$gamma_findings")" \
        'the continued cross-review answers every required source ref'
    assert_eq 'gamma:C-001' "$(jq -r '.findings[0].source_id' "$gamma_findings")" \
        'the finding produced before the interruption keeps its place and its id'
    assert_eq 'gamma:C-002' "$(jq -r '.findings[1].source_id' "$gamma_findings")" \
        'the continued finding is appended after the kept one'
    assert_eq '2' "$(grep -c '"record":"finding"' "$gamma_raw")" \
        'the published raw stream is the merged stream'
    assert_file_exists "$continuation_prompt" 'the continuation runs as its own pass'
    assert_file_contains "$continuation_prompt" '===== BEGIN PENDING SOURCE REFS =====' \
        'the continuation prompt lists only the unanswered refs'
    assert_false 'the continuation prompt does not resend the kept record itself' \
        grep -Fq '"source_id":"gamma:C-001"' "$continuation_prompt"
    assert_file_contains "$continuation_prompt" 'gamma:C-001 already answers' \
        'the continuation prompt names the kept record only as bookkeeping'
    assert_file_exists "$work_dir/${stem}-cross-gamma-error-continuation-attempt-1-source-raw.ndjson" \
        'the interrupted draft is preserved for inspection'
    assert_eq '2' "$(jq -r '.passes | length' "$work_dir/${stem}-cross-gamma-usage.json")" \
        'cross-review usage counts the generation and the continuation pass'
    assert_false 'a continued cross-review does not also run a schema repair' \
        test -e "$work_dir/${stem}-cross-gamma-error-schema-repair-attempt-1-source-raw.ndjson"
}

run_cross_continuation_salvage_case() {
    local case_dir="$suite_root/cross-continuation-failure"
    local reviews="$case_dir/reviews" fake_bin="$case_dir/bin" scenarios="$case_dir/scenarios"
    local checkout config="$case_dir/config.json" manifest work_dir stem report_dir

    mkdir -p -- "$case_dir" "$reviews" "$fake_bin" "$scenarios"
    checkout=$(make_repository "$case_dir")
    export REVIEW_PR_FAKE_REFERENCE_SHA; REVIEW_PR_FAKE_REFERENCE_SHA=$(git -C "$checkout" rev-parse main)
    export REVIEW_PR_FAKE_PULL_HEAD_SHA; REVIEW_PR_FAKE_PULL_HEAD_SHA=$(git --git-dir="$case_dir/origin.git" rev-parse refs/pull/122/head)
    export REVIEW_PR_FAKE_BASE_REF=main REVIEW_PR_FAKE_DEFAULT_BRANCH=main REVIEW_PR_FAKE_PR_BODY='Fixture unusable continuation.'
    unset REVIEW_PR_FAKE_DEFAULT_BRANCH_FAILURE
    write_three_agent_config "$config" "$checkout" "$reviews"
    ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"
    printf 'cross-ndjson-stops-early\n' >"$scenarios/gamma-cross-review"
    printf 'cross-ndjson-ignores-pending\n' >"$scenarios/gamma-cross-review-findings-continuation"

    # A cross-review that stopped early and could not be continued used to take
    # the entire run down with it, hours and four agents after the fact, and the
    # reason lived only in a log. The phase now contributes what the model did
    # write, and the shortfall is recorded where the review is actually read.
    PATH="$fake_bin:$PATH" REVIEW_PR_MOCK_BEHAVIOR=valid-ndjson REVIEW_PR_MOCK_SCENARIO_DIR="$scenarios" \
        "$repo_root/bin/review-pr" --config "$config" 123 >"$case_dir/output.txt" 2>"$case_dir/stderr.log" \
        || fail "a salvaged cross-review must still publish a review: $(tail -3 "$case_dir/stderr.log")"
    manifest=$(latest_manifest "$reviews"); work_dir=${manifest%/*}; stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")
    report_dir=$(report_root_of "$work_dir")
    assert_file_contains "$case_dir/stderr.log" 'continuation_changed_kept_findings_or_remained_invalid' \
        'the run still says why the continuation itself was refused'
    assert_file_exists "$work_dir/${stem}-cross-gamma-error-continuation-attempt-1-invalid-raw.ndjson" \
        'the refused merged stream is preserved for inspection'
    assert_file_exists "$work_dir/${stem}-cross-gamma-findings.json" \
        'the salvaged cross-review publishes the findings it did produce'
    assert_eq 'cross-review' "$(jq -r '.salvage_losses[0].phase' "$manifest")" \
        'the manifest names the phase that had to be salvaged'
    assert_eq gamma "$(jq -r '.salvage_losses[0].agent' "$manifest")" \
        'and the agent whose output it was'
    assert_true 'and counts the source records left unanswered' \
        test "$(jq -r '.salvage_losses[0].unanswered_refs' "$manifest")" -gt 0
    assert_file_contains "$case_dir/stderr.log" 'Kept the cross-review output' \
        'the console says what was kept and what was dropped'
    assert_file_contains "$report_dir/${stem}-final.md" 'Part of the model output had to be dropped' \
        'and the published review carries the loss among its verification limits'
}

run_final_continuation_case() {
    local case_dir="$suite_root/final-continuation"
    local reviews="$case_dir/reviews" fake_bin="$case_dir/bin" scenarios="$case_dir/scenarios" capture="$case_dir/captured-prompts"
    local checkout config="$case_dir/config.json" manifest work_dir stem final_findings continuation_prompt

    mkdir -p -- "$case_dir" "$reviews" "$fake_bin" "$scenarios" "$capture"
    checkout=$(make_repository "$case_dir")
    export REVIEW_PR_FAKE_REFERENCE_SHA; REVIEW_PR_FAKE_REFERENCE_SHA=$(git -C "$checkout" rev-parse main)
    export REVIEW_PR_FAKE_PULL_HEAD_SHA; REVIEW_PR_FAKE_PULL_HEAD_SHA=$(git --git-dir="$case_dir/origin.git" rev-parse refs/pull/122/head)
    export REVIEW_PR_FAKE_BASE_REF=main REVIEW_PR_FAKE_DEFAULT_BRANCH=main REVIEW_PR_FAKE_PR_BODY='Fixture interrupted final synthesis.'
    unset REVIEW_PR_FAKE_DEFAULT_BRANCH_FAILURE
    write_three_agent_config "$config" "$checkout" "$reviews"
    ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"
    printf 'final-ndjson-stops-early\n' >"$scenarios/alpha-final-synthesis"

    PATH="$fake_bin:$PATH" REVIEW_PR_MOCK_BEHAVIOR=valid-ndjson REVIEW_PR_MOCK_SCENARIO_DIR="$scenarios" REVIEW_PR_MOCK_CAPTURE_DIR="$capture" \
        "$repo_root/bin/review-pr" --config "$config" 123 >"$case_dir/output.txt" 2>"$case_dir/stderr.log" \
        || fail "interrupted final synthesis pipeline failed: $(tail -3 "$case_dir/stderr.log")"
    manifest=$(latest_manifest "$reviews"); work_dir=${manifest%/*}; stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")
    final_findings="$work_dir/${stem}-final-findings.json"
    continuation_prompt="$capture/final-findings-continuation-alpha-attempt-1.prompt"

    assert_eq complete "$(jq -r '.status.pipeline' "$manifest")" \
        'a final synthesis that stopped early is continued instead of failing the run'
    assert_eq 'FINAL-001' "$(jq -r '.findings[0].source_id' "$final_findings")" \
        'the final finding produced before the interruption keeps its place'
    assert_eq 'FINAL-002' "$(jq -r '.findings[1].source_id' "$final_findings")" \
        'the continued final finding is appended after the kept one'
    assert_eq '6' "$(jq '[.findings[].source_refs[]] | length' "$final_findings")" \
        'the merged final stream covers every canonical cross-review ref'
    assert_file_exists "$continuation_prompt" 'the final continuation runs as its own pass'
    assert_file_contains "$continuation_prompt" 'INTERRUPTED FINAL SYNTHESIS' \
        'the final continuation prompt names its own phase'
    assert_file_exists "$work_dir/${stem}-final-error-continuation-source-raw.ndjson" \
        'the interrupted final draft is preserved for inspection'
    assert_file_exists "$(report_root_of "$work_dir")/${stem}-final.md" \
        'a continued final synthesis still publishes the report'
}

run_final_retry_case() {
    local case_dir="$suite_root/final-retry"
    local reviews="$case_dir/reviews" fake_bin="$case_dir/bin" scenarios="$case_dir/scenarios"
    local checkout config="$case_dir/config.json" events="$case_dir/events.tsv" manifest work_dir stem

    mkdir -p -- "$case_dir" "$reviews" "$fake_bin" "$scenarios"
    checkout=$(make_repository "$case_dir")
    export REVIEW_PR_FAKE_REFERENCE_SHA; REVIEW_PR_FAKE_REFERENCE_SHA=$(git -C "$checkout" rev-parse main)
    export REVIEW_PR_FAKE_PULL_HEAD_SHA; REVIEW_PR_FAKE_PULL_HEAD_SHA=$(git --git-dir="$case_dir/origin.git" rev-parse refs/pull/122/head)
    export REVIEW_PR_FAKE_BASE_REF=main REVIEW_PR_FAKE_DEFAULT_BRANCH=main REVIEW_PR_FAKE_PR_BODY='Fixture final retry.'
    unset REVIEW_PR_FAKE_DEFAULT_BRANCH_FAILURE
    write_config "$config" "$checkout" "$reviews" 2
    jq '.execution.retry = {max_attempts: 2, delay_seconds: 0}' "$config" >"$config.tmp"
    mv -- "$config.tmp" "$config"
    ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"
    printf 'final-invalid-once\n' >"$scenarios/alpha-final-synthesis"

    PATH="$fake_bin:$PATH" REVIEW_PR_MOCK_BEHAVIOR=valid REVIEW_PR_MOCK_SCENARIO_DIR="$scenarios" \
        REVIEW_PR_MOCK_EVENT_LOG="$events" \
        "$repo_root/bin/review-pr" --config "$config" 123 >"$case_dir/output.txt" 2>"$case_dir/stderr.log" \
        || fail "final retry pipeline failed: $(tail -3 "$case_dir/stderr.log")"
    manifest=$(latest_manifest "$reviews"); work_dir=${manifest%/*}; stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")

    assert_eq complete "$(jq -r '.status.pipeline' "$manifest")" \
        'a final synthesis that produced an off-contract answer is retried'
    assert_eq '2' "$(grep -c '^start.*final-synthesis' "$events")" \
        'the synthesizer ran exactly twice'
    assert_file_exists "$(report_root_of "$work_dir")/${stem}-final.md" 'the retried final synthesis publishes its report'
    assert_file_exists "$work_dir/${stem}-final-error-attempt-1-invalid.md" \
        'the rejected first answer is preserved under its own attempt number'
    assert_file_exists "$work_dir/${stem}-final-error-attempt-1-usage.json" \
        'the failed attempt keeps its own usage record'
    assert_false 'the successful attempt leaves no failure artifacts' \
        bash -c 'ls "$1"/*-final-error-attempt-2-* >/dev/null 2>&1' _ "$work_dir"
}

run_final_no_retry_case() {
    local case_dir="$suite_root/final-no-retry"
    local reviews="$case_dir/reviews" fake_bin="$case_dir/bin" scenarios="$case_dir/scenarios"
    local checkout config="$case_dir/config.json" events="$case_dir/events.tsv"

    mkdir -p -- "$case_dir" "$reviews" "$fake_bin" "$scenarios"
    checkout=$(make_repository "$case_dir")
    export REVIEW_PR_FAKE_REFERENCE_SHA; REVIEW_PR_FAKE_REFERENCE_SHA=$(git -C "$checkout" rev-parse main)
    export REVIEW_PR_FAKE_PULL_HEAD_SHA; REVIEW_PR_FAKE_PULL_HEAD_SHA=$(git --git-dir="$case_dir/origin.git" rev-parse refs/pull/122/head)
    export REVIEW_PR_FAKE_BASE_REF=main REVIEW_PR_FAKE_DEFAULT_BRANCH=main REVIEW_PR_FAKE_PR_BODY='Fixture final without a turn.'
    unset REVIEW_PR_FAKE_DEFAULT_BRANCH_FAILURE
    write_config "$config" "$checkout" "$reviews" 2
    jq '.execution.retry = {max_attempts: 2, delay_seconds: 0}' "$config" >"$config.tmp"
    mv -- "$config.tmp" "$config"
    ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"
    printf 'final-never-starts\n' >"$scenarios/alpha-final-synthesis"

    if PATH="$fake_bin:$PATH" REVIEW_PR_MOCK_BEHAVIOR=valid REVIEW_PR_MOCK_SCENARIO_DIR="$scenarios" \
        REVIEW_PR_MOCK_EVENT_LOG="$events" \
        "$repo_root/bin/review-pr" --config "$config" 123 >"$case_dir/output.txt" 2>"$case_dir/stderr.log"; then
        fail 'a final synthesis that never got a turn must not publish a report'
    fi
    assert_eq '1' "$(grep -c '^start.*final-synthesis' "$events")" \
        'a synthesizer that produced nothing is not run again'
    assert_false 'the run does not announce a retry it did not make' \
        grep -Fq 'queued for retry' "$case_dir/stderr.log"
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
    assert_file_contains "$case_dir/stderr.log" 'dispute_resolution_validation_failed: resolution[dispute:alpha:r01].confirmed_over_unresolved_factual' \
        'the failure names the count-over-measurement violation'
    assert_file_not_exists "$work_dir/${stem}-final-resolutions.json" 'no resolutions sidecar is published for an invalid final'
    assert_file_not_exists "$(report_root_of "$work_dir")/${stem}-final.md" 'no final report is published for an invalid final'
}

run_measured_resolution_case() {
    local case_dir="$suite_root/dispute-measured"
    local reviews="$case_dir/reviews" fake_bin="$case_dir/bin" scenarios="$case_dir/scenarios"
    local checkout config="$case_dir/config.json" manifest work_dir stem sidecar

    mkdir -p -- "$case_dir" "$reviews" "$fake_bin" "$scenarios"
    checkout=$(make_repository "$case_dir")
    export REVIEW_PR_FAKE_REFERENCE_SHA; REVIEW_PR_FAKE_REFERENCE_SHA=$(git -C "$checkout" rev-parse main)
    export REVIEW_PR_FAKE_PULL_HEAD_SHA; REVIEW_PR_FAKE_PULL_HEAD_SHA=$(git --git-dir="$case_dir/origin.git" rev-parse refs/pull/122/head)
    export REVIEW_PR_FAKE_BASE_REF=main REVIEW_PR_FAKE_DEFAULT_BRANCH=main REVIEW_PR_FAKE_PR_BODY='Fixture measured resolution.'
    unset REVIEW_PR_FAKE_DEFAULT_BRANCH_FAILURE
    write_three_agent_config "$config" "$checkout" "$reviews"
    jq '.reporting.execute_measurements = true' "$config" >"$config.tmp" && mv -- "$config.tmp" "$config"
    ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"
    printf 'cross-ndjson-rejected\n' >"$scenarios/gamma-cross-review"
    printf 'final-resolution-measured\n' >"$scenarios/alpha-final-synthesis"

    PATH="$fake_bin:$PATH" REVIEW_PR_MOCK_BEHAVIOR=valid-ndjson REVIEW_PR_MOCK_SCENARIO_DIR="$scenarios" \
        "$repo_root/bin/review-pr" --config "$config" 123 >"$case_dir/output.txt" 2>"$case_dir/stderr.log" \
        || fail "measured-resolution pipeline failed: $(tail -3 "$case_dir/stderr.log")"
    manifest=$(latest_manifest "$reviews"); work_dir=${manifest%/*}; stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")
    sidecar="$work_dir/${stem}-final-resolutions.json"
    assert_eq 'true' "$(jq -r '.resolutions[0].measurement.executed' "$sidecar")" \
        'an allow-listed command proposed by the finalizer is executed in the review checkout'
    assert_eq '0' "$(jq -r '.resolutions[0].measurement.exit_status' "$sidecar")" \
        'the measurement records the command exit status'
    assert_eq "$REVIEW_PR_FAKE_PULL_HEAD_SHA" "$(jq -r '.resolutions[0].measurement.commit' "$sidecar")" \
        'the measurement records the exact PR head it ran against'
    assert_eq 'The changed branch was read directly; the disputed premise holds.' "$(jq -r '.resolutions[0].observed' "$sidecar")" \
        'the model claim in observed is kept separate from the measurement'
    assert_eq 'explicit_repository_rule' "$(jq -r '.resolutions[0].basis' "$sidecar")" \
        'an explicit repository rule basis survives end to end'
    assert_eq 'AGENTS.md' "$(jq -r '.resolutions[0].basis_source' "$sidecar")" \
        'the explicit rule names its repository source'
    assert_file_contains "$(report_root_of "$work_dir")/${stem}-final.md" '| Measured |' 'the final report shows the Measured column'
    assert_file_contains "$(report_root_of "$work_dir")/${stem}-final.md" '| exit 0 |' 'the final report shows the measurement outcome'
    assert_file_contains "$(report_root_of "$work_dir")/${stem}-final.md" 'explicit_repository_rule (`AGENTS.md`)' 'the final report shows the rule source'
}

run_unavailable_measurement_case() {
    local case_dir="$suite_root/dispute-unavailable"
    local reviews="$case_dir/reviews" fake_bin="$case_dir/bin" scenarios="$case_dir/scenarios"
    local checkout config="$case_dir/config.json" manifest work_dir stem sidecar

    mkdir -p -- "$case_dir" "$reviews" "$fake_bin" "$scenarios"
    checkout=$(make_repository "$case_dir")
    export REVIEW_PR_FAKE_REFERENCE_SHA; REVIEW_PR_FAKE_REFERENCE_SHA=$(git -C "$checkout" rev-parse main)
    export REVIEW_PR_FAKE_PULL_HEAD_SHA; REVIEW_PR_FAKE_PULL_HEAD_SHA=$(git --git-dir="$case_dir/origin.git" rev-parse refs/pull/122/head)
    export REVIEW_PR_FAKE_BASE_REF=main REVIEW_PR_FAKE_DEFAULT_BRANCH=main REVIEW_PR_FAKE_PR_BODY='Fixture unavailable measurement.'
    unset REVIEW_PR_FAKE_DEFAULT_BRANCH_FAILURE
    write_three_agent_config "$config" "$checkout" "$reviews"
    jq '.reporting.execute_measurements = true' "$config" >"$config.tmp" && mv -- "$config.tmp" "$config"
    ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"
    printf 'cross-ndjson-rejected\n' >"$scenarios/gamma-cross-review"
    printf 'final-resolution-unavailable\n' >"$scenarios/alpha-final-synthesis"

    PATH="$fake_bin:$PATH" REVIEW_PR_MOCK_BEHAVIOR=valid-ndjson REVIEW_PR_MOCK_SCENARIO_DIR="$scenarios" \
        "$repo_root/bin/review-pr" --config "$config" 123 >"$case_dir/output.txt" 2>"$case_dir/stderr.log" \
        || fail "unavailable-measurement pipeline failed: $(tail -3 "$case_dir/stderr.log")"
    manifest=$(latest_manifest "$reviews"); work_dir=${manifest%/*}; stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")
    sidecar="$work_dir/${stem}-final-resolutions.json"
    assert_eq 'UNCERTAIN' "$(jq -r '.findings[0].classification' "$work_dir/${stem}-final-findings.json")" \
        'a factual dispute whose measurement is unavailable leaves the covering finding UNCERTAIN'
    assert_eq 'uncertain' "$(jq -r '.resolutions[0].resolution_status' "$sidecar")" 'the resolution records the uncertain status'
    assert_eq 'false' "$(jq -r '.resolutions[0].measurement.executed' "$sidecar")" 'a runtime tool proposed by the model is not executed'
    assert_eq 'not_allowlisted' "$(jq -r '.resolutions[0].measurement.skipped_reason' "$sidecar")" 'the skipped measurement names the policy reason'
    assert_file_contains "$(report_root_of "$work_dir")/${stem}-final.md" '| skipped: not_allowlisted |' 'the final report shows the skipped measurement'
}

run_split_claim_resolution_case() {
    local case_dir="$suite_root/dispute-split"
    local reviews="$case_dir/reviews" fake_bin="$case_dir/bin" scenarios="$case_dir/scenarios"
    local checkout config="$case_dir/config.json" manifest work_dir stem sidecar

    mkdir -p -- "$case_dir" "$reviews" "$fake_bin" "$scenarios"
    checkout=$(make_repository "$case_dir")
    export REVIEW_PR_FAKE_REFERENCE_SHA; REVIEW_PR_FAKE_REFERENCE_SHA=$(git -C "$checkout" rev-parse main)
    export REVIEW_PR_FAKE_PULL_HEAD_SHA; REVIEW_PR_FAKE_PULL_HEAD_SHA=$(git --git-dir="$case_dir/origin.git" rev-parse refs/pull/122/head)
    export REVIEW_PR_FAKE_BASE_REF=main REVIEW_PR_FAKE_DEFAULT_BRANCH=main REVIEW_PR_FAKE_PR_BODY='Fixture split compound claim.'
    unset REVIEW_PR_FAKE_DEFAULT_BRANCH_FAILURE
    write_three_agent_config "$config" "$checkout" "$reviews"
    ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"
    printf 'cross-ndjson-split\n' >"$scenarios/gamma-cross-review"
    printf 'final-split-refs\n' >"$scenarios/alpha-final-synthesis"

    PATH="$fake_bin:$PATH" REVIEW_PR_MOCK_BEHAVIOR=valid-ndjson REVIEW_PR_MOCK_SCENARIO_DIR="$scenarios" \
        "$repo_root/bin/review-pr" --config "$config" 123 >"$case_dir/output.txt" 2>"$case_dir/stderr.log" \
        || fail "split-claim pipeline failed: $(tail -3 "$case_dir/stderr.log")"
    manifest=$(latest_manifest "$reviews"); work_dir=${manifest%/*}; stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")
    sidecar="$work_dir/${stem}-final-resolutions.json"
    assert_eq '3' "$(jq -r '.disputes[0].conflicting_refs | length' "$sidecar")" \
        'a compound claim split by one cross-reviewer yields a dispute over all three cross records'
    assert_eq 'severity' "$(jq -r '.disputes[0].kind_hint' "$sidecar")" \
        'confirmed records with different severities are detected as a severity dispute'
    assert_eq '2' "$(jq -r '.finding_count' "$work_dir/${stem}-final-findings.json")" \
        'the finalizer may keep the split topics as separate final records'
    assert_eq 'FINAL-001' "$(jq -r '.resolutions[0].final_source_id' "$sidecar")" \
        'the resolution names the final record that carries the decision even though it covers only part of the refs'
    assert_eq 'complete' "$(jq -r '.status.pipeline' "$manifest")" 'the split-claim run completes'
}

run_diagnostics_case() {
    local case_dir="$suite_root/diagnostics"
    local reviews="$case_dir/reviews" fake_bin="$case_dir/bin" scenarios="$case_dir/scenarios" capture="$case_dir/captured-prompts"
    local checkout config="$case_dir/config.json" manifest work_dir stem sidecar final_report

    mkdir -p -- "$case_dir" "$reviews" "$fake_bin" "$scenarios" "$capture"
    checkout=$(make_repository "$case_dir")
    export REVIEW_PR_FAKE_REFERENCE_SHA; REVIEW_PR_FAKE_REFERENCE_SHA=$(git -C "$checkout" rev-parse main)
    export REVIEW_PR_FAKE_PULL_HEAD_SHA; REVIEW_PR_FAKE_PULL_HEAD_SHA=$(git --git-dir="$case_dir/origin.git" rev-parse refs/pull/122/head)
    export REVIEW_PR_FAKE_BASE_REF=main REVIEW_PR_FAKE_DEFAULT_BRANCH=main REVIEW_PR_FAKE_PR_BODY='Fixture diagnostics.'
    export REVIEW_PR_FAKE_REVIEW_THREADS_FAILURE=true
    export REVIEW_PR_FAKE_CHECK_RUNS_JSON='{"check_runs":[{"id":11,"name":"phpunit","status":"completed","conclusion":"failure","output":{"annotations_count":2}},{"name":"lint","status":"completed","conclusion":"success"},{"name":"phpstan","status":"in_progress","conclusion":null}]}'
    # The second read settles the check that was still running at the start.
    export REVIEW_PR_FAKE_CHECK_RUNS_REFRESH_JSON='{"check_runs":[{"id":11,"name":"phpunit","status":"completed","conclusion":"failure","output":{"annotations_count":2}},{"name":"lint","status":"completed","conclusion":"success"},{"name":"phpstan","status":"completed","conclusion":"success"}]}'
    export REVIEW_PR_FAKE_CHECK_RUNS_STATE="$case_dir/check-runs-read"
    export REVIEW_PR_FAKE_CHECK_ANNOTATIONS_JSON='[{"annotation_level":"failure","path":"src/Changed.php","start_line":10,"end_line":10,"message":"Failed asserting that null matches expected 1."},{"annotation_level":"warning","path":"src/Changed.php","start_line":12,"end_line":12,"message":"This changed line is not covered by any test."}]'
    unset REVIEW_PR_FAKE_DEFAULT_BRANCH_FAILURE
    write_three_agent_config "$config" "$checkout" "$reviews"
    jq '.execution.retry.max_attempts = 2' "$config" >"$config.tmp" && mv -- "$config.tmp" "$config"
    ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"
    printf 'fail-once\n' >"$scenarios/beta-primary-review"

    PATH="$fake_bin:$PATH" REVIEW_PR_MOCK_BEHAVIOR=valid-ndjson REVIEW_PR_MOCK_SCENARIO_DIR="$scenarios" REVIEW_PR_MOCK_CAPTURE_DIR="$capture" \
        REVIEW_PR_MOCK_PRIMARY_LIMITATION='Could not run the fixture test suite.' \
        "$repo_root/bin/review-pr" --config "$config" 123 >"$case_dir/output.txt" 2>"$case_dir/stderr.log" \
        || fail "diagnostics pipeline failed: $(tail -3 "$case_dir/stderr.log")"
    unset REVIEW_PR_FAKE_REVIEW_THREADS_FAILURE REVIEW_PR_FAKE_CHECK_RUNS_JSON \
        REVIEW_PR_FAKE_CHECK_RUNS_REFRESH_JSON REVIEW_PR_FAKE_CHECK_RUNS_STATE REVIEW_PR_FAKE_CHECK_ANNOTATIONS_JSON
    manifest=$(latest_manifest "$reviews"); work_dir=${manifest%/*}; stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")
    sidecar="$work_dir/${stem}-final-diagnostics.json"
    final_report="$(report_root_of "$work_dir")/${stem}-final.md"
    assert_eq complete "$(jq -r '.status.pipeline' "$manifest")" 'a run with a failed check, unavailable threads, and a retried agent still completes'
    assert_eq 'agent_attempt_failed,github_check_failed,github_review_threads_unavailable' \
        "$(jq -r '[.orchestrator[].type] | unique | join(",")' "$sidecar")" \
        'the diagnostics sidecar records exactly the orchestrator-measured limitations'
    assert_eq 'phpunit: failure' "$(jq -r '.orchestrator[] | select(.type == "github_check_failed") | .detail' "$sidecar")" \
        'a failed check records its name and conclusion'
    assert_eq 'beta' "$(jq -r '.orchestrator[] | select(.type == "agent_attempt_failed") | .agent' "$sidecar")" \
        'a failed attempt names its agent'
    assert_eq '1' "$(jq '.reviewers | length' "$sidecar")" 'the same limitation from three primaries merges into one entry'
    assert_eq 'alpha,beta,gamma' "$(jq -r '.reviewers[0].agents | join(",")' "$sidecar")" 'the merged limitation keeps every contributing agent'
    assert_eq 'primary' "$(jq -r '.reviewers[0].phases | join(",")' "$sidecar")" 'the merged limitation keeps its phase'
    assert_eq 'alpha,beta,gamma' "$(jq -r '.positive_evidence[0].agents | join(",")' "$sidecar")" 'shared positive evidence merges with its agents'
    assert_file_contains "$capture/final-synthesis-alpha-attempt-1.prompt" '"type":"github_check_failed"' \
        'the finalizer sees the failed check in KNOWN LIMITATIONS'
    # A check's annotations say which line failed, which a bare conclusion cannot.
    assert_file_contains "$work_dir/${stem}-github-context.md" 'Failed asserting that null matches expected 1.' \
        'reviewers receive the annotations a failing check produced'
    assert_file_contains "$work_dir/${stem}-github-context.md" 'src/Changed.php:10' \
        'an annotation carries the exact file and line it points at'
    # The snapshot keeps what was true when the reviewers read it.
    assert_file_contains "$work_dir/${stem}-github-context.md" 'Conclusion: `pending`' \
        'the snapshot reviewers received records the check that was still running'
    # The finalizer reads the settled state instead of the opening snapshot.
    assert_false 'a check that finished during the run is not reported to the finalizer as pending' \
        grep -Fq '"type":"github_check_pending"' "$capture/final-synthesis-alpha-attempt-1.prompt"
    assert_file_contains "$final_report" '<!-- review-pr:verification-limitations -->' 'the final report renders the limitations section'
    assert_file_contains "$final_report" '**CI check failed:** phpunit: failure' 'the final report shows the failed check'
    assert_file_contains "$final_report" 'Could not run the fixture test suite. (alpha, beta, gamma)' 'the final report shows the merged reviewer limitation'
    assert_file_contains "$final_report" '<!-- review-pr:positive-evidence -->' 'the final report renders the positive-evidence section'
    assert_file_contains "$final_report" 'The fixture remains intentionally small. (alpha, beta, gamma)' 'the final report shows merged positive evidence'
}

run_diagnostic_only_finding_case() {
    local case_dir="$suite_root/diagnostic-only-finding"
    local reviews="$case_dir/reviews" fake_bin="$case_dir/bin" scenarios="$case_dir/scenarios"
    local checkout config="$case_dir/config.json" manifest work_dir stem

    mkdir -p -- "$case_dir" "$reviews" "$fake_bin" "$scenarios"
    checkout=$(make_repository "$case_dir")
    export REVIEW_PR_FAKE_REFERENCE_SHA; REVIEW_PR_FAKE_REFERENCE_SHA=$(git -C "$checkout" rev-parse main)
    export REVIEW_PR_FAKE_PULL_HEAD_SHA; REVIEW_PR_FAKE_PULL_HEAD_SHA=$(git --git-dir="$case_dir/origin.git" rev-parse refs/pull/122/head)
    export REVIEW_PR_FAKE_BASE_REF=main REVIEW_PR_FAKE_DEFAULT_BRANCH=main REVIEW_PR_FAKE_PR_BODY='Fixture diagnostic-only finding.'
    unset REVIEW_PR_FAKE_DEFAULT_BRANCH_FAILURE
    write_three_agent_config "$config" "$checkout" "$reviews"
    ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"
    printf 'final-diagnostic-only\n' >"$scenarios/alpha-final-synthesis"
    printf 'final-diagnostic-only\n' >"$scenarios/alpha-final-findings-repair"

    if PATH="$fake_bin:$PATH" REVIEW_PR_MOCK_BEHAVIOR=valid-ndjson REVIEW_PR_MOCK_SCENARIO_DIR="$scenarios" \
        "$repo_root/bin/review-pr" --config "$config" 123 >"$case_dir/output.txt" 2>"$case_dir/stderr.log"; then
        fail 'a final finding whose only evidence is a check outcome must fail final synthesis'
    fi
    pass 'a final finding whose only evidence is a check outcome fails final synthesis'
    manifest=$(latest_manifest "$reviews"); work_dir=${manifest%/*}; stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")
    assert_file_contains "$case_dir/stderr.log" 'diagnostic_only_finding: finding[FINAL-001]' 'the failure names the diagnostic-only finding'
    assert_file_not_exists "$work_dir/${stem}-final-diagnostics.json" 'no diagnostics sidecar is published for an invalid final'
    assert_file_not_exists "$(report_root_of "$work_dir")/${stem}-final.md" 'no final report is published for an invalid final'
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

# Every phase may open with a line of prose -- Codex nearly always does, because
# its progress notes are messages of their own and are joined with the answer.
# The line is dropped without a model, so no phase pays a repair pass for it.
run_ndjson_preamble_case() {
    local case_dir="$suite_root/ndjson-preamble"
    local reviews="$case_dir/reviews" fake_bin="$case_dir/bin" scenarios="$case_dir/scenarios"
    local capture="$case_dir/captured-prompts" checkout config="$case_dir/config.json"
    local config_temp="$case_dir/config.tmp.json" manifest work_dir stem

    mkdir -p -- "$case_dir" "$reviews" "$fake_bin" "$scenarios" "$capture"
    checkout=$(make_repository "$case_dir")
    export REVIEW_PR_FAKE_REFERENCE_SHA
    REVIEW_PR_FAKE_REFERENCE_SHA=$(git -C "$checkout" rev-parse main)
    export REVIEW_PR_FAKE_PULL_HEAD_SHA
    REVIEW_PR_FAKE_PULL_HEAD_SHA=$(git --git-dir="$case_dir/origin.git" rev-parse refs/pull/122/head)
    export REVIEW_PR_FAKE_BASE_REF=main REVIEW_PR_FAKE_DEFAULT_BRANCH=main
    unset REVIEW_PR_FAKE_DEFAULT_BRANCH_FAILURE
    export REVIEW_PR_FAKE_PR_BODY='Fixture structured preamble.'
    write_config "$config" "$checkout" "$reviews" 2
    jq '.reporting.finding_contract = {primary: "ndjson-v1", cross_review: "ndjson-v1", final: "ndjson-v1"} |
        .reporting.comparison_sections = {cross_review: "none", final: "none"}' "$config" >"$config_temp"
    mv -- "$config_temp" "$config"
    ln -s "$test_dir/fake-gh.sh" "$fake_bin/gh"
    printf '%s\n' ndjson-preamble >"$scenarios/beta-primary-review"
    printf '%s\n' cross-ndjson-preamble >"$scenarios/beta-cross-review"
    printf '%s\n' final-ndjson-preamble >"$scenarios/alpha-final-synthesis"

    PATH="$fake_bin:$PATH" REVIEW_PR_MOCK_BEHAVIOR=valid-ndjson REVIEW_PR_MOCK_SCENARIO_DIR="$scenarios" \
        REVIEW_PR_MOCK_CAPTURE_DIR="$capture" \
        "$repo_root/bin/review-pr" --config "$config" 123 >"$case_dir/output.txt" 2>"$case_dir/stderr.log" \
        || fail "a preamble must not stop a structured run: $(tail -3 "$case_dir/stderr.log")"
    manifest=$(latest_manifest "$reviews")
    work_dir=${manifest%/*}
    stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")
    assert_eq complete "$(jq -r '.status.pipeline' "$manifest")" \
        'a run whose every phase opened with prose completes'
    assert_eq '' "$(find "$capture" -name '*-repair-*.prompt' -print)" \
        'and no phase needed a repair pass for it'
    assert_eq 'false' "$(jq -r 'has("passes")' "$work_dir/${stem}-beta-usage.json")" \
        'the primary review cost one pass: its usage merges no repair pass into it'
    assert_file_contains "$case_dir/stderr.log" 'Dropped 1 line of prose ahead of the first record in the primary stream from beta' \
        'the console says what was dropped'
    assert_file_contains "$case_dir/stderr.log" 'in the cross-review stream from beta' \
        'in the cross-review'
    assert_file_contains "$case_dir/stderr.log" 'in the final stream from alpha' \
        'and in the final synthesis'
    assert_file_contains "$work_dir/${stem}-beta-raw.ndjson" 'Here is the requested structured review:' \
        'the raw artifact still holds what the model wrote'
    assert_eq 'The fixture changed branch can fail.' \
        "$(jq -r '.findings[0].claim' "$work_dir/${stem}-beta-findings.json")" \
        'and the findings behind the prose are all there'
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
    printf '%s\n' 'ndjson-trailing-prose' >"$scenarios/beta-primary-review"
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
    assert_file_contains "$source_diagnostic" 'That completes the requested structured review.' \
        'preserved source response retains the invalid transport prose'
    assert_false 'canonical raw response excludes repaired transport prose' \
        grep -Fq -- 'That completes the requested structured review.' "$work_dir/${stem}-beta-raw.ndjson"
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
    printf '%s\n' 'ndjson-trailing-prose' >"$scenarios/beta-primary-review"
    printf '%s\n' 'unsafe-ndjson-repair' >"$scenarios/beta-primary-findings-repair"

    # The repair rewrote a finding instead of reformatting it, so its output is
    # thrown away as it always was. What changed is what happens next: the run no
    # longer dies with it. Salvage falls back on the model's own first answer --
    # here a perfectly good stream with a line of prose after it -- and publishes that.
    # The guard being tested is unchanged: the rewritten claim must not appear.
    PATH="$fake_bin:$PATH" \
        REVIEW_PR_MOCK_BEHAVIOR=valid-ndjson \
        REVIEW_PR_MOCK_SCENARIO_DIR="$scenarios" \
        "$repo_root/bin/review-pr" --config "$config" 123 \
        >"$case_dir/output.txt" 2>"$case_dir/stderr.log" \
        || fail "a salvaged primary review must still publish: $(tail -3 "$case_dir/stderr.log")"

    manifest=$(latest_manifest "$reviews")
    work_dir=${manifest%/*}
    stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")
    rejected_repair=$(find "$work_dir" -type f -name '*primary-beta-error-schema-repair-attempt-1-invalid-raw.ndjson' -print | sed -n '1p')
    [[ -n "$rejected_repair" ]] || fail 'unsafe repair did not preserve the repair response'
    pass 'unsafe repair preserves the rejected repair response'
    assert_file_contains "$rejected_repair" 'The repair rewrote the finding claim.' \
        'unsafe repair diagnostic exposes the changed substantive field'
    assert_file_contains "$work_dir/${stem}-beta-raw.ndjson" 'That completes the requested structured review.' \
        'the original response is kept whole, prose and all, as the published raw stream'
    assert_file_exists "$work_dir/${stem}-beta-findings.json" \
        'the salvaged primary review publishes the findings the model first wrote'
    assert_false 'and the claim the repair rewrote is nowhere in them' \
        grep -Fq 'The repair rewrote the finding claim.' "$work_dir/${stem}-beta-findings.json"
    assert_eq 'primary review' "$(jq -r '.salvage_losses[0].phase' "$manifest")" \
        'the manifest records that the primary review had to be salvaged'
    assert_eq 1 "$(jq -r '.salvage_losses[0].unparseable_lines' "$manifest")" \
        'and counts the line of prose it could not read'
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
    printf '%s\n' final-ndjson-trailing-prose >"$scenarios/alpha-final-synthesis"
    printf '%s\n' unsafe-final-ndjson-repair >"$scenarios/alpha-final-findings-repair"

    # The repair changed decisions instead of reformatting them, so it is thrown
    # away exactly as before. The run continues on the synthesizer's own first
    # answer -- a good stream with a line of prose after it -- because losing a
    # finished final synthesis over one stray line costs everything the run spent.
    PATH="$fake_bin:$PATH" REVIEW_PR_MOCK_BEHAVIOR=valid-ndjson REVIEW_PR_MOCK_SCENARIO_DIR="$scenarios" \
        "$repo_root/bin/review-pr" --config "$config" 123 >"$case_dir/output.txt" 2>"$case_dir/stderr.log" \
        || fail "a salvaged final synthesis must still publish: $(tail -3 "$case_dir/stderr.log")"
    manifest=$(latest_manifest "$reviews")
    work_dir=${manifest%/*}
    stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")
    assert_file_exists "$(report_root_of "$work_dir")/${stem}-final.md" \
        'the salvaged final synthesis publishes the report the model first wrote'
    assert_file_exists "$work_dir/${stem}-final-findings.json" \
        'and its canonical findings'
    assert_false 'while the decisions the repair rewrote are nowhere in them' \
        grep -Fq '"classification":"UNCERTAIN"' "$work_dir/${stem}-final-findings.json"
    assert_file_exists "$work_dir/${stem}-final-error-schema-repair-invalid-raw.ndjson" \
        'unsafe final repair preserves the content-changing repair response'
    assert_file_contains "$case_dir/stderr.log" 'repair_changed_decisions_provenance_or_content' \
        'unsafe final repair still reports its stability violation'
    assert_eq 'final synthesis' "$(jq -r '.salvage_losses[0].phase' "$manifest")" \
        'the manifest records that the final synthesis had to be salvaged'
    assert_eq 1 "$(jq -r '.salvage_losses[0].unparseable_lines' "$manifest")" \
        'and counts the line of prose it could not read'
    # The final is rendered by the pass that salvages it, before that pass writes
    # the loss to the manifest. Read from the manifest alone, the one report whose
    # loss matters most would be the one that said nothing about it.
    assert_file_contains "$(report_root_of "$work_dir")/${stem}-final.md" 'Part of the model output had to be dropped' \
        'and the salvaged final itself says what it dropped'
    assert_eq 1 "$(jq '[.salvage_losses[] | select(.phase == "final synthesis")] | length' "$manifest")" \
        'recorded once, not again when the manifest is written after publishing'
}

# Shared setup for the quorum and fallback cases: three mock reviewers, a fresh
# repository, and a scenario directory the caller fills in.
prepare_quorum_case() {
    local case_dir=$1 body=$2
    QUORUM_REVIEWS="$case_dir/reviews" QUORUM_BIN="$case_dir/bin"
    QUORUM_SCENARIOS="$case_dir/scenarios" QUORUM_CAPTURE="$case_dir/captured-prompts"
    QUORUM_CONFIG="$case_dir/config.json"
    mkdir -p -- "$case_dir" "$QUORUM_REVIEWS" "$QUORUM_BIN" "$QUORUM_SCENARIOS" "$QUORUM_CAPTURE"
    QUORUM_CHECKOUT=$(make_repository "$case_dir")
    export REVIEW_PR_FAKE_REFERENCE_SHA; REVIEW_PR_FAKE_REFERENCE_SHA=$(git -C "$QUORUM_CHECKOUT" rev-parse main)
    export REVIEW_PR_FAKE_PULL_HEAD_SHA; REVIEW_PR_FAKE_PULL_HEAD_SHA=$(git --git-dir="$case_dir/origin.git" rev-parse refs/pull/122/head)
    export REVIEW_PR_FAKE_BASE_REF=main REVIEW_PR_FAKE_DEFAULT_BRANCH=main REVIEW_PR_FAKE_PR_BODY=$body
    unset REVIEW_PR_FAKE_DEFAULT_BRANCH_FAILURE
    write_three_agent_config "$QUORUM_CONFIG" "$QUORUM_CHECKOUT" "$QUORUM_REVIEWS"
    jq '.reporting.dispute_resolution = false | .reporting.findings_export = "off"' "$QUORUM_CONFIG" >"$QUORUM_CONFIG.tmp"
    mv -- "$QUORUM_CONFIG.tmp" "$QUORUM_CONFIG"
    ln -s "$test_dir/fake-gh.sh" "$QUORUM_BIN/gh"
}

run_quorum_case() {
    local case_dir=$1
    PATH="$QUORUM_BIN:$PATH" REVIEW_PR_MOCK_BEHAVIOR=valid-ndjson REVIEW_PR_MOCK_SCENARIO_DIR="$QUORUM_SCENARIOS" \
        REVIEW_PR_MOCK_CAPTURE_DIR="$QUORUM_CAPTURE" \
        "$repo_root/bin/review-pr" --config "$QUORUM_CONFIG" 123 >"$case_dir/output.txt" 2>"$case_dir/stderr.log"
}

# The case that cost 29031 its final: every primary review and all but one
# cross-review finished, and one reviewer failed. Two reviewers are still enough
# for every finding to be checked by someone other than its author.
run_quorum_cross_case() {
    local case_dir="$suite_root/quorum-cross" manifest work_dir stem rerun_manifest

    prepare_quorum_case "$case_dir" 'Fixture quorum cross-review.'
    printf 'nonzero\n' >"$QUORUM_SCENARIOS/gamma-cross-review"
    run_quorum_case "$case_dir" \
        || fail "one failed cross-reviewer out of three must not stop the run: $(tail -3 "$case_dir/stderr.log")"
    manifest=$(latest_manifest "$QUORUM_REVIEWS"); work_dir=${manifest%/*}; stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")
    assert_file_exists "$(report_root_of "$work_dir")/${stem}-final.md" \
        'the final is written from the cross-reviews that finished'
    assert_eq 'cross-review gamma' "$(jq -r '.agent_losses[0] | .phase + " " + .agent' "$manifest")" \
        'the manifest names the reviewer the run went on without'
    assert_file_contains "$case_dir/stderr.log" 'Continuing without gamma for the cross-review' \
        'the console says who was left out'
    assert_file_contains "$(report_root_of "$work_dir")/${stem}-final.md" 'A reviewer dropped out of the run' \
        'and the published review says so among its verification limits'
    assert_false "the finalizer is not handed a cross-review that does not exist" \
        grep -Fq -- 'CANONICAL CROSS-REVIEW FINDINGS: gamma' "$QUORUM_CAPTURE/final-synthesis-alpha-attempt-1.prompt"
    assert_file_contains "$QUORUM_CAPTURE/final-synthesis-alpha-attempt-1.prompt" 'CANONICAL CROSS-REVIEW FINDINGS: beta' \
        'while the ones that finished are all there'

    # A final rerun of that run works from the cross-reviews it has. It used to
    # ask for gamma's as well and die on a report that was never written, and
    # "--run last" reached the artifact-only rerun without being resolved.
    PATH="$QUORUM_BIN:$PATH" REVIEW_PR_MOCK_BEHAVIOR=valid-ndjson REVIEW_PR_MOCK_SCENARIO_DIR="$QUORUM_SCENARIOS" \
        REVIEW_PR_MOCK_CAPTURE_DIR="$QUORUM_CAPTURE/rerun" \
        "$repo_root/bin/review-pr" --config "$QUORUM_CONFIG" --rerun-final --run last 123 \
        >"$case_dir/rerun-output.txt" 2>"$case_dir/rerun-stderr.log" \
        || fail "a final rerun of a run that went on without a reviewer must succeed: $(tail -3 "$case_dir/rerun-stderr.log")"
    assert_file_contains "$case_dir/rerun-stderr.log" \
        "Selected the most recent completed run of PR #123: $(jq -r '.timestamp' "$manifest")" \
        'an artifact-only rerun resolves --run last to the newest completed run'
    rerun_manifest=$(find "$work_dir" -type f -name '*-final-rerun-*-manifest.json' -print | sed -n '1p')
    [[ -n "$rerun_manifest" ]] || fail 'the final rerun of a quorum-saved run wrote no manifest'
    assert_eq 'alpha beta' "$(jq -r '.inputs.cross_review | keys | join(" ")' "$rerun_manifest")" \
        'the rerun is given the cross-reviews that exist'
    assert_false 'and its finalizer is not handed the one that does not' \
        grep -Fq -- 'CANONICAL CROSS-REVIEW FINDINGS: gamma' "$QUORUM_CAPTURE/rerun/final-synthesis-alpha-attempt-1.prompt"
    assert_eq 'cross-review gamma' "$(jq -r '.agent_losses[0] | .phase + " " + .agent' "$rerun_manifest")" \
        'the rerun inherits the record of the reviewer the source run went on without'
    assert_file_contains "$(report_root_of "$work_dir")/$(jq -r '.artifact' "$rerun_manifest")" 'A reviewer dropped out of the run' \
        'so the rerun report names the same gap as the report it replaces'
}

# A reviewer that fails its primary review has no findings for anyone to check,
# so it takes no part in cross-review and its report is not handed round.
run_quorum_primary_case() {
    local case_dir="$suite_root/quorum-primary" manifest work_dir stem

    prepare_quorum_case "$case_dir" 'Fixture quorum primary review.'
    printf 'nonzero\n' >"$QUORUM_SCENARIOS/gamma-primary-review"
    run_quorum_case "$case_dir" \
        || fail "one failed primary reviewer out of three must not stop the run: $(tail -3 "$case_dir/stderr.log")"
    manifest=$(latest_manifest "$QUORUM_REVIEWS"); work_dir=${manifest%/*}; stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")
    assert_eq 'primary review gamma' "$(jq -r '.agent_losses[0] | .phase + " " + .agent' "$manifest")" \
        'the loss is recorded against the primary review'
    assert_file_not_exists "$QUORUM_CAPTURE/cross-review-gamma-attempt-1.prompt" \
        'a reviewer with no primary report is not asked to cross-review'
    assert_false 'and no other reviewer is handed its missing report' \
        grep -Fq -- 'CANONICAL PRIMARY FINDINGS: gamma' "$QUORUM_CAPTURE/cross-review-alpha-attempt-1.prompt"
    assert_file_exists "$(report_root_of "$work_dir")/${stem}-final.md" \
        'the run still reaches a published final'
}

# With one reviewer left, its own findings would have nobody to check them and
# would drop out of the final unseen. That is the one loss the run refuses.
run_quorum_below_case() {
    local case_dir="$suite_root/quorum-below" manifest work_dir stem

    prepare_quorum_case "$case_dir" 'Fixture below quorum.'
    printf 'nonzero\n' >"$QUORUM_SCENARIOS/beta-cross-review"
    printf 'nonzero\n' >"$QUORUM_SCENARIOS/gamma-cross-review"
    if run_quorum_case "$case_dir"; then
        fail 'a single finished cross-review must stop the run'
    fi
    pass 'a single finished cross-review stops the run'
    manifest=$(latest_manifest "$QUORUM_REVIEWS"); work_dir=${manifest%/*}; stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")
    assert_file_contains "$case_dir/stderr.log" 'the quorum is 2' \
        'the console says the quorum was not met'
    assert_file_not_exists "$(report_root_of "$work_dir")/${stem}-final.md" \
        'and no final is published from one reviewer'
}

# Final synthesis is the one phase nobody can stand in for, so a different agent
# takes it over once the synthesizer has used up its attempts.
run_fallback_synthesis_case() {
    local case_dir="$suite_root/fallback-synthesis" manifest work_dir stem

    prepare_quorum_case "$case_dir" 'Fixture fallback synthesis.'
    jq '.finalization.fallback_synthesizer = "beta" | .finalization.fallback_model = "mock-strong"' "$QUORUM_CONFIG" >"$QUORUM_CONFIG.tmp"
    mv -- "$QUORUM_CONFIG.tmp" "$QUORUM_CONFIG"
    printf 'nonzero\n' >"$QUORUM_SCENARIOS/alpha-final-synthesis"
    run_quorum_case "$case_dir" \
        || fail "a failed synthesizer with a fallback configured must still publish: $(tail -3 "$case_dir/stderr.log")"
    manifest=$(latest_manifest "$QUORUM_REVIEWS"); work_dir=${manifest%/*}; stem=$(jq -r '.review_id + "-" + .timestamp' "$manifest")
    assert_file_exists "$(report_root_of "$work_dir")/${stem}-final.md" \
        'the fallback writes the final'
    assert_eq 'alpha beta mock-strong' "$(jq -r '.final_fallback | .from + " " + .to + " " + .model' "$manifest")" \
        'the manifest records who failed, who took over, and on which model'
    assert_file_exists "$QUORUM_CAPTURE/final-synthesis-beta-attempt-1.prompt" \
        'the fallback is given a prompt of its own'
    assert_file_contains "$QUORUM_CAPTURE/final-synthesis-beta-attempt-1.prompt" 'Synthesizer: Beta (beta)' \
        'built for it, not the one made for the synthesizer that failed'
    assert_file_contains "$case_dir/stderr.log" 'handing it to Beta on mock-strong' \
        'the console says the synthesis was handed over'
    assert_eq 'alpha' "$(jq -r '.final_fallback.from' "$manifest")" \
        'the manifest names the synthesizer that failed'
    assert_file_contains "$(report_root_of "$work_dir")/${stem}-final.md" 'after alpha on ' \
        'and the report says which model failed, so a same-agent handover still reads clearly'
    assert_file_contains "$(report_root_of "$work_dir")/${stem}-final.md" 'The final synthesis was written by the fallback agent' \
        'and the published review says who actually wrote it'
}

run_full_success_case
run_ndjson_primary_case
run_ndjson_cross_case
run_dispute_resolution_case
run_dispute_resolution_failure_case
run_cross_continuation_case
run_cross_continuation_salvage_case
run_quorum_cross_case
run_quorum_primary_case
run_quorum_below_case
run_fallback_synthesis_case
run_final_continuation_case
run_final_retry_case
run_final_no_retry_case
run_measured_resolution_case
run_unavailable_measurement_case
run_split_claim_resolution_case
run_ndjson_cross_resume_case
run_ndjson_preamble_case
run_ndjson_schema_repair_case
run_ndjson_unsafe_schema_repair_case
run_ndjson_resume_case
run_ndjson_unsafe_final_repair_case
run_diagnostics_case
run_diagnostic_only_finding_case
run_resume_case
run_comparison_failure_case
run_facts_collection_failure_case
run_anchor_repair_case
run_unsafe_anchor_repair_case
run_interrupt_case

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
