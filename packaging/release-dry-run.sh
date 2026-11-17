#!/usr/bin/env bash
# Release-candidate dry run: build the archive, verify it, install it into a
# throwaway prefix, smoke-test the installed command, optionally run the real
# agent contract test, uninstall, and write a machine-readable checklist that
# contains no private paths.
#
# Usage: packaging/release-dry-run.sh [--agent <name>]... [--config <file>] [--output <checklist.json>] [--keep]
#
#   --agent   agent to include in `review-pr contract-test` (repeatable). The
#             contract test uses the configuration named by --config, or the
#             REVIEW_PR_CONFIG / default user configuration, so those agents
#             must be configured and reachable. Without --agent the contract
#             test is skipped and recorded as such.
#   --config  configuration file for the contract test (default: user config).
#   --output  where to write the checklist (default: dist/release-dry-run-<version>.json).
#   --keep    keep the temporary directory for inspection.

set -euo pipefail

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
repository_root=$(CDPATH= cd "${script_dir}/.." && pwd -P)

agents=()
contract_config=${REVIEW_PR_CONFIG:-${XDG_CONFIG_HOME:-${HOME}/.config}/review-pr/config.json}
checklist=""
keep=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --agent) [[ $# -ge 2 ]] || { printf '%s\n' '--agent requires a name' >&2; exit 2; }; agents+=("$2"); shift 2 ;;
        --config) [[ $# -ge 2 ]] || { printf '%s\n' '--config requires a path' >&2; exit 2; }; contract_config=$2; shift 2 ;;
        --output) [[ $# -ge 2 ]] || { printf '%s\n' '--output requires a path' >&2; exit 2; }; checklist=$2; shift 2 ;;
        --keep) keep=true; shift ;;
        --help|-h) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

version=$(sed -n '1p' "${repository_root}/VERSION")
package_name="review-pr-${version}"
[[ -n "$checklist" ]] || checklist="${repository_root}/dist/release-dry-run-${version}.json"

work=$(mktemp -d "${TMPDIR:-/tmp}/review-pr-dry-run.XXXXXX")
work=$(cd -P -- "$work" && pwd -P)
cleanup() {
    if [[ "$keep" == true ]]; then
        printf 'Kept dry-run directory: %s\n' "$work"
    else
        rm -rf -- "$work"
    fi
}
trap cleanup EXIT

steps='[]'
overall=true
record() {
    # record <step> <status: passed|failed|skipped> <detail>; the detail is
    # kept free of the throwaway directory and the home directory.
    local detail=$3
    detail=${detail//"$work"/<dry-run>}
    detail=${detail//"$HOME"/<home>}
    steps=$(jq -c --arg step "$1" --arg status "$2" --arg detail "$detail" '. + [{step: $step, status: $status, detail: $detail}]' <<<"$steps")
    [[ "$2" != failed ]] || overall=false
    printf '%-8s %s%s\n' "$2" "$1" "${3:+ — $3}"
}
run_step() {
    # run_step <step> <command...>: records passed/failed from the exit status.
    local step=$1
    shift
    local output
    if output=$("$@" 2>&1); then
        record "$step" passed "${output##*$'\n'}"
    else
        record "$step" failed "${output##*$'\n'}"
    fi
}

dist="${work}/dist"
home="${work}/home"
prefix="${home}/.local"
config_dir="${home}/.config/review-pr"
checkout="${work}/checkout"
reviews="${work}/reviews"
mkdir -p -- "$home" "$checkout"
git -C "$checkout" init --quiet
git -C "$checkout" remote add origin "${work}/origin.git"

run_step build-package env REVIEW_PR_DIST_DIR="$dist" bash "${repository_root}/packaging/build-package.sh"
archive="${dist}/${package_name}.tar.gz"
if command -v sha256sum >/dev/null 2>&1; then
    run_step verify-checksum bash -c 'cd "$1" && sha256sum -c "$2"' _ "$dist" "${package_name}.tar.gz.sha256"
else
    run_step verify-checksum bash -c 'cd "$1" && shasum -a 256 -c "$2"' _ "$dist" "${package_name}.tar.gz.sha256"
fi
run_step verify-manifest bash -c '
    tar -tzf "$1" | grep -v "/$" | sed "s#^$2/##" | sort >"$3/archive-files.txt"
    grep -v "^#" "$4" | grep -v "^$" | sort >"$3/manifest-files.txt"
    cmp -s "$3/manifest-files.txt" "$3/archive-files.txt" && printf "%s files match packaging/package-manifest.txt\n" "$(wc -l <"$3/archive-files.txt" | tr -d " ")"
' _ "$archive" "$package_name" "$work" "${repository_root}/packaging/package-manifest.txt"
run_step extract-archive tar -xzf "$archive" -C "$work"

# The installed command must not see the developer's own configuration.
install_env=(env -i HOME="$home" XDG_CONFIG_HOME="${home}/.config" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}")
run_step clean-install "${install_env[@]}" sh "${work}/${package_name}/install.sh" \
    --repo "$checkout" --github-repository example/repository --reviews-dir "$reviews"
installed="${prefix}/bin/review-pr"
if [[ -x "$installed" ]]; then
    reported=$("${install_env[@]}" "$installed" --version 2>&1 || true)
    if [[ "$reported" == "review-pr ${version}" ]]; then
        record installed-version passed "$reported"
    else
        record installed-version failed "$reported"
    fi
    run_step show-config "${install_env[@]}" "$installed" --show-config
else
    record installed-version failed 'launcher missing after install'
    record show-config skipped 'launcher missing'
fi

agent_results='[]'
if (( ${#agents[@]} == 0 )); then
    record contract-test skipped 'no --agent given'
elif [[ ! -f "$contract_config" ]]; then
    record contract-test failed 'configuration for the contract test not found'
elif [[ ! -x "$installed" ]]; then
    record contract-test skipped 'launcher missing'
else
    agent_arguments=()
    for agent in "${agents[@]}"; do agent_arguments+=(--agent "$agent"); done
    contract_output="${work}/contract-test"
    # Real agent CLIs need the user's own environment (authentication, model
    # catalogs), so only the configuration is redirected here.
    if REVIEW_PR_CONFIG="$contract_config" "$installed" contract-test "${agent_arguments[@]}" --phase all --output "$contract_output" >"${work}/contract-test.log" 2>&1 \
        && [[ -s "${contract_output}/summary.json" ]]; then
        agent_results=$(jq -c '[.results[] | {agent, phase, model, passed}]' "${contract_output}/summary.json")
        if [[ "$(jq -r '.passed' "${contract_output}/summary.json")" == true ]]; then
            record contract-test passed "$(jq -r '[.results[].agent] | unique | join(", ")' "${contract_output}/summary.json") passed all three phases"
        else
            record contract-test failed "$(jq -r '[.results[] | select(.passed | not) | "\(.agent)/\(.phase): \(.result)"] | join("; ")' "${contract_output}/summary.json")"
        fi
    else
        record contract-test failed "$(grep -E 'ERROR|failed|invalid' "${work}/contract-test.log" | tail -n 1 || tail -n 1 "${work}/contract-test.log")"
    fi
fi

run_step uninstall "${install_env[@]}" sh "${work}/${package_name}/uninstall.sh" --prefix "$prefix"
if [[ ! -e "$installed" && ! -e "${prefix}/libexec/review-pr" && -f "${config_dir}/config.json" ]]; then
    record uninstall-preserves-config passed 'program files removed, configuration kept'
else
    record uninstall-preserves-config failed 'unexpected state after uninstall'
fi
run_step uninstall-purge "${install_env[@]}" sh "${work}/${package_name}/uninstall.sh" --prefix "$prefix" --purge-config
if [[ ! -e "${config_dir}/config.json" ]]; then
    record purge-removes-config passed 'configuration removed from the throwaway home'
else
    record purge-removes-config failed 'configuration still present after --purge-config'
fi

mkdir -p -- "$(dirname "$checklist")"
jq -n \
    --arg version "$version" \
    --arg timestamp "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg platform "$(uname -s) $(uname -m)" \
    --arg bash_version "$BASH_VERSION" \
    --arg jq_version "$(jq --version)" \
    --argjson steps "$steps" \
    --argjson agents "$agent_results" \
    --argjson passed "$overall" \
    '{schema_version: 1, review_pr_version: $version, timestamp: $timestamp, platform: $platform,
      bash_version: $bash_version, jq_version: $jq_version, steps: $steps, contract_test: $agents, passed: $passed}' \
    >"$checklist"
printf 'Checklist: %s\n' "$checklist"
[[ "$overall" == true ]] || { printf '%s\n' 'Release dry run FAILED' >&2; exit 1; }
printf 'Release dry run passed for review-pr %s\n' "$version"
