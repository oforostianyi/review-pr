# Changelog

All notable changes to `review-pr` are documented in this file. The project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
