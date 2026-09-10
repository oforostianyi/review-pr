#!/usr/bin/env bash

set -euo pipefail

TEST_ASSERTIONS=0

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

    mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX"
}

