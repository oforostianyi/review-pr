#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154 # Tests assign the sourced orchestrator's globals.

set -euo pipefail

test_dir=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo_root=$(cd -P -- "$test_dir/../.." && pwd -P)
source "$test_dir/lib/assert.sh"

export REVIEW_PR_LIBRARY_MODE=true
# shellcheck source=/dev/null
source "$repo_root/bin/review-pr" --
unset REVIEW_PR_LIBRARY_MODE

suite_root=$(portable_mktemp_dir review-pr-quota)
trap 'rm -rf -- "$suite_root"' EXIT
export XDG_CACHE_HOME="$suite_root/cache"
fake_bin="$suite_root/bin"
mkdir -p -- "$fake_bin"
original_path=$PATH

# A stand-in for `codex app-server`: it answers initialize, then answers
# account/rateLimits/read with the fixture in $FAKE_CODEX_RATE_LIMITS, and counts
# how often it was started.
cat >"$fake_bin/codex" <<'FAKE'
#!/usr/bin/env bash
[[ "${1:-}" == app-server ]] || exit 64
printf 'started\n' >>"$FAKE_CODEX_STARTS"
while IFS= read -r line; do
    case "$line" in
        *'"id":1,'*) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"userAgent":"fake"}}' ;;
        *'"id":2,'*) printf '%s\n' "$(cat "$FAKE_CODEX_RATE_LIMITS")" ;;
    esac
done
FAKE
chmod +x "$fake_bin/codex"
export FAKE_CODEX_STARTS="$suite_root/starts"
export FAKE_CODEX_RATE_LIMITS="$suite_root/rate-limits.json"
PATH="$fake_bin:$original_path"

fixture() {
    : >"$FAKE_CODEX_STARTS"
    rm -f -- "$XDG_CACHE_HOME/review-pr/quota-codex.json"
    printf '%s\n' "$1" >"$FAKE_CODEX_RATE_LIMITS"
}

# The live answer of 29 September 2026, with the account id left out.
fixture '{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"limitId":"codex","limitName":null,"planType":"team","primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":1790709167},"secondary":{"usedPercent":28,"windowDurationMins":10080,"resetsAt":1791016214},"credits":{"hasCredits":false,"unlimited":false,"balance":null}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","planType":"team","primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":1790709167},"secondary":{"usedPercent":28,"windowDurationMins":10080,"resetsAt":1791016214}}},"futureField":{"anything":true}}}'
quota=$(read_codex_quota)
assert_eq 'team|5h:90|weekly:72' "$(jq -r '.plan + "|" + ([.windows[] | "\(.name):\(.remaining_percent)"] | join("|"))' <<<"$quota")" \
    'a primary and a secondary window are named by their length and read as what is left'
assert_eq '2026-09-29T19:12:47Z' "$(jq -r '.windows[0].reset_at' <<<"$quota")" \
    'with the reset time as an instant'
assert_eq 'true' "$(jq -r '.available' <<<"$quota")" 'a field Codex added later does not make the answer unknown'
read_codex_quota >/dev/null
assert_eq 1 "$(grep -c . "$FAKE_CODEX_STARTS")" 'a second reading within a minute comes from the cache'

fixture '{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"limitId":"codex","secondary":{"usedPercent":61,"windowDurationMins":10080,"resetsAt":1791016214}}}}'
assert_eq 'weekly:39' "$(read_codex_quota | jq -r '[.windows[] | "\(.name):\(.remaining_percent)"] | join("|")')" \
    'an answer with only a weekly window reports only that window, not a 5h one by position'

fixture '{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":5,"windowDurationMins":300}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":5,"windowDurationMins":300}},"gpt-6-sol":{"limitId":"gpt-6-sol","normalModelSlug":"gpt-6-sol","primary":{"usedPercent":97,"windowDurationMins":1440}},"future":{"limitId":"future","primary":{"usedPercent":40}}}}}'
quota=$(read_codex_quota)
assert_eq 'codex 5h:95|gpt-6-sol 1d:3|future primary:60' \
    "$(jq -r '[.windows[] | "\(.bucket) \(.name):\(.remaining_percent)"] | join("|")' <<<"$quota")" \
    'every bucket is kept, a model bucket and one of unknown length included'
assert_eq 'null' "$(jq -r '.windows[2].reset_at' <<<"$quota")" 'and a reset Codex did not send stays null'

fixture '{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":0,"windowDurationMins":300},"credits":{"hasCredits":true,"unlimited":false,"balance":"12.50"},"individualLimit":{"limit":100,"used":80,"remainingPercent":20,"resetsAt":1791016214}}}}'
quota=$(read_codex_quota)
assert_eq '12.50' "$(jq -r '.credits.balance' <<<"$quota")" 'credits are reported as Codex sent them'
assert_eq 'spend control:20' "$(jq -r '.windows[1] | "\(.name):\(.remaining_percent)"' <<<"$quota")" \
    'and a spend-control limit is kept as a window of its own'

fixture '{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":5,"windowDurationMins":300},"credits":{"hasCredits":true,"unlimited":false,"balance":"7.00"}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":5,"windowDurationMins":300}}}}}'
assert_eq '7.00' "$(read_codex_quota | jq -r '.credits.balance')" \
    'credits sent only with the aggregate snapshot are kept when the buckets leave them out'

fixture '{"jsonrpc":"2.0","id":2,"error":{"code":-32600,"message":"not logged in"}}'
status=0; quota=$(read_codex_quota) || status=$?
assert_eq '1|false|not logged in' "${status}|$(jq -r '"\(.available)|\(.error)"' <<<"$quota")" \
    'a logged-out account is unavailable, with what Codex said, and exit 1'

fixture '{"jsonrpc":"2.0","id":2,"result":{"somethingElse":true}}'
status=0; quota=$(read_codex_quota) || status=$?
assert_eq '2|false|[]' "${status}|$(jq -c '"\(.available)|\(.windows)"' <<<"$quota" | tr -d '"' | sed 's/\\//g')" \
    'an answer without a rate-limit snapshot is a parser error, exit 2, never a zero quota'

rm -f -- "$XDG_CACHE_HOME/review-pr/quota-codex.json"
status=0; quota=$(PATH=/usr/bin:/bin read_codex_quota) || status=$?
assert_eq '1|false' "${status}|$(jq -r '.available' <<<"$quota")" 'without Codex installed the quota is unavailable'

# The policy is separate from the reading: it refuses a run that would start
# Codex below the threshold, lets an unreadable quota pass with a warning, and
# is off until the configuration asks for it.
declare -A AGENT_TYPES=([codex]=codex [claude]=claude)
REVIEW_AGENTS=(claude codex)
FINAL_SYNTHESIZER=claude
FALLBACK_SYNTHESIZER=""
fixture '{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":90,"windowDurationMins":300,"resetsAt":1790709167},"secondary":{"usedPercent":30,"windowDurationMins":10080}}}}'
QUOTA_CODEX_MINIMUM=""
assert_true 'with no threshold configured the run is not checked' check_codex_quota_before_run all
assert_eq 0 "$(grep -c . "$FAKE_CODEX_STARTS")" 'and Codex is not even asked'
QUOTA_CODEX_MINIMUM=15
set +e
refusal=$( (check_codex_quota_before_run all) 2>&1 )
refusal_status=$?
set -e
assert_eq 1 "$refusal_status" 'a run that would start Codex with 10% left of its 5h window is refused'
assert_true 'and the refusal names the window' grep -q '5h has 10% left' <<<"$refusal"
assert_true 'a --rerun-final whose synthesizers are not Codex is not checked' check_codex_quota_before_run synthesizers
fixture '{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":50,"windowDurationMins":300}}}}'
assert_true 'a run with enough left goes ahead' check_codex_quota_before_run all
fixture '{"jsonrpc":"2.0","id":2,"error":{"message":"not logged in"}}'
warning=$(check_codex_quota_before_run all 2>&1) && unknown_status=0 || unknown_status=$?
assert_eq 0 "$unknown_status" 'an unreadable quota is not an exhausted one: the run goes on'
assert_true 'and the log says the check could not be made' grep -q 'could not be read' <<<"$warning"

# The quota is read again before every phase (Tools 29182: a run started with
# 15% left and Codex ran out of credits in its cross-review). A Codex reviewer
# short of quota is not started for the phase; others are untouched.
QUOTA_CODEX_MINIMUM=15
fixture '{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":95,"windowDurationMins":300,"resetsAt":1790709167}}}}'
skip_log=$(codex_agents_short_of_quota cross-review claude codex 2>&1)
codex_agents_short_of_quota cross-review claude codex 2>/dev/null
assert_eq 'codex' "${CODEX_QUOTA_SKIPPED_AGENTS[*]}" 'a Codex reviewer short of quota is set aside for the phase'
assert_true 'and the log says which window and that it is not started' \
    grep -q 'before the cross-review (5h has 5% left.*); not starting codex for it' <<<"$skip_log"
codex_agents_short_of_quota cross-review claude 2>/dev/null
assert_eq '' "${CODEX_QUOTA_SKIPPED_AGENTS[*]}" 'a phase without Codex does not read the quota'
fixture '{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":50,"windowDurationMins":300}}}}'
codex_agents_short_of_quota cross-review claude codex 2>/dev/null
assert_eq '' "${CODEX_QUOTA_SKIPPED_AGENTS[*]}" 'and one with enough left starts Codex'
QUOTA_CODEX_MINIMUM=""
codex_agents_short_of_quota cross-review claude codex 2>/dev/null
assert_eq '' "${CODEX_QUOTA_SKIPPED_AGENTS[*]}" 'with no threshold configured nothing is set aside'
QUOTA_CODEX_MINIMUM=15
fixture '{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":95,"windowDurationMins":300}}}}'
FINAL_SYNTHESIZER=codex
final_status=0; run_final_synthesis "$suite_root/final-error.log" 2>/dev/null || final_status=$?
assert_eq 1 "$final_status" 'a Codex synthesizer short of quota does not start the final'
assert_true 'and the failure reason names the quota' grep -q '^Codex quota below 15% before the final synthesis' <<<"$FINAL_FAILURE_REASON"
FINAL_SYNTHESIZER=claude

# The command itself: the table, --json, the exit codes and the arguments it
# refuses. A window without usedPercent prints "?" and keeps its reset time; an
# empty field once let the epoch slide into the percentage column.
export XDG_CONFIG_HOME="$suite_root/config"
quota_cli() { TZ=UTC "$repo_root/bin/review-pr" quota "$@"; }
fixture '{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"limitId":"codex","planType":"team","primary":{"windowDurationMins":300,"resetsAt":1790709167},"secondary":{"usedPercent":28,"windowDurationMins":10080,"resetsAt":1791016214}}}}'
cli_status=0; table=$(quota_cli) || cli_status=$?
assert_eq 0 "$cli_status" 'review-pr quota exits 0 when the quota was read'
assert_eq $'Codex (team)\n  5h             ?% left   resets Tue 29 Sep 19:12\n  weekly         72% left   resets Sat 03 Oct 08:30' \
    "$table" 'and prints each window, an unknown share as "?" with its reset time kept'
assert_eq 'null,72' "$(quota_cli --json | jq -r '[.windows[].remaining_percent | tostring] | join(",")')" \
    'review-pr quota --json prints the normalized reading'
fixture '{"jsonrpc":"2.0","id":2,"error":{"message":"not logged in"}}'
cli_status=0; table=$(quota_cli codex) || cli_status=$?
assert_eq '1|Codex: quota unavailable (not logged in)' "${cli_status}|${table}" \
    'an unavailable quota exits 1 and says why'
fixture '{"jsonrpc":"2.0","id":2,"result":{"somethingElse":true}}'
cli_status=0; quota_cli >/dev/null || cli_status=$?
assert_eq 2 "$cli_status" 'an answer of unknown shape exits 2'
assert_false 'a provider review-pr does not know is refused' quota_cli claude
assert_false 'and so is an option the command does not take' quota_cli --bogus
PATH=$original_path

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
