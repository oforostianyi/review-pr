#!/bin/sh

set -eu

usage() {
    cat <<'EOF'
Usage: ./install.sh --repo <dedicated-review-repository> [options]

Options:
  --repo <path>         Absolute path to the dedicated Git review checkout.
  --github-repository <owner/repo>
                        GitHub repository for the default `repository` alias. When
                        omitted, it is detected from --repo with GitHub CLI.
  --prefix <path>       Installation prefix (default: $HOME/.local).
  --config-dir <path>   Configuration directory (default: $XDG_CONFIG_HOME/review-pr
                        or $HOME/.config/review-pr).
  --reviews-dir <path>  External directory for review artifacts (default: $HOME/review-pr).
  --help                Show this help.

An existing config.json is preserved. Supplying --repo updates the default
repository entry; old single-repository configuration is migrated to the
`repositories` format. Supplying --reviews-dir updates only that field.
EOF
}

fail() {
    printf 'install.sh: %s\n' "$*" >&2
    exit 1
}

find_bash() {
    candidate=${REVIEW_PR_BASH:-}
    if [ -n "$candidate" ] && "$candidate" -c '(( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1) ))' 2>/dev/null; then
        printf '%s\n' "$candidate"
        return 0
    fi

    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        if [ -x "$candidate" ] && "$candidate" -c '(( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1) ))' 2>/dev/null; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    candidate=$(command -v bash 2>/dev/null || true)
    if [ -n "$candidate" ] && "$candidate" -c '(( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1) ))' 2>/dev/null; then
        printf '%s\n' "$candidate"
        return 0
    fi
    return 1
}

[ -n "${HOME:-}" ] || fail 'HOME is not set'
script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
package_version=$(sed -n '1p' "${script_dir}/VERSION")
case $package_version in
    ''|*[!0-9A-Za-z.-]*) fail "invalid package version: ${package_version}" ;;
esac
prefix=${REVIEW_PR_PREFIX:-${HOME}/.local}
config_root=${XDG_CONFIG_HOME:-${HOME}/.config}
config_dir=${REVIEW_PR_CONFIG_DIR:-${config_root}/review-pr}
review_repo=""
github_repository=""
reviews_dir=${REVIEW_PR_OUTPUT_DIR:-${HOME}/review-pr}
reviews_dir_configured=false

# Installs one file by writing it beside its destination and renaming it into
# place. A review that is running right now reads its own script incrementally,
# so rewriting the file in place would feed the live process new bytes at offsets
# computed for the old ones. A rename leaves that process on its original inode.
install_file() {
    install_source=$1
    install_target=$2
    install_mode=$3
    install_temp="${install_target}.new.$$"

    cp "$install_source" "$install_temp" || fail "could not stage ${install_target}"
    chmod "$install_mode" "$install_temp" || fail "could not set permissions on ${install_target}"
    mv -f "$install_temp" "$install_target" || fail "could not install ${install_target}"
}

backup_existing_config() {
    backup_dir=${config_dir}/backups
    timestamp=$(date +%Y%m%d-%H%M%S)
    backup_file=${backup_dir}/config-${timestamp}.json
    suffix=1

    [ -f "$config_file" ] || return 0
    [ ! -L "$config_file" ] || fail "refusing to back up symlinked configuration: ${config_file}"

    mkdir -p "$backup_dir"
    while [ -e "$backup_file" ] || [ -L "$backup_file" ]; do
        backup_file=${backup_dir}/config-${timestamp}-${suffix}.json
        suffix=$((suffix + 1))
    done
    cp "$config_file" "$backup_file" || fail "could not back up configuration: ${config_file}"
    chmod 0600 "$backup_file"
    printf 'Backed up existing configuration: %s\n' "$backup_file"
}

install_portable_skills() {
    skill_source=$1
    skill_target_root=${config_dir}/skills

    [ -d "$skill_source" ] || return 0
    find "$skill_source" -type f -name SKILL.md -print | while IFS= read -r source_file; do
        relative_path=${source_file#"${skill_source}/"}
        target_file=${skill_target_root}/${relative_path}
        target_dir=$(dirname "$target_file")

        mkdir -p "$target_dir"
        if [ -e "$target_file" ] || [ -L "$target_file" ]; then
            printf 'Preserved existing portable skill: %s\n' "$target_file"
            continue
        fi
        cp "$source_file" "$target_file"
        chmod 0644 "$target_file"
    done
}

while [ "$#" -gt 0 ]; do
    case $1 in
        --repo)
            [ "$#" -ge 2 ] || fail '--repo requires a path'
            review_repo=$2
            shift 2
            ;;
        --github-repository)
            [ "$#" -ge 2 ] || fail '--github-repository requires owner/repo'
            github_repository=$2
            shift 2
            ;;
        --prefix)
            [ "$#" -ge 2 ] || fail '--prefix requires a path'
            prefix=$2
            shift 2
            ;;
        --config-dir)
            [ "$#" -ge 2 ] || fail '--config-dir requires a path'
            config_dir=$2
            shift 2
            ;;
        --reviews-dir)
            [ "$#" -ge 2 ] || fail '--reviews-dir requires a path'
            reviews_dir=$2
            reviews_dir_configured=true
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *) fail "unknown option: $1" ;;
    esac
done

for required_command in git gh jq mktemp sed; do
    command -v "$required_command" >/dev/null 2>&1 || fail "required command not found: ${required_command}"
done
bash_path=$(find_bash) || fail 'Bash 5.1 or newer is required (macOS: brew install bash)'

git_version_output=$(git --version)
set -- $git_version_output
git_version=${3:-0.0.0}
git_major=${git_version%%.*}
git_remainder=${git_version#*.}
git_minor=${git_remainder%%.*}
case $git_major:$git_minor in
    *[!0-9:]*|:*) fail "could not parse Git version: ${git_version_output}" ;;
esac
if [ "$git_major" -lt 2 ] || { [ "$git_major" -eq 2 ] && [ "$git_minor" -lt 23 ]; }; then
    fail "Git 2.23 or newer is required; found ${git_version}"
fi

jq_version=$(jq --version 2>/dev/null)
jq_version=${jq_version#jq-}
jq_major=${jq_version%%.*}
jq_remainder=${jq_version#*.}
jq_minor=${jq_remainder%%.*}
case $jq_major:$jq_minor in
    *[!0-9:]*|:*) fail "could not parse jq version: ${jq_version}" ;;
esac
if [ "$jq_major" -lt 1 ] || { [ "$jq_major" -eq 1 ] && [ "$jq_minor" -lt 6 ]; }; then
    fail "jq 1.6 or newer is required; found ${jq_version}"
fi

case $prefix in /*) ;; *) fail "--prefix must be an absolute path: ${prefix}" ;; esac
case $config_dir in /*) ;; *) fail "--config-dir must be an absolute path: ${config_dir}" ;; esac
case $reviews_dir in /*) ;; *) fail "--reviews-dir must be an absolute path: ${reviews_dir}" ;; esac
case $github_repository in
    '') ;;
    *[!A-Za-z0-9_.-/]*|*/*/*|/*|*/) fail "--github-repository must be owner/repo: ${github_repository}" ;;
    *) ;;
esac

config_file=${config_dir}/config.json
if [ -n "$review_repo" ]; then
    case $review_repo in /*) ;; *) fail "--repo must be an absolute path: ${review_repo}" ;; esac
    [ -d "$review_repo" ] || fail "review repository does not exist: ${review_repo}"
    review_repo=$(CDPATH= cd "$review_repo" && pwd -P)
    repo_root=$(git -C "$review_repo" rev-parse --show-toplevel 2>/dev/null) || fail "not a Git repository: ${review_repo}"
    [ "$repo_root" = "$review_repo" ] || fail "--repo must point to the repository root: ${repo_root}"
    git -C "$review_repo" remote get-url origin >/dev/null 2>&1 || fail "review repository has no origin remote: ${review_repo}"
    if [ -z "$github_repository" ]; then
        github_repository=$(CDPATH= cd "$review_repo" && gh repo view --json nameWithOwner --jq .nameWithOwner) || fail "could not determine GitHub repository from --repo; pass --github-repository owner/repo"
    fi
elif [ ! -f "$config_file" ]; then
    fail '--repo is required for the first installation'
elif [ -n "$github_repository" ]; then
    fail '--github-repository can only be used with --repo'
fi

if [ -e "$config_file" ]; then
    [ -f "$config_file" ] || fail "configuration is not a regular file: ${config_file}"
    backup_existing_config
fi

mkdir -p "${prefix}/bin" "${prefix}/libexec/review-pr" "${prefix}/share/review-pr" "${prefix}/share/doc/review-pr" "${config_dir}/skills" "$config_dir"
install_file "${script_dir}/bin/review-pr" "${prefix}/libexec/review-pr/review-pr" 0755
install_file "${script_dir}/runners/review-pr-agy" "${prefix}/libexec/review-pr/review-pr-agy" 0755
install_file "${script_dir}/runners/review-pr-pi-guard.js" "${prefix}/libexec/review-pr/review-pr-pi-guard.js" 0644
printf '%s\n' "$config_file" >"${prefix}/libexec/review-pr/config-path"
chmod 0644 "${prefix}/libexec/review-pr/config-path"
install_file "${script_dir}/review-pr-launcher" "${prefix}/bin/review-pr" 0755
install_file "${script_dir}/config/review-pr.example.json" "${prefix}/share/review-pr/review-pr.example.json" 0644
install_file "${script_dir}/config/review-pr.schema.json" "${prefix}/share/review-pr/review-pr.schema.json" 0644
install_file "${script_dir}/config/review-pr-findings-v1.schema.json" "${prefix}/share/review-pr/review-pr-findings-v1.schema.json" 0644
install_file "${script_dir}/VERSION" "${prefix}/share/review-pr/VERSION" 0644
install_file "${script_dir}/README.md" "${prefix}/share/doc/review-pr/README.md" 0644
install_file "${script_dir}/docs/review-pr.md" "${prefix}/share/doc/review-pr/reference.md" 0644
install_file "${script_dir}/docs/review-pr-finding-contract.md" "${prefix}/share/doc/review-pr/review-pr-finding-contract.md" 0644
install_file "${script_dir}/CHANGELOG.md" "${prefix}/share/doc/review-pr/CHANGELOG.md" 0644
install_file "${script_dir}/config/review-pr.schema.json" "${config_dir}/review-pr.schema.json" 0644
install_file "${script_dir}/config/review-pr-findings-v1.schema.json" "${config_dir}/review-pr-findings-v1.schema.json" 0644
install_portable_skills "${script_dir}/skills"

if [ -f "$config_file" ]; then
    if [ -n "$review_repo" ] || [ "$reviews_dir_configured" = true ]; then
        config_temp=$(mktemp "${config_dir}/.config.json.tmp.XXXXXX")
        trap 'rm -f "$config_temp"' EXIT HUP INT TERM
        jq \
            --arg repository "$review_repo" \
            --arg github_repository "$github_repository" \
            --arg reviews_directory "$reviews_dir" \
            --argjson update_repository "$([ -n "$review_repo" ] && printf true || printf false)" \
            --argjson update_reviews_directory "$([ "$reviews_dir_configured" = true ] && printf true || printf false)" \
            'if $update_repository then
                if has("repositories") then
                    .default_repository as $alias |
                    .repositories[$alias].checkout = $repository |
                    .repositories[$alias].github = $github_repository
                else
                    del(.review_repository) |
                    .default_repository = "repository" |
                    .repositories = {
                        repository: {
                            github: $github_repository,
                            checkout: $repository
                        }
                    }
                end
             else . end |
             if $update_reviews_directory then .reviews_directory = $reviews_directory else . end' \
            "$config_file" >"$config_temp"
        mv "$config_temp" "$config_file"
        trap - EXIT HUP INT TERM
    fi
else
    config_temp=$(mktemp "${config_dir}/.config.json.tmp.XXXXXX")
    trap 'rm -f "$config_temp"' EXIT HUP INT TERM
    jq --arg repository "$review_repo" --arg github_repository "$github_repository" --arg reviews_directory "$reviews_dir" \
        '.repositories.repository.checkout = $repository |
         .repositories.repository.github = $github_repository |
         .reviews_directory = $reviews_directory' \
        "${script_dir}/config/review-pr.example.json" >"$config_temp"
    mv "$config_temp" "$config_file"
    trap - EXIT HUP INT TERM
fi
chmod 0644 "$config_file" "${config_dir}/review-pr.schema.json" "${config_dir}/review-pr-findings-v1.schema.json" \
    "${prefix}/share/review-pr/review-pr-findings-v1.schema.json" "${prefix}/share/review-pr/VERSION" \
    "${prefix}/share/doc/review-pr/CHANGELOG.md" "${prefix}/share/doc/review-pr/review-pr-finding-contract.md"

printf 'Installed review-pr %s using %s\n' "$package_version" "$bash_path"
printf 'Command: %s/bin/review-pr\n' "$prefix"
printf 'Config:  %s\n' "$config_file"
case :${PATH}: in
    *:"${prefix}/bin":*) ;;
    *) printf 'Add %s/bin to PATH before running review-pr.\n' "$prefix" ;;
esac
printf '%s\n' 'Authenticate GitHub CLI with `gh auth login`, configure the desired agents, then run `review-pr --show-config`.'
