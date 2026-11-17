## Classification table

| # | Source | Claim | Classification | Severity | Verification |
|---|---|---|---|---|---|
| 1 | Alpha | Changed defect | CONFIRMED | P1 | `src/Changed.php:10` |
| 2 | Beta | Missing integration test | CONFIRMED | P2 | No test covers the new path. |

<!-- review-pr:anchor:changed-line -->
### [P1] Changed defect

File: `src/Changed.php`
Line: `8-10`

Problem:
The changed line introduces a regression.

Failure scenario:
The request fails.

Evidence:
The range ends on a changed RIGHT-side line; earlier range lines are context.

Recommendation:
Correct the changed branch.

<!-- review-pr:anchor:pr-level -->
### [P2] Missing integration test

File: —
Line: —

Problem:
The PR omits coverage for the new integration path.

Failure scenario:
A later regression is not detected.

Evidence:
No suitable test exists in the diff.

Recommendation:
Add an integration test.
