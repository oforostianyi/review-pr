#!/usr/bin/env bash
# The prune subcommand compresses what agents streamed and logged for pull
# requests that are merged or closed, removes temporary files killed runs left,
# and touches nothing else.

set -euo pipefail

test_dir=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo_root=$(cd -P -- "$test_dir/../.." && pwd -P)
source "$test_dir/lib/assert.sh"

suite_root=$(portable_mktemp_dir review-pr-prune)
running_pid=""
trap '[[ -z "$running_pid" ]] || kill "$running_pid" 2>/dev/null || true; rm -rf -- "$suite_root"' EXIT

reviews="$suite_root/reviews"
checkout="$suite_root/checkout"
config="$suite_root/config.json"
fake_bin="$suite_root/bin"
mkdir -p -- "$checkout" "$fake_bin"

jq -n --arg checkout "$checkout" --arg reviews "$reviews" '{
    agents: {
        alpha: {"label": "Alpha", enabled: true, model: "mock-alpha", effort: "low"},
        beta: {"label": "Beta", enabled: true, model: "mock-beta", effort: "low"}
    },
    reviewers: ["alpha", "beta"],
    synthesizer: "alpha",
    default_repository: "fixture",
    repositories: {fixture: {github: "Example/Repository", checkout: $checkout}},
    reviews_directory: $reviews,
    language: "EN",
    finalization: {model: "mock-final", effort: "low"}
}' >"$config"

# GitHub answers the state of the pull requests listed in $FAKE_PR_STATES and
# leaves out any other, as it does for a number it does not know.
cat >"$fake_bin/gh" <<'FAKE'
#!/usr/bin/env bash
[[ "$1 $2" == "api graphql" ]] || exit 64
query=${4#query=}
printf '%s\n' "$query" >>"$FAKE_GH_QUERIES"
numbers=$(grep -o 'p[0-9]*:' <<<"$query" | tr -d 'p:')
jq -n --rawfile states "$FAKE_PR_STATES" --arg numbers "$numbers" '
    ($states | split("\n") | map(select(length > 0) | split(" ") | {key: .[0], value: .[1]}) | from_entries) as $known
    | {data: {repository: ([$numbers | split("\n")[] | select(length > 0) | select($known[.])
        | {key: ("p" + .), value: {state: $known[.]}}] | from_entries)}}'
FAKE
chmod +x "$fake_bin/gh"
export FAKE_PR_STATES="$suite_root/states.txt"
export FAKE_GH_QUERIES="$suite_root/queries.txt"
printf '100 MERGED\n101 OPEN\n102 CLOSED\n' >"$FAKE_PR_STATES"
PATH="$fake_bin:$PATH"

# One review per state. 100 records its repository in its manifest, 102 only in
# the folder it sits in, and GitHub does not know 103.
write_review() {
    local number=$1 manifest=$2
    local dir="$reviews/example-repository/${number}-task" run="20261001-120000-CEST"
    local stem="${number}-task-${run}"
    mkdir -p -- "$dir/work/$run"
    printf 'report\n' >"$dir/${stem}-final.md"
    printf '{}\n' >"$dir/${stem}-fix-list.json"
    printf 'event %s\n' "$number" >"$dir/work/$run/${stem}-primary-pi-error-attempt-1-events.jsonl"
    printf 'log %s\n' "$number" >"$dir/work/$run/${stem}-primary-pi-error-attempt-1.log"
    printf '{"tokens": 1}\n' >"$dir/work/$run/${stem}-primary-pi-error-attempt-1-usage.json"
    printf '{"findings": []}\n' >"$dir/work/$run/${stem}-final-findings.json"
    printf 'prompt\n' >"$dir/work/$run/${stem}-primary-prompt.md"
    printf 'partial\n' >"$dir/work/$run/.${stem}-amendment-reply.tmp.Ab12Cd"
    if [[ "$manifest" == true ]]; then
        jq -n --argjson pr "$number" '{github_repository: "Example/Repository", pr_number: $pr}' \
            >"$dir/work/$run/${stem}-manifest.json"
    else
        printf '{"pr_number": %s}\n' "$number" >"$dir/work/$run/${stem}-manifest.json"
    fi
}
write_review 100 true
write_review 101 true
write_review 102 false
write_review 103 true
printf 'not a pull request\n' >"$reviews/example-repository/notes.txt"
mkdir -p -- "$reviews/contract-tests/20261001-120000-CEST"
printf 'log\n' >"$reviews/contract-tests/20261001-120000-CEST/agent.log"
# A run that started long ago under a PID no review holds now.
printf '%s\n' '{"event":"started","pr":100,"pid":999999999}' >"$reviews/run-history.jsonl"

tree_listing() {
    (cd "$reviews" && find . -type f | LC_ALL=C sort)
}
run_prune() {
    "$repo_root/bin/review-pr" --config "$config" prune "$@"
}

before=$(tree_listing)
output=$(run_prune 2>&1) || fail "prune failed: ${output}"
assert_eq "$before" "$(tree_listing)" 'a dry run changes nothing'
assert_true 'and says what it would do' grep -q 'Would compress 4 files' <<<"$output"
assert_true 'and removing the leftovers of every review, open or not' grep -q 'remove 4 leftover temporary files' <<<"$output"
assert_true 'and an unknown state is reported' grep -q 'State unknown, kept the same way: 1' <<<"$output"
assert_eq 1 "$(grep -c 'pullRequest' "$FAKE_GH_QUERIES")" 'one GitHub query per repository'

# A review that is running holds the files it writes: a dry run says so, and
# --apply refuses.
bash -c 'exec -a review-pr-fixture sleep 30' &
running_pid=$!
printf '{"event":"started","pr":101,"pid":%s}\n' "$running_pid" >>"$reviews/run-history.jsonl"
output=$(run_prune 2>&1) || fail "a dry run during a review failed: ${output}"
assert_true 'a dry run names the running review' grep -q "A review is running (PID ${running_pid})" <<<"$output"
apply_status=0
output=$(run_prune --apply 2>&1) || apply_status=$?
assert_eq 1 "$apply_status" '--apply refuses while a review runs'
assert_eq "$before" "$(tree_listing)" 'and changes nothing'
kill "$running_pid" 2>/dev/null || true
wait "$running_pid" 2>/dev/null || true
running_pid=""

output=$(run_prune --apply 2>&1) || fail "prune --apply failed: ${output}"
run="20261001-120000-CEST"
for number in 100 102; do
    work="$reviews/example-repository/${number}-task/work/$run"
    stem="${number}-task-${run}"
    assert_eq "event ${number}" "$(gzip -dc "$work/${stem}-primary-pi-error-attempt-1-events.jsonl.gz")" \
        "the events of ${number} are compressed whole"
    assert_file_not_exists "$work/${stem}-primary-pi-error-attempt-1-events.jsonl" 'in place of the original'
    assert_file_exists "$work/${stem}-primary-pi-error-attempt-1.log.gz" "the log of ${number} is compressed"
    assert_file_exists "$work/${stem}-primary-pi-error-attempt-1-usage.json" 'usage stays readable as it is'
    assert_file_exists "$work/${stem}-final-findings.json" 'findings stay'
    assert_file_exists "$work/${stem}-primary-prompt.md" 'prompts stay'
    assert_file_exists "$work/${stem}-manifest.json" 'manifests stay'
    assert_file_exists "$reviews/example-repository/${number}-task/${stem}-final.md" 'reports stay'
    assert_file_not_exists "$work/.${stem}-amendment-reply.tmp.Ab12Cd" 'leftover temporary files go'
done
work="$reviews/example-repository/101-task/work/$run"
assert_file_exists "$work/101-task-${run}-primary-pi-error-attempt-1-events.jsonl" 'an open pull request keeps its events'
assert_file_not_exists "$work/.101-task-${run}-amendment-reply.tmp.Ab12Cd" 'but not its leftovers'
work="$reviews/example-repository/103-task/work/$run"
assert_file_exists "$work/103-task-${run}-primary-pi-error-attempt-1-events.jsonl" 'a pull request of unknown state keeps its events'
assert_file_not_exists "$work/.103-task-${run}-amendment-reply.tmp.Ab12Cd" 'but not its leftovers either'
assert_file_exists "$reviews/contract-tests/20261001-120000-CEST/agent.log" 'what is not a review is not touched'
assert_true 'the outcome is reported' grep -q 'Compressed 4 files' <<<"$output"
output=$(run_prune 2>&1) || fail "a second dry run failed: ${output}"
assert_true 'a second run finds nothing left to do' grep -q 'Would compress 0 files' <<<"$output"

usage_status=0
"$repo_root/bin/review-pr" --config "$config" --apply 123 >/dev/null 2>&1 || usage_status=$?
assert_eq 1 "$usage_status" '--apply belongs to prune alone'
usage_status=0
run_prune 123 >/dev/null 2>&1 || usage_status=$?
assert_eq 1 "$usage_status" 'prune takes no pull request'

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
