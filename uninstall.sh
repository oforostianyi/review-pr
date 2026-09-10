#!/bin/sh

set -eu

[ -n "${HOME:-}" ] || {
    printf '%s\n' 'uninstall.sh: HOME is not set' >&2
    exit 1
}

prefix=${REVIEW_PR_PREFIX:-${HOME}/.local}
purge_config=false

while [ "$#" -gt 0 ]; do
    case $1 in
        --prefix)
            [ "$#" -ge 2 ] || { printf '%s\n' 'uninstall.sh: --prefix requires a path' >&2; exit 1; }
            prefix=$2
            shift 2
            ;;
        --purge-config)
            purge_config=true
            shift
            ;;
        --help|-h)
            printf '%s\n' 'Usage: ./uninstall.sh [--prefix <path>] [--purge-config]'
            exit 0
            ;;
        *) printf 'uninstall.sh: unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done

rm -f "${prefix}/bin/review-pr" "${prefix}/libexec/review-pr/review-pr" "${prefix}/libexec/review-pr/review-pr-agy" "${prefix}/libexec/review-pr/config-path"
rmdir "${prefix}/libexec/review-pr" 2>/dev/null || true
rm -f "${prefix}/share/review-pr/review-pr.example.json" "${prefix}/share/review-pr/review-pr.schema.json" \
    "${prefix}/share/review-pr/review-pr-findings-v1.schema.json" "${prefix}/share/review-pr/VERSION"
rmdir "${prefix}/share/review-pr" 2>/dev/null || true
rm -f "${prefix}/share/doc/review-pr/README.md" "${prefix}/share/doc/review-pr/reference.md" \
    "${prefix}/share/doc/review-pr/review-pr-finding-contract.md" "${prefix}/share/doc/review-pr/CHANGELOG.md"
rmdir "${prefix}/share/doc/review-pr" 2>/dev/null || true

if [ "$purge_config" = true ]; then
    config_root=${XDG_CONFIG_HOME:-${HOME}/.config}
    config_dir=${REVIEW_PR_CONFIG_DIR:-${config_root}/review-pr}
    rm -f "${config_dir}/config.json" "${config_dir}/review-pr.schema.json" \
        "${config_dir}/review-pr-findings-v1.schema.json"
    rmdir "$config_dir" 2>/dev/null || true
    printf 'Removed review-pr and configuration from %s\n' "$config_dir"
else
    printf '%s\n' 'Removed review-pr. Configuration was preserved.'
fi
