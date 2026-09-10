#!/usr/bin/env bash

set -euo pipefail

test_dir=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo_root=$(cd -P -- "$test_dir/../.." && pwd -P)
source "$test_dir/lib/assert.sh"

export REVIEW_PR_LIBRARY_MODE=true
# shellcheck source=/dev/null
source "$repo_root/bin/review-pr" --
unset REVIEW_PR_LIBRARY_MODE

test_root=$(portable_mktemp_dir review-pr-github-context)
trap 'rm -rf -- "$test_root"' EXIT

export PATH="$test_dir:$PATH"
ln -s "$test_dir/fake-gh.sh" "$test_root/gh"
export PATH="$test_root:$PATH"

GITHUB_REPOSITORY=example/repository
PR_NUMBER=123
HEAD_SHA=1111111111111111111111111111111111111111
PR_BODY='Fixture body.'
WORK_DIR=$test_root
REPORT_STEM=fixture

export REVIEW_PR_FAKE_REVIEW_THREADS_JSON
REVIEW_PR_FAKE_REVIEW_THREADS_JSON=$(printf '%s\n' \
    '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"THREAD-1","isResolved":false,"isOutdated":false,"path":"src/One.php","line":10,"originalLine":null,"comments":{"totalCount":1,"nodes":[{"fullDatabaseId":"101"}]}}],"pageInfo":{"hasNextPage":true,"endCursor":"cursor-1"}}}}}}' \
    '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"THREAD-2","isResolved":true,"isOutdated":true,"path":"src/Two.php","line":20,"originalLine":18,"comments":{"totalCount":2,"nodes":[{"fullDatabaseId":"102"},{"fullDatabaseId":"103"}]}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}')
export REVIEW_PR_FAKE_REVIEW_COMMENTS_JSON
REVIEW_PR_FAKE_REVIEW_COMMENTS_JSON=$(jq -cn '[
    {id:101, user:{login:"reviewer"}, path:"src/One.php", line:10, created_at:"2026-01-01T00:00:00Z", body:"Open concern", html_url:"https://example.test/comments/101"},
    {id:102, user:{login:"reviewer"}, path:"src/Two.php", line:20, created_at:"2026-01-02T00:00:00Z", body:"Resolved concern", html_url:"https://example.test/comments/102"},
    {id:103, in_reply_to_id:102, user:{login:"author"}, path:"src/Two.php", line:20, created_at:"2026-01-03T00:00:00Z", body:"Resolved reply", html_url:"https://example.test/comments/103"},
    {id:999, user:{login:"race"}, path:"src/New.php", line:30, created_at:"2026-01-04T00:00:00Z", body:"Comment created between snapshots", html_url:"https://example.test/comments/999"}
]')

fetch_github_pr_context
assert_eq complete "$PR_REVIEW_THREADS_STATUS" \
    'multi-page GraphQL review-thread collection is complete'
assert_eq '2' "$(jq -r 'length' <<<"$PR_REVIEW_THREADS_JSON")" \
    'all GraphQL thread pages are combined'

write_github_context_snapshot
assert_file_contains "$PR_CONTEXT_FILE" '- Availability: `complete`' \
    'GitHub context records thread-state availability'
assert_file_contains "$PR_CONTEXT_FILE" '- Thread state: `unresolved`' \
    'top-level unresolved feedback is mapped from GraphQL to its REST comment ID'
assert_file_contains "$PR_CONTEXT_FILE" '- Thread state: `resolved`' \
    'resolved feedback remains visible as historical context'
assert_file_contains "$PR_CONTEXT_FILE" '- Role: reply' \
    'review replies are explicitly distinguished from top-level feedback'
assert_file_contains "$PR_CONTEXT_FILE" '- Outdated: `true`' \
    'outdated resolved threads are marked explicitly'
assert_file_contains "$PR_CONTEXT_FILE" 'unknown (comment was not mapped to the captured threads)' \
    'a REST/GraphQL snapshot race remains explicit instead of dropping the comment'

export REVIEW_PR_FAKE_REVIEW_THREADS_FAILURE=true
fetch_github_review_threads
assert_eq unavailable "$PR_REVIEW_THREADS_STATUS" \
    'GraphQL failure is not represented as an empty complete thread set'
assert_eq graphql_request_failed "$PR_REVIEW_THREADS_REASON" \
    'GraphQL failure has a stable limitation reason'
REPORT_STEM=fixture-unavailable
write_github_context_snapshot
assert_file_contains "$PR_CONTEXT_FILE" '- Availability: `unavailable`' \
    'GitHub context exposes unavailable thread state'
assert_file_contains "$PR_CONTEXT_FILE" 'do not interpret this as zero unresolved threads' \
    'unavailable thread state carries an explicit conservative instruction'
unset REVIEW_PR_FAKE_REVIEW_THREADS_FAILURE

REVIEW_PR_FAKE_REVIEW_THREADS_JSON='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"THREAD-PARTIAL","isResolved":false,"isOutdated":false,"path":"src/Many.php","line":1,"originalLine":null,"comments":{"totalCount":101,"nodes":[{"fullDatabaseId":"201"}]}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}'
fetch_github_review_threads
assert_eq partial "$PR_REVIEW_THREADS_STATUS" \
    'a thread with more nested comments than captured is explicitly partial'
assert_eq nested_comment_pagination_incomplete "$PR_REVIEW_THREADS_REASON" \
    'nested pagination limitation is machine-stable'

printf '%s assertions passed.\n' "$TEST_ASSERTIONS"
