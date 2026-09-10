#!/usr/bin/env bash

set -euo pipefail

if [[ -n "${REVIEW_PR_FAKE_GH_LOG:-}" ]]; then
    printf '%q ' "$@" >>"$REVIEW_PR_FAKE_GH_LOG"
    printf '\n' >>"$REVIEW_PR_FAKE_GH_LOG"
fi

case "${1:-} ${2:-}" in
    'repo view')
        if [[ " $* " == *' defaultBranchRef '* ]]; then
            if [[ "${REVIEW_PR_FAKE_DEFAULT_BRANCH_FAILURE:-false}" == true ]]; then
                printf '%s\n' 'fake default-branch lookup failed' >&2
                exit 1
            fi
            printf '%s\n' "${REVIEW_PR_FAKE_DEFAULT_BRANCH:-main}"
        else
            printf '%s\n' 'example/repository'
        fi
        ;;
    'pr view')
        jq -n \
            --arg body "${REVIEW_PR_FAKE_PR_BODY:-Fixture PR description.}" \
            --arg base_ref "${REVIEW_PR_FAKE_BASE_REF:-main}" \
            '{
            additions: 1,
            author: {login: "fixture", name: "Fixture Author"},
            baseRefName: $base_ref,
            body: $body,
            changedFiles: 1,
            deletions: 0,
            headRefName: "fixture/test",
            title: "FIX-123: Fixture PR",
            url: "https://example.test/example/repository/pull/123"
        }'
        ;;
    'api graphql')
        if [[ "${REVIEW_PR_FAKE_REVIEW_THREADS_FAILURE:-false}" == true ]]; then
            printf '%s\n' 'fake review-thread GraphQL lookup failed' >&2
            exit 1
        fi
        if [[ -n "${REVIEW_PR_FAKE_REVIEW_THREADS_JSON:-}" ]]; then
            printf '%s\n' "$REVIEW_PR_FAKE_REVIEW_THREADS_JSON"
        else
            printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}'
        fi
        ;;
    'api --paginate')
        endpoint=${*: -1}
        case "$endpoint" in
            *'/check-runs?'*) printf '%s\n' '{"check_runs":[]}' ;;
            *'/pulls/'*'/comments?'*)
                printf '%s\n' "${REVIEW_PR_FAKE_REVIEW_COMMENTS_JSON:-[]}" ;;
            *) printf '%s\n' '[]' ;;
        esac
        ;;
    api\ *)
        endpoint=${2:-}
        reference_sha=${REVIEW_PR_FAKE_REFERENCE_SHA:-1111111111111111111111111111111111111111}
        pull_head_sha=${REVIEW_PR_FAKE_PULL_HEAD_SHA:-$reference_sha}
        case "$endpoint" in
            'repos/example/repository/issues/122')
                printf '%s\n' '{"number":122,"state":"closed","html_url":"https://example.test/example/repository/issues/122","pull_request":{"url":"https://api.example.test/pulls/122"}}'
                ;;
            'repos/example/repository/pulls/122')
                jq -n --arg sha "$pull_head_sha" '{
                    number: 122,
                    state: "closed",
                    merged: true,
                    merged_at: "2026-01-01T00:00:00Z",
                    merge_commit_sha: $sha,
                    html_url: "https://example.test/example/repository/pull/122",
                    base: {ref: "main", repo: {full_name: "example/repository"}},
                    head: {ref: "fixture/dependency", sha: $sha, repo: {full_name: "example/repository"}}
                }'
                ;;
            repos/example/repository/commits/*)
                jq -n --arg sha "$reference_sha" '{sha: $sha, html_url: ("https://example.test/example/repository/commit/" + $sha)}'
                ;;
            *)
                printf 'Unknown fake GitHub API endpoint: %s\n' "$endpoint" >&2
                exit 1
                ;;
        esac
        ;;
    *)
        printf 'Unsupported fake gh invocation: ' >&2
        printf '%q ' "$@" >&2
        printf '\n' >&2
        exit 64
        ;;
esac
