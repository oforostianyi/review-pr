# Portable atomic-finding contract

Status: accepted on 2026-09-10; implementation is proceeding as an opt-in staged rollout.
The primary, cross-review, and final parsers, canonical sidecars, deterministic renderers, and
bounded field-stable schema-repair passes are implemented behind independent opt-in settings.

## Problem

The current Markdown reports are useful to humans but are a fragile machine interface. Localized
headings, tables, escaped pipes, compound claims, and model-specific prose make deterministic
classification, deduplication, and validation harder than necessary. Native structured-output flags
cannot be required because review-pr supports generic runners and agent CLIs with different feature
sets.

The new contract must remain portable, preserve the original response, survive partial output
diagnostically, and keep old Markdown-only runs usable for final reruns.

## Options considered

| Option | Strengths | Weaknesses | Decision |
|---|---|---|---|
| One strict JSON document | Familiar schema; easy validation when complete | One truncation or escaping error invalidates the entire response; poor streaming diagnostics | Reject |
| Human Markdown plus embedded JSON | Keeps model-authored Markdown and adds structure | Duplicates long evidence; sections can disagree; materially increases output-token pressure | Reject |
| NDJSON records rendered to Markdown | One atomic record per line; compact; language-independent control plane; deterministic human rendering | Changes the orchestrated output contract and needs a compatibility adapter | Recommend |

## Recommended v1 protocol

In orchestrated mode, an agent returns only newline-delimited JSON records. It does not need native
JSON-schema support: every CLI can return plain text. Each physical line is one complete JSON
object. The final record is mandatory and proves that generation completed.

Example:

```jsonl
{"record":"finding","schema_version":1,"source_id":"F-001","title":"Retry loses the original command","claim":"A retry replaces the command payload before dispatch.","anchor":{"kind":"changed-line","file":"src/Retry.php","start":42,"end":42},"evidence":["Line 42 assigns the fallback payload before the original value is read."],"failure_scenario":"A timed-out job retries with different input.","recommendation":"Preserve the original payload until dispatch succeeds.","classification":null,"severity":"P1","category":"correctness","contributing_agents":["codex"],"verification_limitations":[],"existing_feedback":{"state":"new","thread_ids":[]}}
{"record":"complete","schema_version":1,"finding_count":1,"summary":"One actionable correctness issue was found.","verification_limitations":[],"positive_evidence":[]}
```

Required finding fields:

- `source_id`: stable and unique within one source report;
- `title` and one atomic `claim`;
- `anchor.kind`: `changed-line` or `pr-level`;
- `anchor.file`, `anchor.start`, and `anchor.end`, nullable only for `pr-level`;
- `evidence` and `failure_scenario`; a classified `REJECTED` or `UNCERTAIN` record may set
  `failure_scenario` to `null` or `""` because no failure scenario applies to a refuted or unproven claim;
- `recommendation`;
- `classification`: `CONFIRMED`, `REJECTED`, `UNCERTAIN`, or `null` when the phase does not classify;
- `severity`: `P0`, `P1`, `P2`, `P3`, or `null` when it does not apply;
- `category` or pattern;
- `contributing_agents` and source provenance;
- `verification_limitations`;
- `existing_feedback.state`: `new`, `confirmed-existing`, `historical`, or `unknown`, with thread IDs when known.

Cross-review records additionally contain `source_refs`, a non-empty array of `{agent, source_id}`
objects. The agent key makes source-local IDs unambiguous across reports. Every supplied source ref
must be covered and unknown refs are rejected. A compound source claim may become multiple records
so each classification remains atomic. Consolidation may merge duplicate records, but it retains
every source ref and contributing agent.

Final records use the same `source_refs` shape for canonical cross-review records and add
`include_in_rejected_summary`. That boolean is valid only as `true` on a `REJECTED` record and
controls presentation, not classification. Canonical final sidecars additionally contain derived
`primary_refs`; this field is produced by the orchestrator and is never accepted from model output.

## Accepted structured final-synthesis design

The final phase will use the same NDJSON transport and finding vocabulary, but its `source_refs`
point to cross-review records rather than directly to primary records. The phase is therefore
unambiguous without globally unique model-generated IDs: `{agent, source_id}` is interpreted against
the canonical sidecars supplied for that phase.

The final runtime must enforce these rules:

- `final: "ndjson-v1"` is opt-in and requires structured primary and cross-review inputs;
- the finalizer receives canonical cross-review JSON, never localized cross-review Markdown as its
  machine input, and never receives report text as executable instructions;
- every cross-review `{agent, source_id}` must be referenced by at least one final record, while an
  unknown reference is invalid;
- genuine duplicates may be merged and compound claims may be split, but source provenance cannot
  be dropped; no source-free new finding is allowed in synthesis;
- classification is `CONFIRMED`, `REJECTED`, or `UNCERTAIN`; only `CONFIRMED` carries `P0`–`P3`;
- the orchestrator derives transitive primary provenance from the validated cross-review graph. The
  model does not restate or invent primary provenance;
- source code and concrete evidence remain authoritative: coverage proves that a claim was
  considered, not that majority voting decided it;
- one additional final-only boolean will state whether an important rejected decision belongs in
  the human `Rejected findings` section. It does not affect classification;
- the terminal `complete` record remains mandatory and no records may follow it.

The deterministic final renderer will own the PR heading and two-column metadata table, the full
classification table, detailed actionable sections for confirmed findings, and the optional
important-rejections section. It will generate the existing language-independent anchor markers so
the current exact RIGHT-side anchor validator remains authoritative. Reader-facing strings are
localized; enums, IDs, provenance, and validation controls are not.

Final schema repair is bounded separately from semantic synthesis. It may repair transport or
record metadata only after all decision records are safely parseable, and keeps classification,
severity, cross-review refs, derived primary provenance, anchors, and substantive fields stable.
Failure preserves the original and repair responses and publishes no canonical final report.

## Artifact flow

For each phase, the orchestrator should preserve three distinct artifacts:

1. `*-raw.ndjson` — the exact agent response, never silently rewritten;
2. `*-findings.json` — a validated canonical array plus protocol/completeness metadata;
3. the existing `*.md` report — rendered deterministically in the configured language.

The Markdown renderer, not localized headings, becomes the source of table and section structure.
Free-form evidence remains in the configured report language, while enums, markers, IDs, and schema
keys remain language-independent.

## Validation and repair policy

- Strip only known transport wrappers such as a single outer code fence before parsing; preserve the
  original bytes separately.
- Parse each line independently and require exactly one terminal `complete` record whose
  `finding_count` matches the number of finding records.
- Validate enums, unique IDs, phase-specific classification rules, and changed-line anchors before
  publishing canonical JSON or Markdown.
- A truncated stream without `complete` is a failed report even if earlier records parse. Preserve
  those records as diagnostics; never publish them as a successful review.
- Before an ordinary whole-review retry, allow one bounded repair attempt only when every finding is
  already a parseable object with a unique `source_id` and every substantive field present. Leading
  or trailing transport prose, fences, record/schema metadata, and a missing or malformed terminal
  completion record are repairable. Broken JSON-looking records, unknown record types, duplicate
  completion records, and missing substantive finding fields are ineligible because recovery would
  require guessing.
- Preserve both responses. The repaired report must pass the full schema, completeness, provenance,
  and RIGHT-side anchor validation. Compare the ordered findings by `source_id` using canonical JSON
  for `title`, `claim`, `anchor`, `evidence`, `failure_scenario`, `recommendation`, `classification`,
  `severity`, `category`, `contributing_agents`, `verification_limitations`, and
  `existing_feedback`. No finding may be added, removed, reordered, split, merged, translated, or
  rewritten. Preserve valid completion prose; when none is safely recoverable, require an empty
  summary and arrays. If stability cannot be established, fail closed instead of publishing repair.
- Cross-review repair applies the same rule and additionally freezes `source_refs`, classification,
  severity, and contributing agents. The repaired stream must still cover every canonical primary
  `{agent, source_id}` input and may not introduce an unknown source ref.
- Keep current Markdown validation as a legacy adapter for historical manifests. Legacy fields that
  cannot be recovered become explicit `null`/`unknown`, not invented values.

## Rollout sequence

1. Add a versioned JSON Schema and fixtures from Claude, Codex, Pi, Antigravity, and the local LM
   Studio model, including truncation and malformed escaping.
2. Implement parser, completeness checks, canonical sidecar, and deterministic renderer behind an
   opt-in configuration flag.
3. Add primary-review support, then cross-review provenance/atomic splitting, then final synthesis.
4. Exercise historical Markdown reruns and mixed old/new inputs.
5. Make v1 the default only after all configured runners pass the same contract suite; retain an
   explicit legacy mode for existing reports.

## Accepted decision

NDJSON is the machine source of truth for new opt-in orchestrated phases. Human Markdown is rendered
deterministically. Markdown remains the default during migration, there is no silent fallback, and
historical Markdown artifacts remain supported.
