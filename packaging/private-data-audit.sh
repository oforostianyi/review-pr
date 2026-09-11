#!/usr/bin/env bash
#
# Private-data audit for the public review-pr repository.
#
# Scans every Git-tracked text file (never the working tree at large, never
# local configuration or review artifacts) for personal paths, company or
# ticket identifiers, private network addresses, and credential-like values.
# Allowed generic examples live in private-data-allowlist.txt next to this
# script. Exit status 1 with file:line output when anything is found.
#
# Usage: private-data-audit.sh [--root <repository>] [--allowlist <file>]

set -euo pipefail

script_dir=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
root=$(cd -P -- "$script_dir/.." && pwd -P)
allowlist="$script_dir/private-data-allowlist.txt"

while (( $# > 0 )); do
    case "$1" in
        --root)
            (( $# >= 2 )) || { printf 'Missing value for --root\n' >&2; exit 64; }
            root=$(cd -P -- "$2" && pwd -P)
            shift 2
            ;;
        --allowlist)
            (( $# >= 2 )) || { printf 'Missing value for --allowlist\n' >&2; exit 64; }
            allowlist=$2
            shift 2
            ;;
        --help | -h)
            sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            exit 64
            ;;
    esac
done

# Extended regular expressions. Personal paths, identifiers, and addresses are
# matched case-insensitively; credential shapes are case-sensitive by nature but
# -i does not weaken them meaningfully.
patterns=(
    '/home/[A-Za-z0-9._-]+'
    '/Users/[A-Za-z0-9._-]+'
    'brightlocal'
    'oforostianyi'
    'lenovo'
    'ZV/Projects'
    '\bLM-[0-9]{3,}\b'
    'Tools#[0-9]+'
    '\b192\.168\.[0-9]{1,3}\.[0-9]{1,3}\b'
    '\b10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\b'
    '\b172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}\b'
    'ghp_[A-Za-z0-9]{20,}'
    'github_pat_[A-Za-z0-9_]{20,}'
    '\bsk-[A-Za-z0-9_-]{20,}'
    'xox[abpr]-[A-Za-z0-9-]{10,}'
    'AKIA[0-9A-Z]{16}'
    '-----BEGIN [A-Z ]*PRIVATE KEY-----'
)
pattern_expression=$(IFS='|'; printf '%s' "${patterns[*]}")

declare -a allowed_patterns=() excluded_paths=()
if [[ -f "$allowlist" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%%#*}
        line=${line#"${line%%[![:space:]]*}"}
        line=${line%"${line##*[![:space:]]}"}
        [[ -n "$line" ]] || continue
        case "$line" in
            path:*) excluded_paths+=("${line#path:}") ;;
            pattern:*) allowed_patterns+=("${line#pattern:}") ;;
            *) printf 'Unrecognized allowlist entry (expected path: or pattern:): %s\n' "$line" >&2; exit 65 ;;
        esac
    done <"$allowlist"
fi

strip_allowed() {
    local text=$1 allowed
    for allowed in "${allowed_patterns[@]}"; do
        text=$(sed -E "s#${allowed}##g" <<<"$text")
    done
    printf '%s' "$text"
}

is_excluded() {
    local candidate=$1 excluded
    for excluded in "${excluded_paths[@]}"; do
        [[ "$candidate" == "$excluded" ]] && return 0
    done
    return 1
}

findings=0
while IFS= read -r -d '' tracked; do
    is_excluded "$tracked" && continue
    file="$root/$tracked"
    [[ -f "$file" ]] || continue
    grep -Iq . "$file" 2>/dev/null || continue
    while IFS= read -r hit; do
        [[ -n "$hit" ]] || continue
        line_number=${hit%%:*}
        content=${hit#*:}
        stripped=$(strip_allowed "$content")
        if grep -Eiq -- "$pattern_expression" <<<"$stripped"; then
            printf '%s:%s: %s\n' "$tracked" "$line_number" "$content"
            findings=$((findings + 1))
        fi
    done < <(grep -nEi -- "$pattern_expression" "$file" || true)
done < <(git -C "$root" ls-files -z)

if (( findings > 0 )); then
    printf 'Private-data audit failed: %s finding(s) in tracked files.\n' "$findings" >&2
    exit 1
fi
printf 'Private-data audit passed: no private paths, identifiers, addresses, or credentials in tracked files.\n'
