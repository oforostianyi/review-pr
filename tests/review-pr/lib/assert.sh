#!/usr/bin/env bash

set -euo pipefail

TEST_ASSERTIONS=0

# The tests write thousands of short-lived files. An endpoint scanner on the
# development laptop checks every one of them under /tmp but leaves /dev/shm
# alone (it chooses by path, not by file system), so the suite runs there when
# /dev/shm is a writable tmpfs with room to spare; an explicit TMPDIR, macOS, or
# a container with a small /dev/shm keeps the usual temporary directory.
if [[ -z "${TMPDIR:-}" && -d /dev/shm && -w /dev/shm ]]; then
    shm_free_kb=$(df -Pk /dev/shm 2>/dev/null | awk 'NR == 2 { print $4 }') || shm_free_kb=0
    [[ "$shm_free_kb" =~ ^[0-9]+$ ]] || shm_free_kb=0
    # The suite runs scripts it writes there (fake CLIs, the installed launcher),
    # so a noexec mount keeps the usual temporary directory too.
    if (( shm_free_kb >= 1048576 )) && shm_probe=$(mktemp /dev/shm/review-pr-exec-probe.XXXXXX 2>/dev/null); then
        printf '#!/bin/sh\nexit 0\n' >"$shm_probe"
        chmod 700 "$shm_probe"
        ! "$shm_probe" 2>/dev/null || export TMPDIR=/dev/shm
        rm -f "$shm_probe"
    fi
    unset shm_free_kb shm_probe
fi

# Every fixture repository commits, pushes and fetches, and git follows each of
# those with an automatic maintenance run -- several hundred processes in the
# pipeline tests that keep nothing tidy, since the repositories are thrown away.
if [[ -z "${GIT_CONFIG_COUNT:-}" ]]; then
    export GIT_CONFIG_COUNT=2
    export GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false
    export GIT_CONFIG_KEY_1=gc.auto GIT_CONFIG_VALUE_1=0
fi

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

pass() {
    printf 'ok - %s\n' "$1"
}

assert_true() {
    local message=$1
    shift

    TEST_ASSERTIONS=$((TEST_ASSERTIONS + 1))
    if "$@"; then
        pass "$message"
    else
        fail "$message"
    fi
}

assert_false() {
    local message=$1
    shift

    TEST_ASSERTIONS=$((TEST_ASSERTIONS + 1))
    if "$@"; then
        fail "$message"
    else
        pass "$message"
    fi
}

assert_eq() {
    local expected=$1
    local actual=$2
    local message=$3

    TEST_ASSERTIONS=$((TEST_ASSERTIONS + 1))
    if [[ "$actual" == "$expected" ]]; then
        pass "$message"
    else
        fail "${message}: expected <${expected}>, got <${actual}>"
    fi
}

assert_file_exists() {
    local file=$1
    local message=$2

    TEST_ASSERTIONS=$((TEST_ASSERTIONS + 1))
    [[ -f "$file" ]] || fail "${message}: missing ${file}"
    pass "$message"
}

assert_file_not_exists() {
    local file=$1
    local message=$2

    TEST_ASSERTIONS=$((TEST_ASSERTIONS + 1))
    [[ ! -e "$file" ]] || fail "${message}: unexpected ${file}"
    pass "$message"
}

assert_file_contains() {
    local file=$1
    local needle=$2
    local message=$3

    TEST_ASSERTIONS=$((TEST_ASSERTIONS + 1))
    grep -Fq -- "$needle" "$file" || fail "${message}: ${needle} not found in ${file}"
    pass "$message"
}

portable_mktemp_dir() {
    local prefix=${1:-review-pr-test}
    local directory

    # Return the canonical path: macOS resolves $TMPDIR through /private and the
    # orchestrator canonicalizes the paths it records, so tests compare like with like.
    directory=$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX")
    (cd -P -- "$directory" && pwd -P)
}

# Replaces the first literal occurrence of $1 with $2 on stdin. Portable across
# GNU and BSD tools, unlike sed's GNU-only "0,/re/" address.
replace_first_literal() {
    awk -v needle="$1" -v replacement="$2" '
        !done { position = index($0, needle); if (position > 0) { $0 = substr($0, 1, position - 1) replacement substr($0, position + length(needle)); done = 1 } }
        { print }'
}
