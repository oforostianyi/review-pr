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
    repositories: {
        fixture: {github: "Example/Repository", checkout: $checkout},
        other: {github: "Other/Repository", checkout: $checkout}
    },
    reviews_directory: $reviews,
    language: "EN",
    finalization: {model: "mock-final", effort: "low"}
}' >"$config"

# GitHub answers the states listed in $FAKE_PR_STATES as "owner/name#number
# STATE" and leaves out any other, as it does for a number it does not know;
# with $FAKE_GH_FAIL set it fails as a logged-out gh does.
cat >"$fake_bin/gh" <<'FAKE'
#!/usr/bin/env bash
[[ "$1 $2" == "api graphql" ]] || exit 64
[[ -z "${FAKE_GH_FAIL:-}" ]] || { printf 'gh: not logged in\n' >&2; exit 4; }
query=${4#query=}
printf '%s\n' "$query" >>"$FAKE_GH_QUERIES"
owner=$(sed -n 's/.*owner: "\([^"]*\)".*/\1/p' <<<"$query")
name=$(sed -n 's/.*name: "\([^"]*\)".*/\1/p' <<<"$query")
numbers=$(grep -o 'p[0-9]*:' <<<"$query" | tr -d 'p:')
jq -n --rawfile states "$FAKE_PR_STATES" --arg repo "$owner/$name" --arg numbers "$numbers" '
    ($states | split("\n") | map(select(length > 0) | split(" ") | {key: .[0], value: .[1]}) | from_entries) as $known
    | {data: {repository: ([$numbers | split("\n")[] | select(length > 0) | select($known[$repo + "#" + .])
        | {key: ("p" + .), value: {state: $known[$repo + "#" + .]}}] | from_entries)}}'
FAKE
chmod +x "$fake_bin/gh"
export FAKE_PR_STATES="$suite_root/states.txt"
export FAKE_GH_QUERIES="$suite_root/queries.txt"
cat >"$FAKE_PR_STATES" <<'STATES'
Example/Repository#100 MERGED
Example/Repository#101 OPEN
Example/Repository#102 CLOSED
Example/Repository#104 MERGED
Example/Repository#105 MERGED
Other/Repository#100 OPEN
Legacy/Repository#106 MERGED
Legacy/Repository#108 MERGED
Example/Repository#109 MERGED
STATES
PATH="$fake_bin:$PATH"

run="20261001-120000-CEST"
old_stamp=202601010000
work_of_fixture() {
    printf '%s' "$reviews/$1/$2/work/$run"
}

# One review per case: a run's agent streams and logs, the artifacts that stay,
# and a temporary file a killed run left. Everything is a day old or more.
write_review() {
    local folder=$1 dir_name=$2 manifest_repository=$3 layout=${4:-nested} run=${5:-$run}
    local dir="$reviews/$folder/$dir_name" stem="${dir_name}-${run}" work
    work="$dir/work/$run"
    [[ "$layout" == nested ]] || work="$dir/work"
    mkdir -p -- "$work"
    printf 'report\n' >"$dir/${stem}-final.md"
    printf '{}\n' >"$dir/${stem}-fix-list.json"
    printf 'event %s\n' "$dir_name" >"$work/${stem}-primary-pi-error-attempt-1-events.jsonl"
    printf 'log %s\n' "$dir_name" >"$work/${stem}-primary-pi-error-attempt-1.log"
    printf '{"tokens": 1}\n' >"$work/${stem}-primary-pi-error-attempt-1-usage.json"
    printf '{"findings": []}\n' >"$work/${stem}-final-findings.json"
    printf 'review\n' >"$work/${stem}-claude.md"
    printf 'partial\n' >"$work/.${stem}-amendment-reply.tmp.Ab12Cd"
    jq -n --arg repository "$manifest_repository" --arg stem "$stem" '
        (if $repository == "" then {} else {github_repository: $repository} end)
        + {artifacts: {primary: {claude: ($stem + "-claude.md")}, final_findings: ($stem + "-final-findings.json")}}' \
        >"$work/${stem}-manifest.json"
}
write_review example-repository 100-task Example/Repository
write_review example-repository 101-task Example/Repository
# Recorded only in the folder it sits in.
write_review example-repository 102-task ''
# GitHub does not know this one.
write_review example-repository 103-task Example/Repository
# A branch that says "error": only what follows the run's timestamp counts.
write_review example-repository 104-fix-x-error Example/Repository
# The flat layout of early releases, without a per-run directory.
write_review example-repository 105-task Example/Repository flat
# The same number in another repository, whose pull request is still open.
write_review other-repository 100-task Other/Repository
# A repository no longer configured: known from the run history alone.
write_review legacy-repository 106-task ''
# A manifest naming a repository the folder is not named after is not believed.
write_review legacy-repository 107-task Example/Repository
# Known from its manifest alone, read after a manifest that is no JSON at all.
write_review legacy-repository 108-task Legacy/Repository
mkdir -p -- "$reviews/example-repository/100-task/work/20260101-000000-CEST"
printf '{"github_repository": "Example/Repo' >"$reviews/example-repository/100-task/work/20260101-000000-CEST/100-task-20260101-000000-CEST-manifest.json"
# A run in a zone whose abbreviation is a negative offset.
write_review example-repository 109-task Example/Repository nested 20261001-120000--03
# Reviewers whose keys say error: their reports, raw streams and findings stay,
# and only a failed attempt goes. An artifact the manifest names stays even when
# its name looks like a failed step's, as an anchor validation of a failed final
# synthesis does; the same name no manifest claims goes.
work="$reviews/example-repository/100-task/work/$run"
for artifact in error-checker.md error-checker-raw.ndjson error-checker-findings.json \
    cross-error-checker.md cross-error-checker-findings.json \
    cross-logic-error-checker.md cross-logic-error-checker-raw.ndjson cross-logic-error-checker-findings.json; do
    printf 'artifact\n' >"$work/100-task-${run}-${artifact}"
done
printf 'log\n' >"$work/100-task-${run}-cross-error-checker-error-attempt-1.log"
printf '{}\n' >"$work/100-task-${run}-final-error-anchor-validation.json"
printf '{}\n' >"$(work_of_fixture example-repository 102-task)/102-task-${run}-final-error-anchor-validation.json"
jq --arg stem "100-task-${run}" '.artifacts.primary["error-checker"] = ($stem + "-error-checker.md")
    | .artifacts.primary_raw = {"error-checker": ($stem + "-error-checker-raw.ndjson")}
    | .artifacts.primary_findings = {"error-checker": ($stem + "-error-checker-findings.json")}
    | .artifacts.cross_review = {"error-checker": ($stem + "-cross-error-checker.md"),
        "logic-error-checker": ($stem + "-cross-logic-error-checker.md")}
    | .artifacts.cross_review_raw = {"logic-error-checker": ($stem + "-cross-logic-error-checker-raw.ndjson")}
    | .artifacts.cross_review_findings = {"error-checker": ($stem + "-cross-error-checker-findings.json"),
        "logic-error-checker": ($stem + "-cross-logic-error-checker-findings.json")}
    | .artifacts.final_anchor_validation = ($stem + "-final-error-anchor-validation.json")' \
    "$work/100-task-${run}-manifest.json" >"$work/manifest.tmp" && mv "$work/manifest.tmp" "$work/100-task-${run}-manifest.json"
# The same pull request reviewed from a second branch: one pull request still.
write_review example-repository 101-second-branch Example/Repository
# A final rerun of that run: its failed attempt goes, its findings stay.
printf 'log\n' >"$work/100-task-${run}-final-rerun-20261002-120000-CEST-final-error-attempt-1.log"
printf '{}\n' >"$work/100-task-${run}-final-rerun-20261002-120000-CEST-final-findings.json"
# The worktree of a killed command agent: a checkout, counted and left alone.
mkdir -p -- "$work/.100-task-${run}-tool-1.worktree.Ab12Cd"
printf 'source\n' >"$work/.100-task-${run}-tool-1.worktree.Ab12Cd/handler-error-1.log"
# A staging copy left beside the final report.
printf 'partial\n' >"$reviews/example-repository/100-task/.100-task-${run}-final.md.publish.Cd34Ef"
printf 'not a pull request\n' >"$reviews/example-repository/notes.txt"
mkdir -p -- "$reviews/contract-tests/$run"
printf 'log\n' >"$reviews/contract-tests/$run/agent.log"
# A run that started long ago under a PID no review holds now, and the history
# of the legacy review.
{
    printf '%s\n' '{"event":"started","pr":100,"pid":999999999}'
    printf '%s\n' '{"event":"finished","pr":106,"review_id":"106-task","repository":"Legacy/Repository","pid":999999998}'
} >"$reviews/run-history.jsonl"
find "$reviews" -exec touch -t "$old_stamp" {} +
# A temporary file of a review still being written, which no history records,
# and a log a run of a merged pull request is still writing.
printf 'live\n' >"$reviews/example-repository/101-task/work/$run/.101-task-${run}-primary-prompt.tmp.Gh56Ij"
printf 'live\n' >"$reviews/example-repository/100-task/work/$run/100-task-${run}-final-error-attempt-1.log"

tree_listing() {
    (cd "$reviews" && find . -type f ! -name run-history.jsonl | LC_ALL=C sort)
}
run_prune() {
    "$repo_root/bin/review-pr" --config "$config" prune "$@"
}
work_of() {
    local folder=$1 dir_name=$2 layout=${3:-nested} run=$run
    [[ "$dir_name" != 109-task ]] || run=20261001-120000--03
    if [[ "$layout" == nested ]]; then
        printf '%s' "$reviews/$folder/$dir_name/work/$run"
    else
        printf '%s' "$reviews/$folder/$dir_name/work"
    fi
}

before=$(tree_listing)
output=$(run_prune 2>&1) || fail "prune failed: ${output}"
assert_eq "$before" "$(tree_listing)" 'a dry run changes nothing'
assert_true 'and says what it would do' grep -q 'Would compress 17 files' <<<"$output"
assert_true 'counting the leftovers of every review, open or not' grep -q 'remove 13 leftover temporary files' <<<"$output"
assert_true 'and the reviews whose state is not known' grep -q 'State unknown, kept the same way: 2' <<<"$output"
assert_true 'each pull request counted once, whatever number of branches it was reviewed from' \
    grep -q 'Open pull requests keep their streams and logs: 2' <<<"$output"
assert_true 'and what is too fresh to touch' grep -q 'Files changed in the last day are left for later: 2' <<<"$output"
assert_eq 3 "$(grep -c 'pullRequest' "$FAKE_GH_QUERIES")" 'one GitHub query per repository'

# A review that is running holds the files it writes: a dry run says so, and
# --apply refuses. Only Bash running review-pr is a review; another program
# under a reused PID is not, even one that names the script.
mkdir -p -- "$suite_root/fake install"
printf 'sleep 30\n' >"$suite_root/fake install/review-pr"
bash "$suite_root/fake install/review-pr" &
running_pid=$!
printf '{"event":"started","pr":101,"pid":%s}\n' "$running_pid" >>"$reviews/run-history.jsonl"
output=$(run_prune 2>&1) || fail "a dry run during a review failed: ${output}"
assert_true 'a dry run names the running review' grep -q "A review is running (PID ${running_pid})" <<<"$output"
apply_status=0
output=$(run_prune --apply 2>&1) || apply_status=$?
assert_eq 1 "$apply_status" '--apply refuses while a review runs'
kill "$running_pid" 2>/dev/null || true
wait "$running_pid" 2>/dev/null || true
running_pid=""
bash -c 'exec -a vim tail -f "$1" >/dev/null' vim "$suite_root/fake install/review-pr" &
running_pid=$!
assert_true 'the stand-in runs under a command line that names the script' \
    bash -c 'sleep 0.2; ps -p "$1" -o command= | grep -q review-pr' _ "$running_pid"
printf '{"event":"started","pr":101,"pid":%s}\n' "$running_pid" >>"$reviews/run-history.jsonl"
output=$(run_prune 2>&1) || fail "a dry run failed: ${output}"
assert_false 'a process that is not a review does not count as one' grep -q 'A review is running' <<<"$output"
kill "$running_pid" 2>/dev/null || true
wait "$running_pid" 2>/dev/null || true
running_pid=""
assert_eq "$before" "$(tree_listing)" 'and nothing has changed'

# GitHub not answering is said out loud, and nothing is compressed on a guess.
output=$(FAKE_GH_FAIL=1 run_prune 2>&1) || fail "prune without GitHub failed: ${output}"
assert_true 'a repository GitHub did not answer for is named' \
    grep -q 'GitHub did not report the state of 7 pull requests of Example/Repository' <<<"$output"
assert_true 'and nothing is compressed' grep -q 'Would compress 0 files' <<<"$output"

output=$(run_prune --apply 2>&1) || fail "prune --apply failed: ${output}"
assert_true 'the outcome is reported' grep -q 'Compressed 17 files' <<<"$output"
for review in example-repository/100-task example-repository/102-task example-repository/104-fix-x-error \
    legacy-repository/106-task legacy-repository/108-task example-repository/109-task example-repository/105-task:flat; do
    layout=nested
    [[ "$review" != *:flat ]] || { layout=flat; review=${review%:flat}; }
    work=$(work_of "${review%%/*}" "${review#*/}" "$layout")
    stem="${review#*/}-${run}"
    [[ "$review" != */109-task ]] || stem="${review#*/}-20261001-120000--03"
    assert_eq "event ${review#*/}" "$(gzip -dc "$work/${stem}-primary-pi-error-attempt-1-events.jsonl.gz")" \
        "the events of ${review} are compressed whole"
    assert_file_not_exists "$work/${stem}-primary-pi-error-attempt-1-events.jsonl" 'in place of the original'
    assert_file_exists "$work/${stem}-primary-pi-error-attempt-1.log.gz" "the log of ${review} is compressed"
    assert_file_exists "$work/${stem}-primary-pi-error-attempt-1-usage.json" 'usage stays readable as it is'
    assert_file_exists "$work/${stem}-final-findings.json" 'findings stay'
    assert_file_exists "$work/${stem}-claude.md" "a reviewer's report stays"
    assert_file_exists "$work/${stem}-manifest.json" 'manifests stay, whatever the branch is called'
    assert_file_exists "$reviews/${review}/${stem}-final.md" 'reports stay'
    assert_file_not_exists "$work/.${stem}-amendment-reply.tmp.Ab12Cd" 'leftover temporary files go'
done
work=$(work_of example-repository 100-task)
for artifact in error-checker.md error-checker-raw.ndjson error-checker-findings.json \
    cross-error-checker.md cross-error-checker-findings.json \
    cross-logic-error-checker.md cross-logic-error-checker-raw.ndjson cross-logic-error-checker-findings.json; do
    assert_file_exists "$work/100-task-${run}-${artifact}" "the ${artifact} of a reviewer whose key says error stays"
done
assert_file_exists "$work/100-task-${run}-cross-error-checker-error-attempt-1.log.gz" 'while its failed attempt is compressed'
assert_file_exists "$work/100-task-${run}-final-error-anchor-validation.json" 'an artifact the manifest names stays'
assert_file_exists "$(work_of example-repository 102-task)/102-task-${run}-final-error-anchor-validation.json.gz" \
    'while the same kind of file no manifest names goes'
assert_file_exists "$work/100-task-${run}-final-rerun-20261002-120000-CEST-final-error-attempt-1.log.gz" \
    "a final rerun's failed attempt is compressed"
assert_file_exists "$work/100-task-${run}-final-rerun-20261002-120000-CEST-final-findings.json" 'and its findings stay'
assert_file_exists "$work/.100-task-${run}-tool-1.worktree.Ab12Cd/handler-error-1.log" "an agent's worktree is left alone"
assert_file_not_exists "$reviews/example-repository/100-task/.100-task-${run}-final.md.publish.Cd34Ef" \
    'and so does a staging copy beside the final report'
work=$(work_of example-repository 100-task)
assert_file_exists "$work/100-task-${run}-final-error-attempt-1.log" 'a log changed in the last day is left alone'
for review in example-repository/101-task other-repository/100-task example-repository/103-task legacy-repository/107-task; do
    work=$(work_of "${review%%/*}" "${review#*/}")
    stem="${review#*/}-${run}"
    assert_file_exists "$work/${stem}-primary-pi-error-attempt-1-events.jsonl" \
        "${review} keeps its events: open, unknown, or of a repository its folder does not name"
    assert_file_not_exists "$work/.${stem}-amendment-reply.tmp.Ab12Cd" 'but not its old leftovers'
done
assert_file_exists "$(work_of example-repository 101-task)/.101-task-${run}-primary-prompt.tmp.Gh56Ij" \
    'while a fresh temporary file of a review the history never recorded stays'
assert_file_exists "$reviews/contract-tests/$run/agent.log" 'what is not a review is not touched'
output=$(run_prune 2>&1) || fail "a second dry run failed: ${output}"
assert_true 'a second run finds nothing left to do' grep -q 'Would compress 0 files' <<<"$output"

usage_status=0
"$repo_root/bin/review-pr" --config "$config" --apply 123 >/dev/null 2>&1 || usage_status=$?
assert_eq 1 "$usage_status" '--apply belongs to prune alone'
usage_status=0
"$repo_root/bin/review-pr" --config "$config" quota --apply >/dev/null 2>&1 || usage_status=$?
assert_eq 1 "$usage_status" 'and is not quietly dropped by another subcommand'
usage_status=0
usage_output=$("$repo_root/bin/review-pr" --config "$config" contract-test prune 2>&1) || usage_status=$?
assert_eq 1 "$usage_status" 'two subcommands are refused before either runs'
assert_true 'with the reason' grep -q 'Only one subcommand at a time' <<<"$usage_output"
usage_status=0
run_prune 123 >/dev/null 2>&1 || usage_status=$?
assert_eq 1 "$usage_status" 'prune takes no pull request'

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
