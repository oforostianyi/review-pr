# Changelog

All notable changes to `review-pr` are documented in this file. The project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- GitHub Actions workflow `.github/workflows/ci.yml`: syntax check, `shellcheck`, private-data audit,
  and the full test suite on Linux (macOS for `main` and manual runs), then a package build with
  checksum and content verification uploaded as an artifact.

### Fixed

- Run manifests record the measured review-thread state as `review_threads: {status, reason}`, and a
  resumed run or an artifact-only `--rerun-final` restores it from the source manifest (or, for older
  runs, from the GitHub context snapshot) instead of reporting `github_review_threads_unavailable:
  not_fetched` in the final diagnostics.

## [1.14.0] - 2026-09-12

### Added

- Final diagnostics sidecar `work/*-final-diagnostics.json` (manifest `artifacts.final_diagnostics`),
  written whenever the final contract is `ndjson-v1`: typed `orchestrator` records of what the
  orchestrator itself measured as limiting the review (review-thread state, check-run outcomes,
  changed-line map and repository-facts availability, failed agent attempts, Pi guard outcomes,
  skipped measurements, artifact-only reruns), `reviewers` limitations merged across every canonical
  sidecar of the run by normalized text with their phases, agents, and finding refs, and capped
  `positive_evidence` with a heuristic `verified_safe`/`no_issue_found` label. No model record
  changes and no flag is needed.
- The final report renders the sidecar as two marker-delimited, localized sections,
  `Verification limitations` and `Positive evidence`; empty sections are omitted.
- The final prompt lists the orchestrator records in a `KNOWN LIMITATIONS` block, and the primary,
  cross-review, and final contracts state that a failed, pending, or skipped CI check, a denied or
  failing tool, or an unavailable file is a verification limitation, never a finding by itself.
- Final processing rejects a `CONFIRMED` finding whose only evidence is such an outcome with
  `diagnostic_only_finding: finding[<id>]`.
- Pi usage JSON carries `pi_guard` counters (`executed`, `duplicates_blocked`, `budget_blocked`,
  `terminated`) when a guard log exists.

### Fixed

- The primary and cross-review `ndjson-v1` contracts now state the basis policy for rule-based
  findings: evidence must name an explicit repository rule with its path, a configured skill rule by
  name, or an inferred convention verified against sibling files; general style preferences without
  engineering impact are not findings, and an inferred convention alone cannot carry `P0`/`P1`.
  Previously only the final contract carried this rule.

## [1.13.0] - 2026-09-12

### Added

- Opt-in `reporting.execute_measurements` (requires `dispute_resolution`). The orchestrator runs the
  argv command a resolution proposes inside the review checkout at the exact PR head: only read-only
  allow-listed tools without a shell, no absolute or parent paths, no `rg --pre`, no `git`
  configuration or directory overrides, a ten-second timeout, bounded credential-redacted excerpts.
  The result is attached to the resolution as a separate `measurement` object and the final report
  gains a `Measured` column; refused commands are recorded as skipped and never run, and
  artifact-only final reruns skip execution.
- End-to-end fixtures for a measured resolution with an explicit `AGENTS.md` rule basis, a factual
  dispute whose only measurement is a refused runtime tool (the covering finding stays `UNCERTAIN`),
  and a compound claim split by a cross-reviewer into records that land in two final findings.

## [1.12.0] - 2026-09-12

### Added

- Opt-in `reporting.dispute_resolution` for structured final synthesis. The orchestrator detects
  cross-review disagreements about the same primary finding, lists them in a `REQUIRED
  RESOLUTIONS` prompt block, and validates one `resolution` record per dispute: dispute kind,
  status, verification method, a recorded argv `command`, the observed result, and the basis
  (explicit repository rule, skill rule, inferred convention, or general engineering). A factual
  dispute cannot be resolved by reviewer count, an unresolved factual premise cannot back a
  `CONFIRMED` finding, and an inferred convention cannot carry `P0`/`P1`. Validated records are
  published as `*-final-resolutions.json`, recorded in the manifest, frozen during schema repair,
  and rendered as a localized `Dispute resolutions` table. Runs without the flag are unchanged.

### Fixed

- Primary, cross-review, and final `ndjson-v1` prompts now state the anchor policy explicitly: a
  finding is anchored to the changed line that causes it, an affected consumer, caller, or flow to
  the changed line that creates the exposure, and `pr-level` is the fallback only when no changed
  line causes the finding (test coverage, migration, documentation), with the file and symbol named
  in evidence. The old wording reserved `pr-level` for PR-wide omissions and made agents drop
  verified consumer and coverage findings that had no changed line to anchor to.
- The primary contract now maps the review skill's report sections onto record fields: findings,
  undisclosed behaviour changes, and affected consumers or flows become records; plausible but not
  fully verified findings stay records with the gap in `verification_limitations` instead of being
  dropped; verified-safe consumers and flows become `positive_evidence`; refuted candidates are not
  emitted. The cross-review contract records "new or pre-existing" and the reachable caller in
  evidence.
- The test suite's terminated-run fixture no longer races the temporary-directory cleanup: the hang
  mock exits on `TERM` immediately, the interrupt case waits for its agents to leave, and the
  cleanup retries. Previously a fully passing suite could end with `Directory not empty`.
- Configured Markdown-oriented `prompts.cross_review` instructions (tables, headings, "new findings"
  sections) are no longer forwarded when the cross-review contract is `ndjson-v1`, where they
  contradicted the machine contract; `--show-config` says so. `prompts.final` was already limited to
  Markdown mode.
- The Pi execution guard instruction no longer tells the model to keep inspection bounded to
  changed code, which contradicted the review skill's consumer and flow steps; it now asks for
  those steps explicitly while still forbidding repeated inspection.

## [1.11.5] - 2026-09-11

### Added

- Optional `agents.pi.max_tool_calls` enables a bundled Pi extension (`review-pr-pi-guard.js`) for
  tool-enabled Pi phases. It blocks identical repeated tool calls, blocks every call after the
  configured budget while asking for the final output, terminates the agent if tool use persists,
  and writes one summary line per attempt to the log. `0` keeps the duplicate guard without a
  budget; omitting the key leaves Pi unchanged. Configuration validation rejects the key for agents
  that cannot enforce it. Motivation: one observed local-model attempt issued 953 tool calls of
  which only 112 were distinct, repeating a ~20-command inspection cycle 42 times across 9
  compactions until the wall-clock timeout.
- `packaging/private-data-audit.sh` with an explicit allowlist. It scans Git-tracked text files for
  personal paths, company or ticket identifiers, private network addresses, and credential-like
  values; the test suite runs it and `packaging/build-package.sh` refuses to package when it fails.
  The remaining company-specific profile name in the documentation example was replaced with a
  neutral `php-project`.

### Fixed

- Cross-review and final `ndjson-v1` records classified `REJECTED` or `UNCERTAIN` may now carry a
  `null` or empty `failure_scenario`, because no failure scenario applies to a refuted or unproven
  claim. `CONFIRMED` and unclassified primary records still require a non-empty scenario. Previously
  any such record failed validation deterministically, the bounded repair pass could not fix it, and
  the whole cross-review attempt was retried and failed again.
- `ndjson-v1` validation failures now append machine-readable details to the stable reason token:
  the failing record by `source_id`, the failing field or stream-level check, and any missing or
  unknown source refs. Attempt logs and manifest failure entries carry the same detail.
- Resuming a run no longer shows preserved primary and cross-review reports as `WAITING`: their
  rows are `LOADED` with the recorded token totals, and only rerun agents progress live.
- Resuming a run no longer draws the `PRIMARY REVIEW` title twice. A plain log line printed after
  the live table started shifted the frame by one row, so every redraw left the stale title above
  the table; the resume messages now go through the dashboard-aware activity log.
- A resumed run no longer overwrites the manifest `agent_status` and `attempts` of agents whose
  artifacts were preserved with `unknown` and `0`; their recorded values are kept.
- Cross-review and final prompts now end with an explicit `REQUIRED SOURCE REFS` list, and the final
  prompt presents each cross-review record's upstream primary refs as `primary_provenance`. A local
  model had referenced primary finding IDs instead of the cross-review record IDs it had to cover,
  which the frozen-provenance repair pass cannot fix.
- A finding that lacks only `existing_feedback` is now eligible for the bounded schema repair with
  `{"state":"unknown","thread_ids":[]}`, instead of failing the whole attempt and triggering a full
  retry of an otherwise valid review.
- Refusing to resume an incompatible run now explains why, for example that the PR head moved from
  the recorded commit to the current one, instead of a bare "not a compatible full-run manifest".
- A Pi attempt that ends with a provider or CLI error (for example a connection error to a local
  model server) now logs that error message. Previously the log reported a misleading
  "Could not extract the final Markdown" and the usage summary hid the cause. Usage summaries
  gained an `error_message` field.

## [1.11.4] - 2026-09-11

### Added

- Optional per-agent `timeout_seconds` wall-clock limits for every phase and repair attempt, with
  status `124`, preserved partial diagnostics, and the existing failed-only retry behavior.
- A system-priority Pi execution guard that stops repeated tool inspection after context compaction
  and requests the best complete contract-compliant result from evidence already collected.

### Fixed

- Tool-using local models can no longer keep an orchestrated attempt alive indefinitely when they
  enter a repeated inspection/compaction loop.

## [1.11.3] - 2026-09-11

### Fixed

- Final anchor parity now compares language-independent anchor markers with actual detailed
  `[P0]`–`[P3]` finding blocks instead of classification-table rows. The classification table is an
  audit ledger and may legitimately retain positive evidence, supporting subclaims, or confirmed
  duplicates merged into another recommendation without causing a false validation failure.

## [1.11.2] - 2026-09-11

### Added

- Authoritative per-run repository facts covering exact base/head/default-branch topology, changed
  files, stacked-PR state, and resolvable PR/commit references from the description.
- Exact RIGHT-side changed-line maps plus final finding-anchor validation and a bounded,
  content-stable anchor-repair pass.
- Paginated GitHub review-thread state with resolved, unresolved, outdated, partial, and unavailable
  semantics for existing-feedback detection.
- Opt-in `reporting.finding_contract.primary = "ndjson-v1"` atomic primary findings, including the
  portable JSON Schema, strict completeness/anchor/provenance validation, exact raw responses,
  canonical findings sidecars, deterministic EN/UA Markdown rendering, manifest-backed resume, and
  mock fixtures.
- One bounded primary `ndjson-v1` schema-repair pass for structurally recoverable output, with
  substantive-field stability checks, original/rejected-response diagnostics, and multi-pass usage.
- Opt-in structured cross-review with namespaced source provenance, complete input coverage,
  phase-specific severity validation, deterministic EN/UA Markdown, and manifest-backed resume.
- One bounded structured cross-review schema-repair pass that freezes classification, severity,
  source provenance, contributing agents, anchors, and substantive content.
- Opt-in structured final synthesis over canonical cross-review sidecars, with complete source-ref
  coverage, orchestrator-derived primary provenance, strict final-only rejection metadata,
  deterministic localized Markdown, manifest-backed resume, and artifact-only final reruns.
- One bounded structured-final schema-repair pass that permits transport/schema correction while
  freezing decisions, severities, refs, anchors, rejection presentation, and substantive content.
- `REVIEW_PR_OUTPUT_CONTRACT` for custom runners and configured commands.
- `review-pr contract-test` for sequential, real-agent conformance checks of the primary,
  cross-review, and final `ndjson-v1` contracts without GitHub or a review checkout. It preserves
  prompts, raw responses, diagnostics, usage, canonical findings, rendered Markdown, and a machine
  summary, including on validation failure.

### Fixed

- Built-in Codex contract tests now pass `--skip-git-repo-check`, because the isolated fixture
  directory intentionally is not a Git checkout. Ordinary PR review execution remains unchanged.

### Changed

- Final report headings, metadata/classification tables, confirmed finding blocks, important
  rejected clarifications, and anchor markers are now rendered by the orchestrator in structured
  mode instead of being parsed from localized model Markdown.
- Extracted the utility into a standalone, repository-neutral source layout with root installation,
  release, and documentation files.
- The distributed example now uses neutral repository/profile placeholders and no preconfigured
  review skill. Company-specific skills are distributed separately from the public core.
- The package installs and uninstalls the finding-contract schema and design reference alongside
  the existing configuration and documentation.
- Pi's final control instruction now follows the selected primary output contract instead of always
  requesting Markdown.

## [1.11.1] - 2026-09-08

### Fixed

- Pi now receives review-pr's leading phase/output contract through `--append-system-prompt` as well
  as the ordinary user payload. Pi's `@file` attachment loader can truncate the beginning of large
  prompt files; that previously removed standalone-comparison instructions and made the model repeat
  the supplied final review instead of producing the comparison report.
- Standalone comparison failures now distinguish a final-review-shaped response from malformed or
  missing comparison markers/tables.

## [1.11.0] - 2026-09-08

### Added

- Standalone comparison reports now carry stable, invisible
  `<!-- review-pr:comparison:* -->` section markers. Validation uses those identifiers and Markdown
  table column counts instead of translated visible headings or localized column labels.

### Compatibility

- Pre-1.11 comparison output without machine markers remains accepted through the legacy localized
  validator, including the apostrophe normalization added in 1.10.1.

## [1.10.1] - 2026-09-08

### Fixed

- Standalone Ukrainian comparison reports now normalize the common ASCII (`'`) and modifier-letter
  (`ʼ`) apostrophes in the required review-comparison heading to the canonical typographic form
  (`’`) before strict validation. A model's equivalent apostrophe choice no longer discards an
  otherwise complete report.

## [1.10.0] - 2026-09-08

### Added

- Added stage-specific comparison modes under `reporting.comparison_sections`: cross-review supports
  `none` and `inline`, while final synthesis supports `none`, `inline`, and `standalone`.
- The new distributed default writes the extended source/attribution/depth comparison as a separate
  top-level `*-comparison.md` report after the core final review, with its own usage artifact,
  dashboard stage, manifest status, failure reporting, and resume support.
- Normalized usage JSON now records provider stop reasons, output-limit status, and reasoning-token
  telemetry when exposed by the CLI.

### Fixed

- Pi final output is now extracted from the authoritative assistant `message_end` event, including
  multi-block Markdown, rather than the last streamed text fragment.
- Pi `stopReason: length` failures now identify the exact output-token count and preserve the raw
  JSONL event stream, normalized usage, and extractable truncated Markdown for diagnosis.
- Final-synthesis instructions now explicitly require compact, non-repetitive output so models do
  not consume their full generation budget unnecessarily.

### Compatibility

- Deprecated `reporting.include_comparison_sections` remains accepted and maps to the original
  all-inline or all-disabled behavior when the new object is absent.

## [1.9.1] - 2026-09-08

### Fixed

- Manifest-backed `--rerun-final` now discovers historical runs from review artifacts without
  reading GitHub, fetching refs, switching branches, or requiring the current PR head to match.
- Final reruns now restore PR metadata and original diff IDs from the source manifest, pass only
  preserved cross-reviews to the synthesizer, and record `input_mode: artifact_only_cross_reviews`.
- Built-in and generic finalizers run from the report directory in artifact-only mode. The bundled
  Antigravity runner also skips disposable Git worktree creation for these reruns.

## [1.9.0] - 2026-09-07

### Added

- Added `reporting.include_comparison_sections` (default `true`) to enable or suppress the
  extended comparison block in cross-review and final-synthesis reports.
- The resolved reporting flag is displayed by `--show-config` and stored in full-run and
  final-rerun manifests.

## [1.8.1] - 2026-09-07

### Fixed

- Sources, reviewer-attribution, and review-depth sections now use exact localized table schemas
  instead of loose prose guidance.
- Reviewer-attribution tables now receive one generated column per supplied active agent; cross
  reports exclude the current cross-reviewer because that agent does not receive its own primary
  report.
- Added the missing Review-depth comparison table to cross and final synthesis.
- Final normalization now distinguishes the six-column classification table from a six-column
  reviewer matrix, which can occur when four review agents are active.

## [1.8.0] - 2026-09-07

### Added

- Every primary and cross-review Markdown artifact now receives a canonical PR metadata header
  with review stage, agent label/key, configured or reported model, and reasoning effort. Final
  reports intentionally keep only PR metadata.
- Cross-review and final-synthesis prompts now request Sources, reviewer attribution matrices,
  Agreements, Disagreements, and Agreed actions after the stable classification table.

## [1.7.4] - 2026-09-07

### Fixed

- Portable checklist references are now explicitly identified as embedded prompt content. Agents
  must apply those blocks directly instead of searching the checked-out repository or another
  agent's skill directory for `checklists/*.md`.

## [1.7.3] - 2026-09-04

### Fixed

- Final-synthesis normalization now identifies the first six-column Markdown classification
  table structurally and regenerates its canonical localized heading and header. A harmless
  model typo or alternative translation in a table label no longer discards an otherwise valid
  final review.

## [1.7.2] - 2026-09-04

### Fixed

- Portable skills can now include a `checklists/` directory: the orchestrator appends its readable
  Markdown checklists to every applicable agent prompt, so Phase 10 rules are available rather
  than merely referenced.

## [1.7.1] - 2026-09-02

### Fixed

- Documented that AGY's Claude Sonnet 4.6 model rejects `--effort`; use the model's built-in Thinking variant with an empty `agents.agy.effort` value. Added direct troubleshooting guidance for this otherwise opaque CLI failure.

## [1.7.0] - 2026-09-01

### Added

- A portable `agy/php-code-review` skill based on the Codex PHP review methodology, including Antigravity-specific disposable-worktree constraints.

### Changed

- The package installer now creates a timestamped backup of an existing `config.json` before an upgrade and preserves locally customized portable skill files.
- The portable package now includes a disposable-worktree runner for Google Antigravity CLI (`agy`) and documents current model references for Claude, Codex, and Antigravity.
- The Antigravity runner now supplies its actual disposable worktree path to the model, prevents file-writing shell constructs, rejects whitespace-only responses, and preserves useful streaming diagnostics.
- New compatible agent CLIs can now be added through a declarative `agents.<name>.command` argument array, without creating or installing a runner script. Each generic command receives a disposable worktree; custom runners remain available for non-standard protocols and structured usage telemetry.
- `--run <timestamp>` now resumes an incomplete manifest-backed pipeline, rerunning only missing or failed reports before continuing to later phases. `--rerun-final --run` retains its final-only meaning.
- Final synthesis now enforces the configured EN/UA reader-facing language more strictly and normalizes the known bilingual `## Підсумок (Final synthesis)` artifact to `## Summary` for English output.

## [1.6.0] - 2026-08-31

### Added

- A single global `language` setting with optional `languages.primary`, `languages.cross_review`, and `languages.final` overrides.
- Portable agent-specific PHP review skill copies installed into the utility configuration directory and supplied to matching named-agent prompts when present.

### Changed

- The distributed default pipeline now uses only Claude and Codex; Pi is entirely absent until a user adds it.
- `finalization.language` is now a backward-compatible legacy fallback for the global language.

## [1.5.0] - 2026-08-31

### Added

- Per-agent `enabled` flags, allowing a reviewer to remain configured while being excluded from primary and cross-review.
- `languages.primary` and `languages.cross_review` for independent and cross-review output, in addition to final-synthesis language.

### Changed

- Skills are now optional names rather than required filesystem paths. Empty skill values explicitly disable inherited profile skills.
- Removed the hardcoded Pi PHP skill path and stopped passing `--skill` to Pi; every agent discovers any named skill in its own installation.

## [1.4.0] - 2026-08-28

### Added

- Multi-repository configuration with a default repository, short aliases, configured GitHub slugs, and GitHub PR URL input.
- Optional reusable profiles and repository-level agent-skill mappings. Repository skills override profile skills.
- Per-GitHub-repository artifact roots, preventing equal PR numbers from different repositories from sharing a report directory.

### Changed

- The portable installer initializes and updates the default repository in the multi-repository configuration, deriving its GitHub slug from the supplied checkout when possible.

## [1.3.0] - 2026-08-27

### Added

- Configurable external `reviews_directory`, defaulting to `$HOME/review-pr`, so generated review artifacts stay outside the dedicated Git checkout.
- `reasoning_effort` in every normalized usage summary when the agent has a configured effort.

### Changed

- The portable installer accepts `--reviews-dir` and initializes that configuration value on first installation.

## [1.2.0] - 2026-08-27

### Added

- Normalized per-agent usage summaries in `work/*-usage.json` for every successful primary, cross-review, and final-synthesis run, with manifest references.

## [1.1.0] - 2026-08-27

### Added

- `finalization.language` with `EN` (the distributed default) and `UA` options; the final synthesizer now receives a matching non-overridable language and localized output format.
- Clean per-review `work/` directories for intermediate reviews, GitHub context, manifests, diagnostics, and invalid-output artifacts.

### Changed

- Orchestrated prompts explicitly override manual reviewer-skill persistence rules: agents receive no output path and must return Markdown for the orchestrator to persist.
- Final-only reruns discover both the new `work/` artifacts and top-level artifacts from historical runs.

## [1.0.0] - 2026-08-27

### Added

- Stable `3 → 3 → 1` multi-agent PHP PR review workflow with independent reviews, cross-review, and source-grounded final synthesis.
- Configurable built-in and custom agents, model and reasoning-effort settings, sequential or parallel execution, failed-agent retries, and final-only reruns.
- Deterministic report layout, atomic artifacts, manifests, live terminal dashboard, native token usage display, and canonical final PR metadata headers.
- GitHub PR context snapshots containing the description, comments and replies, submitted reviews, and exact-head check results.
- Portable Linux/macOS distribution in `packaging/review-pr/`.
- `review-pr --version` and a `review_pr_version` field in every new run manifest.

### Changed

- The classification-table column is Ukrainian (`Серйозність`) and confirmed findings use only `P0`–`P3`.
