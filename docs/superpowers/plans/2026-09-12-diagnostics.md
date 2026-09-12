# Diagnostics and Positive Evidence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Publish every verification limitation the orchestrator knows or the reviewers reported, plus deduplicated positive evidence, as a typed sidecar and two rendered sections of the final report, without changing any `ndjson-v1` record.

**Architecture:** A collector turns orchestrator state (thread availability, check runs, changed-line map, repository facts, failed attempts, Pi guard counters, skipped measurements, artifact-only mode) into typed records. An aggregator merges reviewer limitations and positive evidence across the run's canonical sidecars by normalized text with provenance. Both land in `*-final-diagnostics.json`, the orchestrator records also reach the final prompt as `KNOWN LIMITATIONS`, a post-check rejects findings whose only evidence is a check or tool failure, and the final renderer adds two marker-delimited sections.

**Tech Stack:** Bash 5 (`set -euo pipefail`), `jq`, library-mode test harness, mock agent runner, fake `gh`.

**Spec:** `docs/review-pr-finding-contract.md`, section "Accepted diagnostics and positive-evidence design (Milestone 6)".

## Global Constraints

- No new field on `ndjson-v1` records; the sidecar is orchestrator output.
- Always on when `reporting.finding_contract.final = "ndjson-v1"`; no flag.
- Orchestrator record types are exactly the enum in the spec; `type` + `detail` is the dedup key.
- Reviewer text merging normalizes: lower-case, collapse whitespace, strip trailing `.`/`;`/`,`.
- Positive evidence capped at 12, most contributing agents first, then normalized text.
- Every change: failing test, implementation, `bash -n bin/review-pr`, `git diff --check`, affected test file, full suite before commit, `packaging/private-data-audit.sh` clean.

---

### Task 1: Orchestrator diagnostics collector and Pi guard counters in usage JSON

**Files:** `bin/review-pr` (new `collect_orchestrator_diagnostics`, `pi_guard_usage_object`; Pi branch after `summarize_pi_guard_log`), `tests/review-pr/test_finding_contract.sh`.

**Interfaces:** `collect_orchestrator_diagnostics <output_json>` writes a JSON array of `{type, scope, phase, agent, detail, refs}` sorted by `type, detail`, reading globals `PR_REVIEW_THREADS_STATUS`, `PR_REVIEW_THREADS_REASON`, `PR_CHECK_RUNS_JSON`, `CHANGED_LINE_MAP_FILE`, `REFERENCE_ANCESTRY_STATUS`, `MANIFEST_FILE` (`.attempt_failures`, `.failures`, `.artifacts.usage`), `RERUN_FINAL`, `FINAL_PROCESSED_RESOLUTIONS_FILE`. Pi usage JSON gains `pi_guard: {executed, duplicates_blocked, budget_blocked, terminated}` when a guard log exists.

- [x] Test: set the globals to a failed check, `partial` threads, missing map, `measurement_failed` ancestry, a manifest with one `cross_review` attempt failure `"beta attempt 1/2 (timeout after 5s)"`, `RERUN_FINAL=true`, a resolutions file with one `not_allowlisted` measurement, a usage file with `pi_guard.duplicates_blocked = 3`; assert the exact set of types and that a duplicated failed check appears once.
- [x] Run → `collect_orchestrator_diagnostics: command not found`.
- [x] Implement; map attempt reasons: `timeout` → `agent_attempt_timeout`, `output token limit` → `agent_attempt_output_limit`, `invalid` → `agent_attempt_invalid_output`, else `agent_attempt_failed`. Check conclusions: `failure|timed_out|action_required|startup_failure` → `github_check_failed`, `cancelled` → `github_check_cancelled`, `skipped|neutral` → `github_check_skipped`, status not `completed` → `github_check_pending`.
- [x] Run → pass. Commit `Collect orchestrator diagnostics`.

### Task 2: Reviewer limitation and positive-evidence aggregation

**Files:** `bin/review-pr` (`aggregate_reviewer_limitations <final_canonical> <output_json>`, `aggregate_positive_evidence <final_canonical> <output_json>`), tests.

- [x] Test: two primary canonicals with the same limitation differing in case and trailing period, a cross canonical with a finding-level limitation, a final canonical with completion-level limitation; assert one merged entry with `agents` `["alpha","beta"]` and `phases` `["primary"]`, finding refs preserved; positive evidence: 14 items across agents → 12 kept, the one shared by two agents first, `kind` `verified_safe` for `src/File.php:10 …`, `no_issue_found` otherwise.
- [x] Run → command not found. Implement with jq over `PRIMARY_FINDINGS_OUTPUTS`, `CROSS_FINDINGS_OUTPUTS`, and the final canonical. Run → pass. Commit `Aggregate reviewer limitations and positive evidence`.

### Task 3: Sidecar, manifest, prompt rule, KNOWN LIMITATIONS block

**Files:** `bin/review-pr` (`write_final_diagnostics`, `FINAL_DIAGNOSTICS_OUTPUT`, `FINAL_PROCESSED_DIAGNOSTICS_FILE`, publication, both manifests, `append_known_limitations_to_prompt`, contract bullets), `tests/review-pr/test_pipeline_integration.sh` (ndjson cross case asserts), `tests/review-pr/test_finding_contract.sh`.

- [x] Tests: unit for `append_known_limitations_to_prompt` (block markers, one JSON line per record, literal `none`); integration: final prompt contains `===== BEGIN KNOWN LIMITATIONS =====`, primary/cross/final prompts contain `is a verification limitation, never a finding by itself`, sidecar `*-final-diagnostics.json` exists with keys `orchestrator`, `reviewers`, `positive_evidence`, manifest `artifacts.final_diagnostics` set.
- [x] Implement; sidecar written in `process_final_ndjson_output` after resolutions; published beside findings; rerun stem `*-diagnostics.json`.
- [x] Commit `Publish final diagnostics and known limitations`.

### Task 4: `diagnostic_only_finding` post-check

- [x] Test: canonical final with a CONFIRMED finding whose evidence is `["CI check phpunit failed", "Pipeline status: pending"]` → `describe_diagnostic_only_findings` prints `finding[F-9]`; adding evidence `src/App/Service.php:42 throws on null` clears it; `process_final_ndjson_output` reason `diagnostic_only_finding: finding[F-9]`.
- [x] Implement (pattern set: `check`, `ci `, `pipeline`, `workflow`, `status`, `failed`, `failing`, `pending`, `skipped`, `denied`, `permission`, `tool`, `unavailable`, `could not run`; path-like token regex `[A-Za-z0-9_./-]+\.[a-z]{1,5}(:[0-9]+)?|::|\(\)`).
- [x] Commit `Reject diagnostic-only findings`.

### Task 5: Renderer sections

- [x] Test: EN and UA renders with a diagnostics sidecar show `<!-- review-pr:verification-limitations -->`, `## Verification limitations` / `## Обмеження перевірки`, an orchestrator line with the localized type label and detail, a reviewer line with `(alpha, beta)`, `<!-- review-pr:positive-evidence -->` section; empty sidecar → no sections; legacy `validate_final_markdown` still passes.
- [x] Implement `render_final_findings_markdown <canonical> <output> [resolutions] [diagnostics]`.
- [x] Commit `Render verification limitations and positive evidence`.

### Task 6: End-to-end scenarios and fixtures

**Files:** `tests/review-pr/fake-gh.sh` (`REVIEW_PR_FAKE_CHECK_RUNS_JSON`), `tests/review-pr/mock-agent-runner.sh` (primary limitation text shared by all agents, positive evidence, behaviour `final-diagnostic-only`), `tests/review-pr/test_pipeline_integration.sh`.

- [x] Cases: (a) failed check + unavailable threads + `fail-once` beta primary + shared limitation → sidecar types `github_check_failed`, `github_review_threads_unavailable`, `agent_attempt_failed`; reviewers entry with two agents; rendered sections present; (b) `final-diagnostic-only` → pipeline fails with `diagnostic_only_finding`.
- [x] Docs (`docs/review-pr.md`, contract doc rollout note), CHANGELOG Unreleased. Full suite. Commit `Cover diagnostics end to end`.

### Task 7: Real-data check and bookkeeping

- [x] Run `--rerun-final` on the local model for a run with reviewer limitations; verify the sidecar and sections; record in the plan document and handoff.

**Result (2026-09-12, dirk-qwen3.8-27b@iq3_s, source run 28929/20260911-210427-CEST):** three artifact-only reruns.
150743 failed on a model error unrelated to M6 (`source_refs.unknown[claude:cross-unread-product-metadata]`, the
frozen repair refused the provenance change); its completion record already restated the `checkout_unavailable`
record from `KNOWN LIMITATIONS`. 152447 completed and exposed a real defect: the aggregator emits `finding_refs`
as `{agent, source_id}` objects, the renderer concatenated them as strings, and jq failed silently inside the
output group, so the limitations section rendered empty. Fixed in `336a272` (refs render as `agent:source_id`,
a failing section jq now fails the render, normalization strips backticks). 154630 completed with
`*-diagnostics.json` (2 orchestrator records: `checkout_unavailable`, `github_review_threads_unavailable`
`not_fetched`; 41 reviewer limitations; 12 positive evidence), the rerun manifest's top-level `final_diagnostics`,
and both rendered sections (43 and 12 lines). Follow-up: artifact-only reruns report the thread state as
`not_fetched` because the source manifest does not record it; preserving the source run's thread status would
need a manifest field.
