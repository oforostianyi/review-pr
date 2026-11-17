## Classification table

| # | Source | Claim | Classification | Severity | Verification |
|---|---|---|---|---|---|
| 1 | Alpha | Context-only anchor | CONFIRMED | P1 | `src/Changed.php:13` |

<!-- review-pr:anchor:changed-line -->
### [P1] Context-only anchor

File: `src/Changed.php`
Line: `13`

Problem:
The finding points to an unchanged context line.

Failure scenario:
The inline comment cannot identify the changed cause.

Evidence:
Line 13 is outside the changed ranges.

Recommendation:
Use the actual changed reachability line.
