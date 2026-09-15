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

Anchor policy: a finding is anchored to the changed line that causes it. An existing consumer,
caller, or flow that the change breaks or exposes is anchored to the changed line that creates the
exposure (the new constant, enum case, signature, query, or call). `pr-level` is the fallback only
when no changed line causes the finding, such as missing or stale test coverage, a missing
migration, or a documentation gap; such a record names the affected file and symbol in `evidence`.
The primary prompt also maps the review skill's Markdown report sections onto record fields so
that consumer tracing, flow replay, and plausible-but-unverified findings survive the structured
contract instead of being dropped for lack of a place to report them. Configured Markdown-oriented
`prompts.cross_review` and `prompts.final` instructions are not forwarded under `ndjson-v1`.

Cross-review and final prompts end with a `REQUIRED SOURCE REFS` block: the orchestrator lists every
`{agent, source_id}` pair the response must cover, copied from the canonical inputs, and the final
prompt presents the upstream primary refs of each cross-review record under `primary_provenance` so
they cannot be mistaken for the refs to cover.

Cross-review records additionally contain `source_refs`, a non-empty array of `{agent, source_id}`
objects, each copied verbatim from the `record_ref` of a supplied record. The agent key makes
source-local IDs unambiguous across reports. Every supplied source ref must be covered and unknown
refs are rejected, with one mechanical exception: when a cited `source_id` belongs to exactly one
supplied record, the orchestrator corrects a mislabelled agent key to that owner before validating,
and says so in the log. An unknown or ambiguous `source_id` is never guessed at. A compound source claim may become multiple records
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

## Accepted dispute-resolution design (opt-in `resolution` records)

Cross-reviewers regularly disagree about the same primary finding: one classifies it `CONFIRMED`,
another `REJECTED` or `UNCERTAIN`, or both confirm it with different severities. Today the
finalizer resolves such disputes in prose inside `evidence`; nothing records what kind of dispute it
was, how it was settled, or which measurement settled it. The accepted design makes that decision
machine-readable without breaking `ndjson-v1`: no new required field is added to existing records,
and a run without the feature validates exactly as before.

### Configuration and scope

- `reporting.dispute_resolution: true` (default `false`) enables the feature. It requires
  `reporting.finding_contract.final = "ndjson-v1"`; configuration validation rejects it otherwise.
- The orchestrator, not the model, detects disputes deterministically from the canonical
  cross-review sidecars. A **dispute** exists for a primary `{agent, source_id}` when the
  cross-review records that reference it disagree in classification, or agree on `CONFIRMED` with
  different severities. Each dispute gets a stable `dispute_id` derived from the primary ref, for
  example `dispute:codex:codex.p1.hidden-address-notes`.
- The final prompt lists every dispute in a `REQUIRED RESOLUTIONS` block: `dispute_id`, the primary
  ref, and each contributing cross-review `{agent, source_id, classification, severity}`. The
  finalizer must emit exactly one `resolution` record per listed dispute and no other resolution
  records. Historical manifests without the block stay valid.

### The `resolution` record

One additional record type in the same final NDJSON stream, before the terminal `complete`:

```jsonl
{"record":"resolution","schema_version":1,"dispute_id":"dispute:codex:codex.p1.hidden-address-notes","primary_ref":{"agent":"codex","source_id":"codex.p1.hidden-address-notes"},"conflicting_refs":[{"agent":"claude","source_id":"claude.x1.hidden-address-divergence-note"},{"agent":"pi","source_id":"xrev-hidden-address-notes-leak"}],"final_source_id":"syn-1-hidden-address-notes-leak","dispute_kind":"factual","resolution_status":"resolved","verification_method":"command","command":["rg","-n","address","src/Modules/Sysadmin/CB/Application/Service/Export/Transformers/FoursquareIngestion/LocationTransformer.php"],"observed":"Lines 143-151 append street and postcode to the notes cell for hidden-address rows.","basis":"general_engineering","basis_source":null,"limitations":[]}
```

Fields and their rules:

- `dispute_id`, `primary_ref`, `conflicting_refs`: copied from the `REQUIRED RESOLUTIONS` block;
  `conflicting_refs` must name exactly the listed cross-review refs by `agent` and `source_id`.
  The listed `classification` and `severity` may be copied along; the canonical sidecar keeps only
  `agent` and `source_id`.
- `final_source_id`: the `source_id` of the final finding record that carries the decision for
  this dispute. That record must exist and its `source_refs` must include at least one
  `conflicting_refs` entry: a compound primary finding is often split by the cross-reviewers into
  topics that land in different final records, so one record cannot be required to cover them all.
- `dispute_kind`: `factual` (the reviewers disagree about what the code does or whether something
  exists), `severity` (they agree on the fact and disagree on impact), or `mixed`.
- `resolution_status`: `resolved`, `uncertain`, or `not_applicable` (allowed only for `severity`
  disputes, where synthesis reconciles impact without a measurement).
- `verification_method`: `source`, `command`, `test`, `repository_rule`, `runtime`, or `manual`.
  A `factual` or `mixed` dispute may be `resolved` only with a method other than `manual`, and the
  covering final record may be `CONFIRMED` only when the dispute is `resolved`. When the fact could
  not be measured the status is `uncertain` and the covering final record must be `UNCERTAIN`:
  agent count never settles a factual dispute.
- `command`: `null`, or the measurement as an argv array of non-empty strings (no shell string, no
  evaluation). In this iteration the orchestrator records but does not execute it; a later
  iteration may execute an allow-listed subset in the detached checkout and replace `observed` with
  the captured result. `command` is required when `verification_method` is `command` or `test`.
- `observed`: what the measurement or source read showed, in the final language, bounded in length.
  Required non-empty when `resolution_status` is `resolved`; `null` or empty otherwise, when nothing
  was observed.
- `basis`: `explicit_repository_rule`, `skill_rule`, `inferred_convention`, or `general_engineering`.
  `basis_source` is required for `explicit_repository_rule` (a repository path, optionally
  `path:line`) and for `skill_rule` (the configured skill name, never an absolute private path);
  it must be `null` otherwise. A covering final record whose only basis is `inferred_convention`
  cannot carry `P0` or `P1`.
- `limitations`: a string array of what remains unverified; may be empty.

### Validation, repair, rendering, artifacts

- Validation runs after the existing final checks: complete coverage of the required disputes, no
  unknown `dispute_id`, exact `conflicting_refs`, `final_source_id` linkage, the method/status/
  classification rules above, and the severity rule for inferred conventions. Failures use the
  existing granular reason format, for example
  `dispute_resolution_validation_failed: resolution[dispute:codex:codex.p1.hidden-address-notes].verification_method`.
- Schema repair may fix transport and record metadata of resolution records but freezes
  `dispute_kind`, `resolution_status`, `verification_method`, `command`, `observed`, `basis`,
  `basis_source`, and the refs, exactly as it freezes finding decisions.
- The orchestrator publishes `*-final-resolutions.json` (the validated resolution array plus the
  detected dispute list) beside `*-final-findings.json`, records it in the manifest, and the
  deterministic final renderer adds a compact localized `Dispute resolutions` table (dispute kind,
  status, method, observed excerpt, basis) with a language-independent marker. Merged duplicates
  reference the same resolution once.
- The standalone comparison, the cross-review phase, and historical Markdown or `ndjson-v1` runs
  without the flag are unchanged.

### Orchestrator-executed measurements (iteration 2)

`reporting.execute_measurements: true` (requires `dispute_resolution`) lets the orchestrator run the
`command` of a `command` or `test` resolution after the final stream validated, inside the review
checkout at the exact PR head, and attach the result as a separate `measurement` object:
`executed`, `skipped_reason`, `exit_status`, bounded and credential-redacted `stdout_excerpt` and
`stderr_excerpt`, `duration_ms`, and `commit`. The model's `observed` text is never rewritten and the
resolution decision is never changed automatically; a disagreement between the two is for the reader.

Policy, fixed in this iteration: argv only, no shell; allow-listed read-only tools (`rg`, `grep`,
`ls`, `cat`, `head`, `wc`, `test`, `git` restricted to `show`, `log`, `diff`, `ls-tree`, `cat-file`,
`grep`, `rev-parse`, `blame`); no absolute or parent-directory paths; no `rg --pre`; no `git -c`,
`-C`, `--exec-path`, `--git-dir`, `--work-tree`, `--config-env`, `--namespace`; a ten-second timeout
per command; excerpts capped at 2000 characters after redaction. Everything else is recorded as
`skipped: not_allowlisted` and never executed. Artifact-only final reruns record
`skipped: checkout_unavailable`. Schema repair does not compare measurements: they are attached after
validation and are orchestrator output, not model content.

### Rollout for this feature

1. Design (this section) and the versioned schema additions with positive and negative fixtures:
   factual, severity, mixed, uncertain, explicit rule, inferred convention; and the invalid cases
   "factual resolved by count", "command without observed", "CONFIRMED over an unresolved factual
   premise", "inferred convention presented as explicit rule".
2. Dispute detection, `REQUIRED RESOLUTIONS` prompt block, parser and semantic validation with
   stable failure reasons, repair stability, canonical sidecar and manifest entry.
3. Deterministic renderer and end-to-end tests with mock scenarios; the feature stays opt-in.
4. Orchestrator-executed allow-listed measurements behind `reporting.execute_measurements`
   (done as iteration 2).

## Accepted diagnostics and positive-evidence design (Milestone 6)

Every phase already reports `verification_limitations` (per finding and per completion record) and
`positive_evidence` (per completion record) as free text. Free text means one plain string per entry:
an entry that names a file and a symbol carries both inside that string, never as an object. The three
phase contracts state this explicitly, because a reviewer told only to name "the file and the symbol"
will otherwise encode them as fields, which the validator rejects and the bounded repair may not
rewrite. As free text, and the orchestrator itself knows a set of
states that limit verification: GitHub review-thread state, check-run conclusions, changed-line map
availability, repository-facts measurement failures, failed agent attempts, Pi guard outcomes, and
skipped measurements. Today none of this reaches the final report: the deterministic final renderer
drops both arrays, and orchestrator states live only in logs. The design below makes limitations
and positive evidence a normalized, deduplicated part of the final artifacts without changing any
`ndjson-v1` record: model records stay as they are; the orchestrator adds a typed sidecar and renders
both sources deterministically.

### Two sources, one artifact

`*-final-diagnostics.json` is written by the orchestrator whenever the final contract is
`ndjson-v1`, next to `*-final-findings.json`, and recorded in the manifest as
`artifacts.final_diagnostics`. It has three parts:

1. `orchestrator`: typed records the orchestrator measured itself. Each record is
   `{"type", "scope", "phase", "agent", "detail", "refs"}` where `type` is one of a stable enum:
   `github_review_threads_unavailable`, `github_review_threads_partial`, `github_check_failed`,
   `github_check_cancelled`, `github_check_pending`, `github_check_skipped`,
   `changed_line_map_unavailable`, `repository_facts_measurement_failed`, `agent_attempt_timeout`,
   `agent_attempt_output_limit`, `agent_attempt_invalid_output`, `agent_attempt_failed`,
   `pi_guard_budget_exhausted`, `pi_guard_duplicates_blocked`, `measurement_skipped`,
   `checkout_unavailable`; `scope` is `run`, `phase`, `agent`, or `finding`; `detail` is a short
   English string with the exact value (check name and conclusion, attempt number, reason);
   `refs` lists affected `{agent, source_id}` or dispute ids when known. Types are the dedup key.
2. `reviewers`: model-reported limitations aggregated from every canonical sidecar of the run
   (primary, cross-review, final; per-finding and completion-level). Each entry is
   `{"text", "phases", "agents", "finding_refs"}`; entries are merged when their normalized text
   (lower-cased, whitespace-collapsed, trailing punctuation removed) is equal, keeping every
   contributing phase and agent. All phases of a run share the configured language, so text-level
   merging is deterministic within a run; it is not claimed across languages.
3. `positive_evidence`: completion-level positive evidence aggregated the same way, with an
   explicit `kind`: `verified_safe` when the text names a file or symbol that was checked, or
   `no_issue_found` otherwise (a heuristic label, marked as such). Positive evidence never changes
   a finding's classification or severity; it is presentation only, and the renderer caps the list
   at twelve items, keeping the ones with the most contributing agents first.

### Prompts

- Primary, cross-review, and final contracts gain one rule: a failed, pending, or skipped CI check,
  a denied or failing tool, or an unavailable file is a verification limitation, never a finding by
  itself; a finding needs source or runtime evidence of engineering impact.
- The final prompt gains a `KNOWN LIMITATIONS` block listing the orchestrator records collected so
  far (one compact JSON line each), so the finalizer references them instead of rediscovering or
  contradicting them, and lists what remains unverified in its own `verification_limitations`.

### Validation

- A final finding whose evidence consists only of a CI check outcome or a tool failure is rejected
  with `diagnostic_only_finding` (deterministic check: every evidence string matches the
  check-outcome or tool-failure patterns and no evidence names a repository path or symbol). This
  is a post-check on the canonical final, reported through the existing granular reason format.
- The diagnostics sidecar itself is orchestrator output and is not validated against the model.

### Rendering

The final Markdown gains two sections after the rejected findings and the dispute table, each under
a language-independent marker: `<!-- review-pr:verification-limitations -->` with
`## Verification limitations` / `## Обмеження перевірки` (orchestrator records first with a
localized label per type and the exact detail, then reviewer limitations with the contributing
agents in parentheses, each once), and `<!-- review-pr:positive-evidence -->` with
`## Positive evidence` / `## Позитивні докази` (capped, with contributing agents). Empty sections
are omitted. The standalone comparison does not repeat them. Historical Markdown runs are unchanged.

### Rollout

1. Design (this section), the sidecar shape, and fixtures: unavailable file reported by two agents,
   denied tool, failed check, unavailable review threads, unverified production-data assumption,
   one agent timed out while peers completed, duplicated positive evidence, EN and UA rendering,
   foreign-language model text not affecting markers.
2. Orchestrator collector (typed records from the states above), reviewer aggregation, positive
   evidence aggregation, sidecar and manifest entry.
3. Prompt rule and `KNOWN LIMITATIONS` block; the `diagnostic_only_finding` post-check.
4. Renderer sections and end-to-end tests; no configuration flag, because the change adds
   orchestrator output and rendering without altering any model contract.

Status (2026-09-12): steps 2 to 4 are implemented and covered by unit and end-to-end tests
(failed check, unavailable review threads, a retried agent attempt, one limitation shared by three
primaries, shared positive evidence, EN and UA rendering, and the `diagnostic_only_finding`
rejection). The `diagnostic_only_finding` check is deliberately two-factor: an evidence item counts
as diagnostic only when it names a check, pipeline, workflow, job, build, tool, or permission and a
failed, pending, skipped, denied, or unavailable state, and no item names a path, line, or symbol;
`UNCERTAIN` claims may still cite a check failure as their reason.

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
- A schema, provenance, or completeness failure records a stable reason token followed by
  machine-readable details, for example
  `schema_provenance_or_completeness_validation_failed: finding[xr-3].failure_scenario` or
  `source_refs.missing[pi:pi-2]`. Details name the record by `source_id`, the failing field or
  stream-level check, and missing or unknown source refs, so a failed attempt can be diagnosed from
  its log without re-running the validator.
- A truncated stream without `complete` is a failed report even if earlier records parse. Preserve
  those records as diagnostics; never publish them as a successful review. They may still seed one
  continuation pass, described below, which republishes them only as part of a merged stream that
  passes the full contract.
- Before an ordinary whole-review retry, allow one bounded repair attempt only when every finding is
  already a parseable object with a unique `source_id` and every substantive field present. Leading
  or trailing transport prose, fences, record/schema metadata, and a missing or malformed terminal
  completion record are repairable. A finding that lacks only `existing_feedback` is repairable
  too: the baseline records `{"state":"unknown","thread_ids":[]}`, which states honestly that the
  model did not report thread coverage. Broken JSON-looking records, unknown record types,
  duplicate completion records, and other missing substantive finding fields are ineligible because
  recovery would require guessing.
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
- A stream that stopped before answering every required source ref is continued rather than
  repaired, because a bounded repair runs without tools and may not add findings, while the absent
  records need their own repository evidence. The continuation is gated on the failure diagnostic
  naming nothing but `stream.no_complete` and `source_refs.missing[...]`: any per-record problem,
  unknown ref, duplicate `source_id`, or extra completion record keeps the bounded repair. A stream
  that answered every ref and only omitted `complete` also stays with the repair, which can supply
  that record without inventing content.
- The continuation is a real review pass with repository access. It repeats the original phase
  prompt and adds only bookkeeping: the ids of the records already produced, and a
  `PENDING SOURCE REFS` block that replaces `REQUIRED SOURCE REFS` for that pass. The produced
  records themselves are withheld, so the continuation has nothing to revise. Its terminal
  `complete` counts the kept and the new findings together and describes the whole review.
- A continuation may only append. The orchestrator drops the interrupted pass's own `complete`
  record, concatenates the kept records with the continuation reply, and validates the merged
  stream as one ordinary cross-review. It then compares the leading findings against the kept
  records field by field, in order. A continuation that rewrites, reorders, or drops a kept
  finding, repeats a kept `source_id`, or answers an unlisted ref is rejected, and the run falls
  back to the ordinary whole-review retry. At most one continuation runs per attempt, and it
  replaces the repair pass for that attempt rather than adding to it.
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
