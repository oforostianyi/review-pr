#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154 # Tests read what the sourced orchestrator and the helpers below set.
# The stats subcommand reads the artifacts finished runs left and says, for each
# reviewer, what became of the findings it raised. It writes nothing.

set -euo pipefail

test_dir=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo_root=$(cd -P -- "$test_dir/../.." && pwd -P)
source "$test_dir/lib/assert.sh"

export REVIEW_PR_LIBRARY_MODE=true
# shellcheck source=/dev/null
source "$repo_root/bin/review-pr" --
unset REVIEW_PR_LIBRARY_MODE

suite_root=$(portable_mktemp_dir review-pr-stats)
trap 'rm -rf -- "$suite_root"' EXIT

reviews="$suite_root/reviews"
checkout="$suite_root/checkout"
config="$suite_root/config.json"
mkdir -p -- "$checkout"

jq -n --arg checkout "$checkout" --arg reviews "$reviews" '{
    agents: {
        alpha: {"label": "Alpha", enabled: true, model: "mock-alpha", effort: "low"},
        beta: {"label": "Beta", enabled: true, model: "mock-beta", effort: "low"}
    },
    reviewers: ["alpha", "beta"],
    synthesizer: "alpha",
    default_repository: "fixture",
    repositories: {
        fixture: {github: "Example/Repository", checkout: $checkout}
    },
    reviews_directory: $reviews,
    language: "EN",
    finalization: {model: "mock-final", effort: "low"}
}' >"$config"

# Runs review-pr with the given arguments and no agent CLI on PATH, as CI does,
# and keeps what it printed and how it ended. The Bash and jq are the ones this
# suite runs with: on macOS /usr/bin and /bin hold only Bash 3.2, and the
# minimum-jq job puts jq 1.6 first on PATH.
stats_jq_directory=$(dirname -- "$(command -v jq)")
run_review_pr() {
    stats_status=0
    stats_output=$(env PATH="${stats_jq_directory}:/usr/bin:/bin" "$BASH" "$repo_root/bin/review-pr" --config "$config" "$@" 2>"$suite_root/stderr") || stats_status=$?
    stats_error=$(<"$suite_root/stderr")
}

run_stats() {
    run_review_pr stats "$@"
}

# The command line.
run_stats
assert_eq 0 "$stats_status" 'an absent reviews directory is not an error'
assert_eq 'No finished review with structured final findings to count.' "$stats_output" 'and says there is nothing to count'
assert_eq '' "$stats_error" 'on standard output alone'

run_stats --json
assert_eq 0 "$stats_status" 'the same as JSON'
assert_eq '{"schema_version":1,"filters":{"since":null,"until":null,"repository":null},"runs":{"counted":0,"skipped":0},"period":null,"reviewers":[]}' \
    "$(jq -c . <<<"$stats_output")" 'is a document with no runs and no reviewers'
assert_false 'and the reviews directory is not created' test -e "$reviews"

run_stats --since 2026-11-01 --until 2026-11-30 --repo Example/Repository --json
assert_eq '{"since":"2026-11-01","until":"2026-11-30","repository":"Example/Repository"}' \
    "$(jq -c .filters <<<"$stats_output")" 'the filters given are the filters reported'

refused() {
    local message=$1 reason=$2
    shift 2
    run_review_pr "$@"
    assert_true "${message}: refused" test "$stats_status" -ne 0
    assert_true "${message}: with the reason" grep -Fq -- "$reason" <<<"$stats_error"
}

refused 'stats takes no pull request' 'stats does not accept a pull-request target' stats 123
refused 'a month that does not exist' '--since requires a date as YYYY-MM-DD' stats --since 2026-13-40
refused 'a word for a date' '--until requires a date as YYYY-MM-DD' stats --until yesterday
refused '--since without a value' '--since requires a date as YYYY-MM-DD' stats --since
refused 'a period that ends before it starts' '--since is later than --until' stats --since 2026-11-02 --until 2026-11-01
refused 'a repository alias' '--repo requires a GitHub repository as owner/name' stats --repo fixture
refused '--apply with stats' '--apply is only valid for the prune subcommand' stats --apply
refused 'stats with --run' 'stats cannot be combined with PR workflow options' stats --run 20261101-101500-CET
refused 'stats with --reviewers' '--reviewers applies to a new review' stats --reviewers alpha
refused 'two subcommands' 'Only one subcommand at a time' prune stats
refused 'a stats filter elsewhere' '--since, --until and --repo are only valid for the stats subcommand' prune --since 2026-11-01
refused '--json elsewhere' '--json is only valid for the quota and stats subcommands' findings --json 123

# Fixture runs. make_run names the run every following write_* call adds to.
make_run() {
    local review_id=$1 timestamp=$2 layout=${3:-nested} folder=${4:-example-repository} work
    work="$reviews/$folder/$review_id/work"
    [[ "$layout" == flat ]] || work="$work/$timestamp"
    mkdir -p -- "$work"
    run_prefix="$work/${review_id}-${timestamp}"
    run_manifest="${run_prefix}-manifest.json"
}

# write_manifest <reviewers> <source handles: true|false> [<repository>]
write_manifest() {
    jq -n --argjson reviewers "$1" --argjson handles "$2" --arg repository "${3-Example/Repository}" '
        {schema_version: 1, reviewers: $reviewers}
        + (if $repository == "" then {} else {github_repository: $repository} end)
        + (if $handles then {reporting: {source_handles: true}} else {} end)' >"$run_manifest"
}

# write_primary <agent> <records>, each record [<source id>, <severity or null>]
write_primary() {
    jq -n --arg agent "$1" --argjson records "$2" '
        {agent: $agent, phase: "primary", findings: [$records[] | {source_id: .[0], severity: .[1]}]}' \
        >"${run_prefix}-$1-findings.json"
}

# write_final <findings> [<rerun timestamp> [<complete: true|false>]], each finding
# [<classification>, <severity or null>, ["<agent> <source id>", ...]]
write_final() {
    local target="${run_prefix}-final-findings.json"
    [[ -z "${2:-}" ]] || target="${run_prefix}-final-rerun-$2-findings.json"
    jq -n --argjson findings "$1" --argjson complete "${3:-true}" '
        {phase: "final-synthesis", complete: $complete,
         findings: [$findings[] | {classification: .[0], severity: .[1],
            primary_refs: [.[2][] | split(" ") | {agent: .[0], source_id: .[1]}]}]}' >"$target"
}

# write_usage <agent> <primary|cross> <model> <effort> <tokens>
write_usage() {
    local target="${run_prefix}-$1-usage.json"
    [[ "$2" == primary ]] || target="${run_prefix}-cross-$1-usage.json"
    jq -n --arg agent "$1" --arg model "$3" --arg effort "$4" --argjson tokens "$5" '
        {agent: $agent, model: $model, effort: $effort, reported_total_tokens: $tokens}' >"$target"
}

# The pairs of one reviewer in $summary, in a fixed order, as "column group" words.
pairs_of() {
    jq -r --arg agent "$1" '[.reviewers[] | select(.agents | index($agent)) | .pairs | sort_by(.group, .column)[]
        | .column + " " + .group] | join(", ")' <<<"$summary"
}

reviewer_field() {
    jq -r --arg agent "$1" --arg field "$2" '.reviewers[] | select(.agents | index($agent)) | .[$field] | tostring' <<<"$summary"
}

# The run the rest of this file comes back to: three reviewers, handles on.
#   r01 alpha P1   r02 alpha P2   r03 alpha P3   r04 alpha P3
#   r05 beta P2    r06 beta P1    r07 gamma P3
write_reference_run() {
    write_manifest '["alpha", "beta", "gamma"]' true
    write_primary alpha '[["a-1", "P1"], ["a-2", "P2"], ["a-3", "P3"], ["a-4", "P3"]]'
    write_primary beta '[["b-1", "P2"], ["b-2", "P1"]]'
    write_primary gamma '[["g-1", "P3"]]'
    write_final '[["CONFIRMED", "P3", ["alpha r01"]],
                  ["CONFIRMED", "P2", ["alpha r02", "alpha r03", "beta r05"]],
                  ["REJECTED", null, ["beta r06"]],
                  ["UNCERTAIN", null, ["gamma r07"]]]'
    write_usage alpha primary mock-alpha high 1000
    write_usage alpha cross mock-alpha high 500
    write_usage beta primary provider/mock-beta xhigh 2000
}

summary_status() {
    local status=0
    summary=$(stats_run_summary "$run_manifest" 2>"$suite_root/stderr") || status=$?
    printf '%s' "$status"
}

# One run to one summary.
make_run 123-fix-FIX-123 20261101-101500-CET flat
write_reference_run
assert_eq 0 "$(summary_status)" 'a finished run has a summary'
summary=$(stats_run_summary "$run_manifest")
assert_eq 1 "$(wc -l <<<"$summary" | tr -d ' ')" 'on one line'
assert_eq '20261101-101500-CET 2026-11-01 Example/Repository' "$(jq -r '[.run, .date, .repository] | join(" ")' <<<"$summary")" \
    'that names the run, its date and its repository'
assert_eq 'shared P2, sole P3' "$(pairs_of alpha)" \
    'a confirmed finding counts at its final severity, and two records behind one finding count once'
assert_eq 1 "$(reviewer_field alpha unaccounted)" 'a record no final finding refers to is unaccounted'
assert_eq 'mock-alpha high 1500 true' \
    "$(reviewer_field alpha model) $(reviewer_field alpha effort) $(reviewer_field alpha tokens) $(reviewer_field alpha has_usage)" \
    'the reviewer is the model and effort of its usage file, with primary and cross-review tokens'
assert_eq 'rejected P1, shared P2' "$(pairs_of beta)" 'a rejected finding counts at the severity its reviewer claimed'
assert_eq 'provider/mock-beta xhigh 2000' "$(reviewer_field beta model) $(reviewer_field beta effort) $(reviewer_field beta tokens)" \
    'the model id is kept whole, and a missing cross-review usage adds nothing'
assert_eq 'uncertain P3' "$(pairs_of gamma)" 'an uncertain finding counts at the claimed severity too'
assert_eq 'gamma||0|false' "$(jq -r '.reviewers[] | select(.agents == ["gamma"]) | [.model, .effort, .tokens, .has_usage] | map(tostring) | join("|")' <<<"$summary")" \
    'without a usage file the agent name stands in for the model'
reference_summary=$(jq -c 'del(.run, .date)' <<<"$summary")

make_run 123-fix-FIX-123 20261101-111500-CET nested
write_reference_run
summary=$(stats_run_summary "$run_manifest")
assert_eq "$reference_summary" "$(jq -c 'del(.run, .date)' <<<"$summary")" 'a run in a directory of its own reads the same'

make_run 123-fix-FIX-123 20261101-121500-CET
write_manifest '["alpha", "beta"]' false ''
write_primary alpha '[["a-1", "P1"], ["a-2", "P2"]]'
write_primary beta '[["b-1", "P2"]]'
write_final '[["CONFIRMED", "P2", ["alpha a-2", "beta b-1"]], ["REJECTED", null, ["alpha a-1"]]]'
summary=$(stats_run_summary "$run_manifest")
assert_eq 'rejected P1, shared P2' "$(pairs_of alpha)" 'a run without handles is read by the reviewers own ids'
assert_eq 'null' "$(jq -r '.repository | tostring' <<<"$summary")" 'and a manifest that names no repository gives none'

make_run 123-fix-FIX-123 20261101-131500-CET
write_manifest '["alpha", "beta", "gamma"]' true
jq '. + {agent_status: {primary: {alpha: "failed", beta: "unknown", gamma: "complete"}}}' "$run_manifest" >"$suite_root/manifest" \
    && mv -- "$suite_root/manifest" "$run_manifest"
write_primary beta '[["b-1", "P1"]]'
write_primary gamma '[["g-1", "P2"]]'
write_final '[["REJECTED", null, ["beta r01"]], ["REJECTED", null, ["gamma r02"]]]'
summary=$(stats_run_summary "$run_manifest")
assert_eq 'beta gamma' "$(jq -r '[.reviewers[].agents[]] | join(" ")' <<<"$summary")" \
    'a reviewer takes part when its primary findings are on disk, whatever the manifest says of it'
assert_eq 'rejected P1 / rejected P2' "$(pairs_of beta) / $(pairs_of gamma)" 'and one that left none does not shift the handles'
: >"${run_prefix}-alpha-findings.json"
summary=$(stats_run_summary "$run_manifest")
assert_eq 'beta gamma' "$(jq -r '[.reviewers[].agents[]] | join(" ")' <<<"$summary")" 'an empty findings file is no findings file'

make_run 123-fix-FIX-123 20261101-141500-CET
write_manifest '["alpha", "beta"]' true
write_primary alpha '[["a-1", "P3"], ["a-2", null], ["a-3", "P1"], ["a-4", null], ["a-5", null], ["a-6", "P2"]]'
write_primary beta '[["b-1", "P2"]]'
write_final '[["REJECTED", null, ["alpha r01", "alpha r02", "alpha r03"]],
              ["UNCERTAIN", null, ["alpha r04", "alpha r05"]],
              ["REJECTED", null, ["alpha r99"]],
              ["CONFIRMED", null, ["alpha r06"]],
              ["CONFIRMED", "P0", ["beta r07", "gamma r08"]]]'
summary=$(stats_run_summary "$run_manifest")
assert_eq 'rejected P1, uncertain none, rejected unresolved, sole unresolved' "$(pairs_of alpha)" \
    'the highest claim names the group; no claim at all, an unknown record and a confirmed finding without a severity have groups of their own'
assert_eq 0 "$(reviewer_field alpha unaccounted)" 'and every record a final finding names is accounted for'
assert_eq 'shared P0' "$(pairs_of beta)" 'a finding another agent is named for is shared, even one that took no part'

make_run 124-fix-FIX-124 20261102-101500-CET
write_manifest '["alpha"]' true
write_primary alpha '[["a-1", "P2"]]'
write_final '[["REJECTED", null, ["alpha r01"]]]'
write_final '[["UNCERTAIN", null, ["alpha r01"]]]' 20261102-121500-CET
write_final '[["CONFIRMED", "P1", ["alpha r01"]]]' 20261102-141500-CET
write_final '[["CONFIRMED", "P3", ["alpha r01"]]]' 20261102-161500-CET false
summary=$(stats_run_summary "$run_manifest")
assert_eq 'sole P1' "$(pairs_of alpha)" 'the latest complete final synthesis of a run is the one that counts'
printf '{"findings": [' >"${run_prefix}-final-rerun-20261102-181500-CET-findings.json"
summary=$(stats_run_summary "$run_manifest")
assert_eq 'sole P1' "$(pairs_of alpha)" 'and one cut short is passed over'

printf 'not json\n' >"${run_prefix}-alpha-usage.json"
: >"${run_prefix}-cross-alpha-usage.json"
summary=$(stats_run_summary "$run_manifest")
assert_eq 'alpha||0|false' "$(jq -r '.reviewers[0] | [.model, .effort, .tokens, .has_usage] | map(tostring) | join("|")' <<<"$summary")" \
    'a usage file that cannot be read is a usage file that is missing'
jq -n '{model: "", effort: null, reported_total_tokens: "many"}' >"${run_prefix}-alpha-usage.json"
write_usage alpha cross mock-alpha high 700
summary=$(stats_run_summary "$run_manifest")
assert_eq 'alpha||700|true' "$(jq -r '.reviewers[0] | [.model, .effort, .tokens, .has_usage] | map(tostring) | join("|")' <<<"$summary")" \
    'and only the primary usage names the model, while any number of tokens counts'

jq -n '{model: "mock-alpha", effort: "high", reported_total_tokens: 900, error_message: ("x" * 200000)}' >"${run_prefix}-alpha-usage.json"
assert_eq 0 "$(summary_status)" 'a usage file too large for one command-line argument does not cost the run'
summary=$(stats_run_summary "$run_manifest")
assert_eq 'mock-alpha|high|1600|true' "$(jq -r '.reviewers[0] | [.model, .effort, .tokens, .has_usage] | map(tostring) | join("|")' <<<"$summary")" \
    'and is read like any other'

# Two agents on one model and effort are one reviewer within a run as well.
make_run 124-fix-FIX-124 20261102-201500-CET
write_manifest '["alpha", "beta", "gamma"]' true
write_primary alpha '[["a-1", "P3"], ["a-2", "P2"]]'
write_primary beta '[["b-1", "P1"], ["b-2", "P2"], ["b-3", "P3"]]'
write_primary gamma '[["g-1", "P2"]]'
write_final '[["CONFIRMED", "P1", ["alpha r01", "beta r03"]],
              ["CONFIRMED", "P2", ["alpha r02", "gamma r06"]],
              ["REJECTED", null, ["alpha r01", "beta r04"]]]'
write_usage alpha primary mock-twin high 100
write_usage beta primary mock-twin high 20
write_usage beta cross mock-twin high 3
write_usage gamma primary mock-twin low 1000
summary=$(stats_run_summary "$run_manifest")
assert_eq '["alpha","beta"] ["gamma"]' "$(jq -r '[.reviewers[] | .agents | tojson] | join(" ")' <<<"$summary")" \
    'agents on one model and effort are one reviewer of the run, another effort is another reviewer'
assert_eq 'sole P1, rejected P2, shared P2' "$(pairs_of alpha)" \
    'a finding both of its agents raised counts once and is its own; the highest claim of either names a rejected one'
assert_eq '1 123 true' "$(reviewer_field alpha unaccounted) $(reviewer_field alpha tokens) $(reviewer_field alpha has_usage)" \
    'what its agents left unaccounted and spent is added up'
rm -f -- "${run_prefix}-alpha-usage.json"
summary=$(stats_run_summary "$run_manifest")
assert_eq 'mock-twin high 23 true' "$(reviewer_field beta model) $(reviewer_field beta effort) $(reviewer_field beta tokens) $(reviewer_field beta has_usage)" \
    'an agent without usage is a reviewer of its own, and the other keeps its tokens'
assert_eq 'alpha  0 false' "$(reviewer_field alpha model) $(reviewer_field alpha effort) $(reviewer_field alpha tokens) $(reviewer_field alpha has_usage)" \
    'named after the agent'
assert_eq 'shared P1, shared P2, rejected P3 / shared P1, rejected P2' "$(pairs_of alpha) / $(pairs_of beta)" \
    'and what they both raised is then shared'

# Runs that do not count give nothing, and say nothing.
no_summary() {
    local message=$1
    assert_eq 1 "$(summary_status)" "${message}: no summary"
    summary=$(stats_run_summary "$run_manifest" 2>&1) || :
    assert_eq '' "$summary" "${message}: and no output"
}

make_run 124-fix-FIX-124 20261103-101500-CET
write_manifest '["alpha"]' true
write_primary alpha '[["a-1", "P2"]]'
no_summary 'a run without a final synthesis'
printf '{"complete": true, "findings": [{"classification": "CONFIRMED", "severity": "P2"}]}\n' >"${run_prefix}-final-findings.json"
no_summary 'a final synthesis from before primary references'
printf '{"complete": true, "findings": [' >"${run_prefix}-final-findings.json"
no_summary 'a final synthesis cut short'
write_final '[["CONFIRMED", "P2", ["alpha r01"]]]' '' false
no_summary 'a final synthesis that did not complete'
write_final '[["CONFIRMED", "P2", ["alpha r01"]]]'
assert_eq 0 "$(summary_status)" 'the same run with a complete final synthesis counts'
printf '{"reviewers": [' >"$run_manifest"
no_summary 'a manifest cut short'
write_manifest '["alpha"]' true
rm -f -- "${run_prefix}-alpha-findings.json"
no_summary 'a run no reviewer took part in'
printf 'not json\n' >"${run_prefix}-alpha-findings.json"
no_summary 'a primary findings file that cannot be read'

# All runs to one document. A history of its own: two counted runs and one
# without a final synthesis in one repository, one counted run in another.
rm -rf -- "$reviews"
make_run 123-fix-FIX-123 20261101-101500-CET flat
write_reference_run

make_run 124-fix-FIX-124 20261103-090000-CET nested
write_manifest '["alpha", "delta"]' true
write_primary alpha '[["a-1", "P2"]]'
write_primary delta '[["d-1", "P1"]]'
write_final '[["CONFIRMED", "P1", ["delta r02"]], ["REJECTED", null, ["alpha r01"]]]'
write_usage alpha primary mock-alpha-2 high 300
write_usage delta primary provider/mock-beta xhigh 1001

make_run 124-fix-FIX-124 20261105-090000-CET nested
write_manifest '["alpha"]' true
write_primary alpha '[["a-1", "P2"]]'

make_run 125-fix-FIX-125 20261102-090000-CET nested other-repository
write_manifest '["epsilon", "zeta"]' true Other/Repository
write_primary epsilon '[["e-1", "P3"]]'
write_primary zeta '[["z-1", "P2"]]'
write_final '[["CONFIRMED", "P3", ["epsilon r01"]]]'
write_usage epsilon primary mock-epsilon low 50

# One field of the row of one model, as compact JSON.
row() {
    jq -c --arg model "$1" ".reviewers[] | select(.model == \$model) | $2" <<<"$stats_output"
}
counted_and_skipped() {
    jq -r '"\(.runs.counted) counted, \(.runs.skipped) skipped"' <<<"$stats_output"
}

snapshot() {
    find "$reviews" -type f -exec cksum {} + | LC_ALL=C sort
}
before=$(snapshot)

run_stats --json
assert_eq 0 "$stats_status" 'a history is reported'
assert_eq '3 counted, 1 skipped' "$(counted_and_skipped)" 'a run without a final synthesis is skipped, not counted'
assert_eq '{"from":"2026-11-01","to":"2026-11-03"}' "$(jq -c .period <<<"$stats_output")" 'the period spans the counted runs'
assert_eq 'provider/mock-beta gamma mock-alpha mock-alpha-2 mock-epsilon zeta' "$(jq -r '[.reviewers[].model] | join(" ")' <<<"$stats_output")" \
    'one row per model and effort, the most runs first, then by name'
assert_eq '["alpha"] ["alpha"]' "$(row mock-alpha .agents) $(row mock-alpha-2 .agents)" 'an agent that changed its model is two reviewers'
assert_eq '["beta","delta"] 2' "$(row provider/mock-beta .agents) $(row provider/mock-beta .runs)" \
    'and two agents on one model and effort are one'
assert_eq '{"total":2,"sole":1,"shared":0,"uncertain":0,"rejected":1}' "$(row provider/mock-beta .by_severity.P1)" \
    'a severity group adds up over the runs'
assert_eq '1 3 67' "$(row provider/mock-beta .by_severity.P2.shared) $(row provider/mock-beta .total) $(row provider/mock-beta .precision)" \
    'precision is the confirmed share of everything raised, to a whole percent'
assert_eq '{"total":3001,"per_run":1501,"runs_without_usage":0}' "$(row provider/mock-beta .tokens)" \
    'tokens are averaged over the reviewers runs, half rounded up'
assert_eq '{"P0":{"total":0,"sole":0,"shared":0,"uncertain":0,"rejected":0},"P1":{"total":0,"sole":0,"shared":0,"uncertain":0,"rejected":0},"P2":{"total":0,"sole":0,"shared":0,"uncertain":0,"rejected":0},"P3":{"total":1,"sole":0,"shared":0,"uncertain":1,"rejected":0},"none":{"uncertain":0,"rejected":0}}' \
    "$(row gamma .by_severity)" 'every severity group is there, empty or not'
assert_eq '{"total":0,"per_run":0,"runs_without_usage":1} 0' "$(row gamma .tokens) $(row gamma .precision)" \
    'a run without usage is counted as such, and nothing confirmed is a precision of zero'
assert_eq '3 1 67' "$(row mock-alpha .total) $(row mock-alpha .unaccounted) $(row mock-alpha .precision)" \
    'a record no final finding refers to is part of the total'
assert_eq '1 1 0 0' "$(row zeta .total) $(row zeta .unaccounted) $(row zeta .precision) $(row zeta .unresolved)" \
    'even when it is all a reviewer raised'
assert_eq 'schema_version filters runs period reviewers' "$(jq -r 'keys_unsorted | join(" ")' <<<"$stats_output")" 'the document has its five parts'
assert_eq 'model effort agents runs by_severity total unresolved unaccounted precision tokens' \
    "$(jq -r '.reviewers[0] | keys_unsorted | join(" ")' <<<"$stats_output")" 'and a reviewer its ten'

run_stats --json --since 2026-11-03
assert_eq '1 counted, 1 skipped' "$(counted_and_skipped)" '--since leaves out earlier runs, counted or not'
assert_eq 'mock-alpha-2 provider/mock-beta' "$(jq -r '[.reviewers[].model] | join(" ")' <<<"$stats_output")" 'and keeps the day it names'
run_stats --json --until 2026-11-01
assert_eq '1 counted, 0 skipped' "$(counted_and_skipped)" '--until leaves out later runs'
assert_eq '{"from":"2026-11-01","to":"2026-11-01"}' "$(jq -c .period <<<"$stats_output")" 'and the period is that of the runs left'
run_stats --json --since 2026-11-02 --until 2026-11-02 --repo other/repository
assert_eq '1 counted, 0 skipped' "$(counted_and_skipped)" '--repo keeps one repository, however its name is cased'
assert_eq 'mock-epsilon zeta' "$(jq -r '[.reviewers[].model] | join(" ")' <<<"$stats_output")" 'with its reviewers'
assert_eq '{"since":"2026-11-02","until":"2026-11-02","repository":"other/repository"}' "$(jq -c .filters <<<"$stats_output")" \
    'and the filters are reported as given'
run_stats --json --repo Example/Repository
assert_eq '2 counted, 1 skipped' "$(counted_and_skipped)" 'another repository is neither counted nor skipped'
run_stats --json --since 2027-01-01
assert_eq '0 counted, 0 skipped null []' "$(counted_and_skipped) $(jq -c .period <<<"$stats_output") $(jq -c .reviewers <<<"$stats_output")" \
    'a period without runs is an empty document'
run_stats
assert_eq "$before" "$(snapshot)" 'nothing in the reviews directory is written or changed'
assert_file_not_exists "$reviews/run-history.jsonl" 'and stats is not a run'

# Groups outside P0 to P3, and runs a repository filter has to judge.
make_run 126-fix-FIX-126 20261201-090000-CET
write_manifest '["eta"]' true
write_primary eta '[["h-1", null], ["h-2", "P2"], ["h-3", "P0"]]'
write_final '[["UNCERTAIN", null, ["eta r01"]], ["REJECTED", null, ["eta r99"]], ["CONFIRMED", "P0", ["eta r03"]]]'
run_stats --json --since 2026-12-01
assert_eq '{"uncertain":1,"rejected":0} 1 1 4 25' \
    "$(row eta .by_severity.none) $(row eta .unresolved) $(row eta .unaccounted) $(row eta .total) $(row eta .precision)" \
    'no claimed severity, an unknown record and an unreferenced one are in the total alone'
assert_eq '{"total":1,"sole":1,"shared":0,"uncertain":0,"rejected":0}' "$(row eta .by_severity.P0)" 'beside what has a group'

make_run 127-fix-FIX-127 20261202-090000-CET
write_manifest '["alpha"]' true Other/Repository
write_primary alpha '[["a-1", "P2"]]'
write_final '[["CONFIRMED", "P2", ["alpha r01"]]]'
run_stats --json --since 2026-12-02 --repo Example/Repository
assert_eq '0 counted, 0 skipped' "$(counted_and_skipped)" 'a run whose manifest names another repository is not of the repository its folder suggests'
run_stats --json --since 2026-12-02
assert_eq '1 counted, 0 skipped' "$(counted_and_skipped)" 'though it counts when no repository is asked for'

make_run 128-fix-FIX-128 20261203-090000-CET
write_manifest '["alpha"]' true ''
write_primary alpha '[["a-1", "P2"]]'
write_final '[["CONFIRMED", "P2", ["alpha r01"]]]'
run_stats --json --since 2026-12-03 --repo Example/Repository
assert_eq '1 counted, 0 skipped' "$(counted_and_skipped)" 'a manifest that names no repository belongs to the one its folder is named after'

make_run 129-fix-FIX-129 20261204-090000-CET
printf '{"reviewers": [' >"$run_manifest"
write_primary alpha '[["a-1", "P2"]]'
write_final '[["CONFIRMED", "P2", ["alpha r01"]]]'
ln -s -- "$reviews/example-repository/128-fix-FIX-128" "$reviews/example-repository/130-fix-FIX-130"
run_stats --json --since 2026-12-03
assert_eq 0 "$stats_status" 'a manifest cut short does not stop the rest'
assert_eq '1 counted, 1 skipped' "$(counted_and_skipped)" 'it is one skipped run, and a review directory that is a link is not read twice'

# The table.
run_stats --until 2026-11-01
expected=$(cat <<'TABLE'
review-pr stats   2026-11-01..2026-11-01   1 run

                        |      P1       |      P2       |      P3       |
Reviewer   Eff   Runs T | T So Sh Un Rj | T So Sh Un Rj | T So Sh Un Rj | Prec Tok/run
gamma               1 1 | 0  0  0  0  0 | 0  0  0  0  0 | 1  0  0  1  0 |   0%       0
mock-alpha high     1 3 | 0  0  0  0  0 | 1  0  1  0  0 | 1  1  0  0  0 |  67%    1.5K
mock-beta  xhigh    1 2 | 1  0  0  0  1 | 1  0  1  0  0 | 0  0  0  0  0 |  50%    2.0K

T total   So confirmed, only this reviewer   Sh confirmed, shared
Un uncertain   Rj rejected   Prec (So+Sh)/T   Tok/run avg tokens per run
1 primary finding no final finding refers to (in the overall T only)
TABLE
)
assert_eq "$expected" "$stats_output" 'one run as a table: a row per reviewer, a group per severity, the model without its provider'
assert_eq '' "$stats_error" 'and nothing else'

run_stats --since 2026-12-01 --until 2026-12-01
expected=$(cat <<'TABLE'
review-pr stats   2026-12-01..2026-12-01   1 run

                    |      P0       |      P1       |      P2       |      P3       |
Reviewer Eff Runs T | T So Sh Un Rj | T So Sh Un Rj | T So Sh Un Rj | T So Sh Un Rj | Prec Tok/run
eta             1 4 | 1  1  0  0  0 | 0  0  0  0  0 | 0  0  0  0  0 | 0  0  0  0  0 |  25%       0

T total   So confirmed, only this reviewer   Sh confirmed, shared
Un uncertain   Rj rejected   Prec (So+Sh)/T   Tok/run avg tokens per run
1 uncertain or rejected finding without a claimed severity (in the overall T only)
1 finding that fits no severity group (in the overall T only)
1 primary finding no final finding refers to (in the overall T only)
TABLE
)
assert_eq "$expected" "$stats_output" 'a P0 finding brings the P0 group, and each count outside the groups its own line'

run_stats --until 2026-11-30
assert_eq 'review-pr stats   2026-11-01..2026-11-03   3 runs' "$(sed -n 1p <<<"$stats_output")" 'the first line names the period and the runs'
assert_eq '1 run skipped (unfinished, unreadable, or without structured final findings)' "$(tail -n 1 <<<"$stats_output")" 'and the last one the runs that could not be counted'
assert_eq 6 "$(grep -c -E '^(provider/)?(mock-|gamma|zeta)' <<<"$stats_output")" 'with a row for every reviewer'
assert_eq 'mock-beta xhigh 2 3 | 2 1 0 0 1 | 1 0 1 0 0 | 0 0 0 0 0 | 67% 1.5K' "$(sed -n 5p <<<"$stats_output" | tr -s ' ')" \
    'the reviewer with the most runs first'

run_stats --since 2027-01-01
assert_eq 'No finished review with structured final findings to count.' "$stats_output" 'a period without runs says so'
run_stats --since 2026-12-04
assert_eq $'No finished review with structured final findings to count.\n1 run skipped (unfinished, unreadable, or without structured final findings)' "$stats_output" \
    'and names the runs it could not count'

# Widths, plurals and token figures, on a document written by hand.
severity() {
    jq -c -n --argjson figures "[$1]" '{total: ($figures | add), sole: $figures[0], shared: $figures[1], uncertain: $figures[2], rejected: $figures[3]}'
}
none='{"total":0,"sole":0,"shared":0,"uncertain":0,"rejected":0}'
document=$(jq -n --argjson none "$none" --argjson p1 "$(severity 3,8,1,2)" --argjson p2 "$(severity 12,33,5,11)" --argjson p3 "$(severity 126,57,11,21)" '
    def reviewer($model; $effort; $runs; $tokens): {model: $model, effort: $effort, agents: ["a"], runs: $runs,
        by_severity: {P0: $none, P1: $none, P2: $none, P3: $none, none: {uncertain: 0, rejected: 0}},
        total: 0, unresolved: 0, unaccounted: 0, precision: null, tokens: {total: 0, per_run: $tokens, runs_without_usage: 0}};
    {schema_version: 1, filters: {since: null, until: null, repository: null}, runs: {counted: 42, skipped: 2},
     period: {from: "2026-11-01", to: "2026-11-17"},
     reviewers: [
        (reviewer("vendor/group/model-with-a-long-name"; "xhigh"; 42; 12345678)
            | .by_severity += {P1: $p1, P2: $p2, P3: $p3, none: {uncertain: 1, rejected: 1}}
            | .total = 296 | .unresolved = 2 | .unaccounted = 2 | .precision = 81),
        reviewer("b"; ""; 7; 0), reviewer("c"; "low"; 7; 999), reviewer("d"; "low"; 7; 1000),
        reviewer("e"; "low"; 7; 1049), reviewer("f"; "low"; 7; 1050), reviewer("g"; "low"; 7; 999949),
        reviewer("h"; "low"; 7; 999950)]}')
table=$(stats_render_table <<<"$document")
rows=$(sed -n '4,12p' <<<"$table")
assert_eq 1 "$(awk '{ print length($0) }' <<<"$rows" | sort -u | wc -l | tr -d ' ')" 'the header and every row are equally wide'
assert_eq 1 "$(sed -n '3,12p' <<<"$table" | awk '{ line = ""; for (i = 1; i <= length($0); i++) if (substr($0, i, 1) == "|") line = line " " i; print line }' | sort -u | wc -l | tr -d ' ')" \
    'and the group separators stand in one column, the line of group names included'
assert_false 'no line ends with a space' grep -q ' $' <<<"$table"
assert_eq 'model-with-a-long-name xhigh 42 296 | 14 3 8 1 2 | 61 12 33 5 11 | 215 126 57 11 21 | 81% 12.3M' \
    "$(sed -n 5p <<<"$table" | tr -s ' ')" 'a wide row keeps its figures in order'
assert_eq '- 0|- 999|- 1.0K|- 1.0K|- 1.1K|- 999.9K|- 1.0M' "$(sed -n '6,12p' <<<"$table" | awk '{ printf "%s%s %s", (NR > 1 ? "|" : ""), $(NF - 1), $NF }')" \
    'tokens are written short, and a reviewer that raised nothing has no precision'
assert_eq 'review-pr stats   2026-11-01..2026-11-17   42 runs' "$(sed -n 1p <<<"$table")" 'many runs are runs'
assert_eq $'2 uncertain or rejected findings without a claimed severity (in the overall T only)\n2 findings that fit no severity group (in the overall T only)\n2 primary findings no final finding refers to (in the overall T only)\n2 runs skipped (unfinished, unreadable, or without structured final findings)' \
    "$(tail -n 4 <<<"$table")" 'and more than one of anything is plural'
assert_false 'without a P0 finding there is no P0 group' grep -q 'P0' <<<"$table"

document=$(jq '.reviewers = [.reviewers[1] | (.model = "provider-a/same-name"), (.model = "same-name"), (.model = "provider-b/other-name")]' <<<"$document")
assert_eq 'provider-a/same-name same-name other-name' "$(stats_render_table <<<"$document" | sed -n '5,7p' | awk '{ printf "%s%s", (NR > 1 ? " " : ""), $1 }')" \
    'two models that differ only in their provider keep it, so that their rows can be told apart'

# Runs are read several at a time, and the figures do not depend on how many.
REVIEWS_ROOT=$reviews
STATS_SINCE="" STATS_UNTIL="" STATS_REPOSITORY=""
assert_eq 1 "$(stats_collect_summaries 1 | grep -c '^{"skipped":')" 'one worker reports its skipped runs once'
assert_eq 3 "$(stats_collect_summaries 3 | grep -c '^{"skipped":')" 'three workers each report theirs'
in_turn=$(stats_collect_summaries 1 | stats_document "" "" "")
assert_eq '6 counted, 2 skipped' "$(jq -r '"\(.runs.counted) counted, \(.runs.skipped) skipped"' <<<"$in_turn")" 'the whole history, read in turn'
assert_eq "$in_turn" "$(stats_collect_summaries 3 | stats_document "" "" "")" 'is the same history read three runs at a time'
assert_eq "$in_turn" "$(stats_collect_summaries 64 | stats_document "" "" "")" 'or with more workers than runs'
assert_eq "$in_turn" "$(stats_collect_summaries | stats_document "" "" "")" 'or with as many as the machine suggests'
assert_true 'which is between one and eight' test "$(stats_job_count)" -ge 1 -a "$(stats_job_count)" -le 8
STATS_SINCE=2027-01-01
assert_eq '{"skipped":0}' "$(stats_collect_summaries 3)" 'no run at all needs no worker'
STATS_SINCE=""

# Two agents on one model in one run, end to end.
make_run 131-fix-FIX-131 20261210-090000-CET
write_manifest '["alpha", "beta"]' true
write_primary alpha '[["a-1", "P1"]]'
write_primary beta '[["b-1", "P2"]]'
write_final '[["CONFIRMED", "P1", ["alpha r01", "beta r02"]]]'
write_usage alpha primary mock-twin high 100
write_usage beta primary mock-twin high 50
run_stats --json --since 2026-12-10
assert_eq '["alpha","beta"] 1 1 {"total":1,"sole":1,"shared":0,"uncertain":0,"rejected":0} 100 150' \
    "$(row mock-twin .agents) $(row mock-twin .runs) $(row mock-twin .total) $(row mock-twin .by_severity.P1) $(row mock-twin .precision) $(row mock-twin .tokens.per_run)" \
    'a finding two agents of one reviewer raised is one finding of its own, in one run'

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
