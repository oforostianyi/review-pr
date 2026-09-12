# review-pr configuration

For installation, prerequisites, agent CLI setup, and upgrades, see the repository
[`README.md`](../README.md).

## Development test suite

From the source repository, run the complete deterministic suite with:

```bash
./tests/review-pr/run.sh
```

The suite creates disposable repositories and output directories under the system temporary
directory. It uses a fake GitHub CLI and mock agent runners, so it does not contact GitHub, run a
real PR review, consume model quota, or read/update the user's `config.json`. Covered paths include
parallel and sequential phases, retry, resume, artifact-only final reruns, process termination,
atomic artifact publication, configuration backup, usage summaries, and comparison-schema
regressions. The integration suite also verifies authoritative repository facts, stacked-PR
detection, exact filenames with shell metacharacters, unresolved references, and failure before an
agent starts. Changed-line fixtures cover renamed, added, deleted, deletion-only, binary, context,
range, and newline-containing paths, plus bounded anchor repair. The install lifecycle suite stages
the package into an empty HOME with a prefix containing a space, performs a clean install, runs
`--version` and `--show-config` through the installed launcher, reinstalls twice to check
idempotency and same-second backup naming, and uninstalls with and without `--purge-config` while
verifying that backups, portable skills, published reviews, and the review checkout are never touched.
The package suite builds the release archive into a temporary directory (`REVIEW_PR_DIST_DIR`
overrides the default `dist/`), verifies the checksum with `sha256sum` or `shasum`, compares the
archive against `packaging/package-manifest.txt` in both directions, checks file modes and the
absence of symlinks or development files, and installs from the extracted archive.

To run the static syntax check separately:

```bash
bash -n bin/review-pr tests/review-pr/*.sh tests/review-pr/lib/*.sh
```

Run `shellcheck` over the same shell sources when it is installed.

The same checks run in GitHub Actions (`.github/workflows/ci.yml`) on every push and pull request:
syntax check, `shellcheck -S warning`, the private-data audit, and the full suite on `ubuntu-latest`,
plus a second Linux leg pinned to jq 1.6 (the documented minimum), followed by a package build
whose checksum and contents are verified and uploaded as a workflow artifact. `macos-latest` (Homebrew Bash 5, jq, shellcheck) joins the matrix for pushes to `main`
and manual runs, because macOS minutes are billed at a multiple of Linux minutes on private
repositories. Superseded runs of the same branch are cancelled. No agent CLI or credential is
required: the suite uses the fake GitHub CLI and mock runners.

The default configuration is `${XDG_CONFIG_HOME:-$HOME/.config}/review-pr/config.json`. It maps a GitHub repository alias to its own dedicated checkout. A bare PR number uses `default_repository`:

```json
{
  "agents": {
    "claude": {"enabled": true},
    "codex": {"enabled": true}
  },
  "reviewers": ["claude", "codex"],
  "synthesizer": "codex",
  "default_repository": "repository",
  "repositories": {
    "repository": {
      "github": "owner/repository",
      "checkout": "/absolute/path/to/dedicated/review-checkout",
      "profile": "default"
    }
  },
  "profiles": {
    "default": {
      "skills": {}
    }
  },
  "reviews_directory": "/absolute/path/to/review-pr-output"
}
```

`reviews_directory` is intentionally separate from every configured checkout: reports are user-generated artifacts and should not be accidentally picked up by `git add .`. When omitted, it defaults to `$HOME/review-pr`; it must be outside the selected review checkout. `REVIEW_PR_OUTPUT_DIR` temporarily overrides the artifact root, while `REVIEW_PR_REPO` overrides the selected checkout for an invocation. Use another configuration file with:

```bash
review-pr --config /path/to/config.json 123
```

## Repository targets, aliases, and profiles

The following forms identify the same configured PR. Matching aliases and GitHub slugs is case-insensitive; only configured repositories are accepted.

```bash
review-pr 123                                        # default_repository
review-pr repository#123                             # repository alias
review-pr owner/repository#123                       # configured GitHub slug
review-pr owner/repository/pull/123                  # GitHub path without scheme
review-pr https://github.com/owner/repository/pull/123
```

Add repositories later without creating another utility. Each entry needs a separate dedicated checkout because the command locks and detaches that checkout while reviewing:

```json
{
  "repositories": {
    "backend": {
      "github": "example/backend",
      "checkout": "/Users/example/Work/backend-review",
      "profile": "php"
    },
    "service": {
      "github": "example/service",
      "checkout": "/Users/example/Work/service-review",
      "skills": {
        "codex": "php-code-review"
      }
    }
  }
}
```

`profiles.<name>.skills` is an optional reusable agent-to-skill-name map. `repositories.<alias>.skills` is optional and overrides the profile entry for that repository. A value such as `"php-code-review"` is a name, not a required filesystem path. Use `""` to explicitly disable a skill inherited from a profile. Pi is never given a hardcoded or configured `--skill` path.

The installer puts portable skill copies under `<config-dir>/skills/<agent>/<skill-name>/SKILL.md`. When that file exists and the matching skill name is configured, its content is appended to the agent prompt as review methodology; it is not executed and it cannot override orchestrated-mode safety or persistence rules. This lets a team share reviewed methodology without requiring each agent to have separately installed skills. If the file is absent, the agent simply tries to discover the named skill in its own installation; the review still starts either way.

On a repeat installation, the installer preserves `config.json` and writes a timestamped pre-upgrade copy to `<config-dir>/backups/config-YYYYMMDD-HHMMSS.json` before applying any explicit `--repo` or `--reviews-dir` migration. It never prunes these backups. Existing portable `SKILL.md` files are preserved as well; only missing bundled copies are added.

Existing single-repository configuration using `review_repository` remains supported as a backward-compatible legacy format, but cannot resolve aliases, slugs, or URLs until migrated to `repositories`.

Inspect the resolved configuration without starting a review:

```bash
review-pr --show-config
```

## Versioning and release notes

`review-pr` follows Semantic Versioning. Print the installed version without reading configuration or touching a repository:

```bash
review-pr --version
```

Each new full-run and final-rerun manifest records the exact `review_pr_version` used to create it. Release notes are maintained in the root `CHANGELOG.md` and are included in the portable release archive.


Before tagging a release, run the release-candidate dry run from the source repository:

```bash
packaging/release-dry-run.sh --agent claude --agent codex
```

It builds the archive into a throwaway directory, verifies the checksum and
`packaging/package-manifest.txt`, extracts and installs the archive into an isolated HOME, runs
`--version` and `--show-config` through the installed launcher, runs `review-pr contract-test` for the
named agents with the user's configuration (omit `--agent` to skip it, for example in CI), uninstalls
with and without `--purge-config`, and writes a machine-readable checklist to
`dist/release-dry-run-<version>.json` (`--output` overrides the path). Step details never contain
the throwaway or home directory, so the checklist can be attached to release notes. The exit status
is non-zero when any step fails.
## Execution concurrency and retry

Primary reviews and cross-reviews run concurrently by default. Limit the number of reviewer processes that may run at once with:

```json
{
  "execution": {
    "max_concurrency": 1,
    "retry": {
      "max_attempts": 2,
      "delay_seconds": 5
    }
  }
}
```

`1` makes both reviewer phases sequential in the order listed in `reviewers`; `2` allows at most two reviewer processes at once. The final synthesis is always a single process. Omit `execution.max_concurrency` to retain unlimited concurrency within each phase.

`retry.max_attempts` includes the initial attempt, so `2` means one initial run plus one retry. The default is `1`, which disables retry. After every round finishes, only failed or empty-output agents enter the next round; completed agents keep their published artifacts and are never launched again. `retry.delay_seconds` delays the failed-only round while the dashboard continues updating. This applies independently to primary and cross-review; final synthesis still uses the dedicated `--rerun-final` workflow.

Every attempt starts with a truncated temporary output and log. A report becomes the canonical Markdown artifact only after a successful non-empty result. Failed-attempt diagnostics use distinct `*-attempt-N.log` filenames. The full-run manifest records per-agent attempt counts, final agent statuses, and all failed attempts. If an agent exhausts its attempts, the current phase fails only after all other active or queued agents have settled; subsequent phases are not started.

Each agent may also have an independent wall-clock limit:

```json
{
  "agents": {
    "pi": {
      "timeout_seconds": 2700
    }
  }
}
```

The default value is `0`, meaning no timeout. A positive value applies to each individual primary,
cross-review, final, comparison, or bounded-repair attempt run by that agent. When the limit is
reached, the orchestrator sends `TERM`, allows a short shutdown grace period, then uses `KILL` if
needed. The attempt fails with status `124`; its partial output, usage data, and diagnostics follow
the normal failure-preservation and failed-only retry flow. Completed peer reports are retained.
This is particularly useful for tool-using local models: Pi has no native maximum-turn option, so a
model that repeats repository inspection after context compaction otherwise has no hard wall-clock
bound. Choose a value above the agent's observed healthy runtime rather than treating the timeout as
a progress estimate.

Pi can additionally run under an enforceable tool-call guard:

```json
{
  "agents": {
    "pi": {
      "timeout_seconds": 2700,
      "max_tool_calls": 400
    }
  }
}
```

When `max_tool_calls` is present, tool-enabled Pi phases load the bundled extension
`review-pr-pi-guard.js` (installed beside the implementation under `libexec/review-pr`, or under
`runners/` in a source checkout). The extension blocks any tool call whose tool and arguments are
identical to one already executed in that attempt and tells the model that the result is already in
its context. After the configured number of executed calls it blocks every further call and asks
for the final output; if the model keeps calling tools regardless, the guard terminates the agent
after a short allowance so the attempt fails within minutes rather than at the wall-clock timeout.
`0` keeps the duplicate guard without a budget. Omitting the key runs Pi without the extension. The
attempt log receives one summary line, for example
`Pi tool guard: 118 tool calls executed, 41 duplicate calls blocked, budget of 400 not reached, not terminated.`
Only `pi` accepts this key; other agents cannot enforce it and configuration validation rejects it
for them. The guard does not apply to bounded repair, comparison, or contract-test runs because those
already run with tools disabled.

## Built-in agents, models, and reasoning effort

`claude`, `codex`, and `pi` have built-in runners. An empty or omitted `model` uses that CLI's current default. In particular, Pi receives neither `--model` nor `--provider` unless a model is explicitly configured. A Pi model may include its provider prefix, such as `<provider>/<model>`. Other agents can use a declarative `command` configuration without a custom script, or a `runner` for non-standard CLI protocols.

For Pi review phases, the orchestration control prompt also prohibits repeating identical tool
calls or restarting the same inspection after context compaction. It tells the model to stop tool
use and emit the best contract-compliant result once work begins to repeat. That instruction alone
is not reliable for a local model that loops after compaction; `max_tool_calls` enforces the same
rule mechanically, and the configured timeout remains the final wall-clock boundary.

`agents.<agent>.effort` applies to that agent's primary and cross-review runs:

- Claude receives `--effort`. Supported configuration values are `low`, `medium`, `high`, `xhigh`, and `max`; its default is determined by Claude Code when the field is empty or omitted.
- Codex receives `-c model_reasoning_effort="…"`. Supported configuration values are `none`, `low`, `medium`, `high`, `xhigh`, and `max`; model availability determines which values the selected model accepts.
- Pi receives `--thinking`. Supported configuration values are `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, and `max`; an empty value keeps the current default of the configured provider/model. A bounded level matters for reasoning models behind a local server: a finalizer that spends most of its output budget thinking can hit the output token limit before it prints the contract.

The exact model still decides whether an effort is available. For example, Claude Haiku 4.5 rejects effort, and older Claude models may support only a subset. Leave the field empty for the CLI default, or set `finalization.effort` to `""` to explicitly disable inherited agent effort for final synthesis.

JSON does not support comments. The JSON Schema descriptions and this section are the authoritative list of options; the example config keeps the fields visible as empty strings.

Keep an agent's configuration while temporarily excluding it from primary and cross-review with `enabled: false`. It can remain in `reviewers`; the command filters disabled reviewers before checking the minimum of two active agents. The configured synthesizer must be enabled.

```json
{
  "reviewers": ["claude", "codex"],
  "synthesizer": "codex",
  "agents": {
    "claude": {"enabled": true, "model": "claude-opus-5", "effort": "xhigh"},
    "codex": {"model": "gpt-5.6-sol", "effort": "max"},
    "pi": {"enabled": false, "model": "local-model-kept-for-later"}
  }
}
```

The synthesizer does not have to be a reviewer. It must be a built-in agent or define either a generic `command` or custom `runner`.

### Google Antigravity (`agy`) custom runner

The portable package includes `<prefix>/libexec/review-pr/review-pr-agy`. Configure `agy` as a custom agent using that absolute path. The runner sends the prompt through Antigravity's documented streaming JSON mode and creates a disposable worktree at the exact checked-out PR head; it removes that worktree after the response, so the dedicated review checkout is never used as Antigravity's writable workspace. It appends the actual worktree path to the prompt, because `Repository:` is logical PR metadata and may name the runner's source checkout.

```json
{
  "agents": {
    "agy": {
      "label": "Antigravity",
      "model": "gemini-3.1-pro-high",
      "runner": "/home/example/.local/libexec/review-pr/review-pr-agy"
    }
  },
  "profiles": {
    "php-project": {
      "skills": {"agy": "php-code-review"}
    }
  },
  "reviewers": ["claude", "codex", "pi", "agy"]
}
```

Antigravity documents `low`, `medium`, and `high` effort values, but a model can reject the `--effort` flag even though the CLI accepts it. Leave `agents.agy.effort` empty when the selected model slug already includes its effort. In the current AGY model list, `claude-sonnet-4-6` is labelled `Claude Sonnet 4.6 (Thinking)` and rejects `--effort`; configure it as `"model": "claude-sonnet-4-6", "effort": ""`. Run `agy models` to see the account's current available model slugs; availability and effort support are provider- and account-specific. The bundled runner normalizes Antigravity's JSON `usage` result into the same `work/*-usage.json` format and dashboard token total used by built-in agents. Review methodology is not bundled with the public core; configure an optional native or team-provided skill name when needed.

### AGY headless sandbox permissions

AGY's terminal sandbox is a preview feature. In headless mode it cannot display an approval card: an action not covered by an allow rule is denied and AGY may return an empty final response. Configure permissions through AGY's `/permissions` UI at **Project** scope for the review-pr project; do not depend on a manually copied path to a disposable worktree, because the runner creates a new worktree for every invocation.

The runner starts AGY with `--sandbox`, supplies the actual worktree path in the prompt, and asks the model to use only that workspace. The worktree protects the dedicated review checkout from accidental edits, but it is not a replacement for AGY permissions: AGY can still attempt terminal commands or its own file tools. Use a narrow read-only allowlist. A reasonable baseline is:

```text
command(git diff)       unsandboxed(git diff)
command(git show)       unsandboxed(git show)
command(git log)        unsandboxed(git log)
command(git status)     unsandboxed(git status)
command(git grep)       unsandboxed(git grep)
command(rg)             unsandboxed(rg)
command(grep)           unsandboxed(grep)
command(sed)            unsandboxed(sed)
command(find)           unsandboxed(find)
command(ls)             unsandboxed(ls)
```

`unsandboxed(...)` is needed only as a controlled fallback when AGY's terminal sandbox cannot execute a command. Keep it limited to the same read-only commands. Do **not** allow `unsandboxed(*)`, `command(*)`, `write_file(*)`, shell redirection, package installation, `sudo`, or destructive Git operations. In particular, never put `--dangerously-skip-permissions` into the runner or `agents.agy` configuration.

The runner already instructs AGY to make one read-only command per tool call — no `>`, `>>`, `&&`, `||`, `;`, pipes, command substitution, `/tmp`, or `scratch/` files. Command permissions use token-prefix matching, so compound shell expressions are both unnecessary and likely to be denied in headless mode.

Troubleshooting:

- `headless mode cannot prompt` / `permission check failed`: add the exact missing **read-only** command or read-file scope through `/permissions`; do not use a global wildcard as a workaround.
- `read_file` denied for the logical `Repository:` path: verify that the AGY runner is current. It appends the disposable runtime workspace path to the prompt; the logical repository path must not be used for file tools.
- `connecting to sandbox server ... connection reset by peer`: this is a terminal-sandbox failure, not evidence that the command should receive a broader permission. Retry after confirming the narrow allowlist and retain the orchestrator error log for diagnosis.
- `Antigravity returned an empty final response`: the runner preserves stream-event diagnostics in the matching `work/*-error-*.log`. Resolve the earliest denied tool call, then resume the same run with `review-pr <repository>#<pr> --run <timestamp>`.
- `Antigravity CLI failed` immediately after worktree preparation: inspect the CLI log under `~/.gemini/antigravity-cli/log/`. A frequent model-selection cause is `--effort is not supported for model "claude-sonnet-4-6"`; set `agents.agy.effort` to `""`, then resume the same run.

## Finalization model and reasoning effort

`agents.<agent>.model` and `agents.<agent>.effort` apply when that agent runs primary and cross-review. Override either value only for final synthesis with `finalization.model` and `finalization.effort`:

```json
{
  "synthesizer": "claude",
  "agents": {
    "claude": {
      "model": "claude-opus-5",
      "effort": "xhigh"
    }
  },
  "finalization": {
    "model": "claude-haiku-4-5",
    "effort": ""
  }
}
```

When `finalization.model` is empty or omitted, the synthesizer uses its normal agent model; if that is empty too, it uses the CLI default. Omit `finalization.effort` to inherit the synthesizer agent's effort. Include `"effort": ""` to disable an inherited effort, as in the Haiku example above, or set a supported non-empty value to override it. For Pi, an empty model continues to omit `--model` and uses its configured current default, and a non-empty effort is passed as `--thinking`.

## Review language

`language` is the global output language for primary, cross-review, and final-synthesis reports. The distributed example defaults to English:

```json
{
  "language": "EN"
}
```

Override only a stage when needed with `languages.primary`, `languages.cross_review`, or `languages.final`; omit an entry, or set it to `""`, to inherit the global value:

```json
{
  "language": "EN",
  "languages": {
    "cross_review": "UA"
  }
}
```

The legacy `finalization.language` remains readable for existing configurations, but new configurations should use `language` and optional stage overrides. The orchestrator tells every stage its resolved output language; this takes precedence over a conflicting skill or custom formatting instruction. It also localizes built-in cross-review headings and table columns. `CONFIRMED`, `REJECTED`, `UNCERTAIN`, and `P0`–`P3` deliberately remain fixed in both languages.

## Structured finding contracts (opt-in)

Markdown remains the default primary-agent output contract. To evaluate the versioned machine contract for new runs, enable it explicitly:

```json
{
  "reporting": {
    "finding_contract": {
      "primary": "ndjson-v1",
      "cross_review": "ndjson-v1",
      "final": "ndjson-v1"
    }
  }
}
```

In `ndjson-v1` mode each agent returns one complete JSON object per physical line, followed by exactly one terminal `complete` record. The orchestrator validates required fields, enums, unique source IDs, completeness, producer identity, and changed-line anchors before anything is published. It then preserves the exact response as `work/*-raw.ndjson`, writes normalized `work/*-findings.json`, and deterministically renders localized `work/*.md` for humans and the next stage.

Structured cross-review requires `primary: "ndjson-v1"` and `reporting.comparison_sections.cross_review: "none"`. It receives the other agents' canonical primary sidecars rather than localized Markdown. Every input finding must be covered by at least one cross-review record using a unique `{agent, source_id}` reference; unknown references and missing coverage fail validation. Genuine duplicates may be consolidated with multiple references, while a compound source claim may be split across independently classified records. `CONFIRMED` requires `P0`–`P3`; `REJECTED` and `UNCERTAIN` use `null` severity. The portable record schema is installed as `review-pr-findings-v1.schema.json`; the full design is documented in `review-pr-finding-contract.md`.

Structured final synthesis requires structured primary and cross-review inputs plus `comparison_sections.final: "none"` or `"standalone"`. The finalizer receives canonical cross-review JSON rather than localized Markdown. Every cross-review `{agent, source_id}` must be covered, unknown refs fail validation, and only confirmed records may carry `P0`–`P3`. The model never restates primary provenance: the orchestrator derives it through the validated cross-review graph and stores it in the canonical final sidecar. The final Markdown header, metadata table, classification table, actionable findings, rejected-findings section, localization, and anchor markers are rendered deterministically. `include_in_rejected_summary` only controls whether an important rejected decision is explained in that human section.

### Dispute resolutions (opt-in)

`reporting.dispute_resolution: true` (default `false`) requires `finding_contract.final: "ndjson-v1"` and adds machine-readable resolutions of cross-review disagreements to final synthesis:

```json
{
  "reporting": {
    "finding_contract": {"primary": "ndjson-v1", "cross_review": "ndjson-v1", "final": "ndjson-v1"},
    "comparison_sections": {"cross_review": "none", "final": "standalone"},
    "dispute_resolution": true
  }
}
```

The orchestrator detects a dispute whenever the cross-review records that reference the same primary finding disagree in classification, or all confirm it with different severities. Each dispute receives a stable id derived from the primary ref (`dispute:<agent>:<source_id>`) and is listed in a `REQUIRED RESOLUTIONS` block of the final prompt. The finalizer answers with exactly one `resolution` record per dispute in the same NDJSON stream: the dispute kind (`factual`, `severity`, `mixed`), the status (`resolved`, `uncertain`, `not_applicable`), the verification method (`source`, `command`, `test`, `repository_rule`, `runtime`, `manual`), an optional declarative `command` as an argv array that the orchestrator records but never executes, what was observed, and whether the basis is an explicit repository rule (with its path), a configured skill rule, an inferred convention, or general engineering judgement.

Validation enforces the principle that reviewer count never settles a fact: a factual or mixed dispute is `resolved` only with a method other than `manual`; a finding that covers an unresolved factual dispute cannot stay `CONFIRMED`; `not_applicable` is allowed only for severity-only disputes; and a finding whose only basis is an inferred convention cannot carry `P0` or `P1`. Failures use the granular reason format, for example `dispute_resolution_validation_failed: resolution[dispute:codex:codex.p1.notes].verification_method`, and the bounded schema repair freezes every resolution decision. Validated records are published as `work/*-final-resolutions.json` (with the detected dispute list), recorded in the manifest as `artifacts.final_resolutions`, and rendered as a localized `Dispute resolutions` table under a language-independent marker in the final report. Runs without the flag are unchanged; a resolution record they receive fails with `unexpected_resolution_records`. `--show-config` prints `Dispute resolution: enabled|disabled`.

`reporting.execute_measurements: true` (default `false`, requires `dispute_resolution: true`) makes the orchestrator run the `command` a resolution proposes when its `verification_method` is `command` or `test`. Execution is deliberately narrow: the argv array runs without a shell in the review checkout at the exact PR head; only read-only tools are allow-listed (`rg`, `grep`, `ls`, `cat`, `head`, `wc`, `test`, and `git` with `show`, `log`, `diff`, `ls-tree`, `cat-file`, `grep`, `rev-parse`, `blame`); absolute or parent-directory paths, `rg --pre`, and `git` configuration or directory overrides are refused; each command gets a ten-second portable timeout; stdout and stderr excerpts are bounded to 2000 characters and credential-like values are redacted. The result is attached to the resolution as a separate `measurement` object (`executed`, `skipped_reason`, `exit_status`, excerpts, `duration_ms`, `commit`) in `*-final-resolutions.json`, so the model's `observed` claim and the orchestrator's measurement never mix, and the final report gains a `Measured` column. Refused commands are recorded as `skipped: not_allowlisted` and never run; artifact-only `--rerun-final` skips execution with `checkout_unavailable` because it has no checkout.

There is no automatic fallback to Markdown. Invalid or truncated structured output fails closed and preserves attempt-scoped raw output and diagnostics. A structurally recoverable response first receives one dedicated field-stable repair pass. A cross-review that stopped before answering every required source ref receives a continuation pass instead: the records it already produced are kept, the same agent is asked for the unanswered refs alone, and the merged stream must pass the full contract with the kept findings unchanged. Primary repair freezes substantive finding content. Cross-review and final repair additionally cannot change classification, severity, `source_refs`, contributing agents, anchors, or any substantive content; final repair also freezes `include_in_rejected_summary`. Every repaired stream repeats complete schema, input-coverage, and anchor validation before publication. Resume uses all contracts recorded in the run manifest, so changing the current config cannot reinterpret an existing run. Manifest-backed final reruns reuse canonical cross-review sidecars. Historical manifests without these fields continue as Markdown.

### Verification limitations and positive evidence

Whenever `finding_contract.final` is `ndjson-v1`, the orchestrator also publishes
`work/*-final-diagnostics.json` (recorded in the manifest as `artifacts.final_diagnostics`; the
`--rerun-final` stem is `*-diagnostics.json`). It has three parts, none of which changes a model
record:

- `orchestrator`: typed records of what the orchestrator itself measured as limiting the review:
  review-thread state (`github_review_threads_unavailable`/`_partial`), check-run outcomes
  (`github_check_failed`/`_cancelled`/`_pending`/`_skipped` with the check name and conclusion),
  `changed_line_map_unavailable`, `repository_facts_measurement_failed`, failed agent attempts
  (`agent_attempt_timeout`/`_output_limit`/`_invalid_output`/`_failed` with the attempt text), Pi
  guard outcomes (`pi_guard_budget_exhausted`, `pi_guard_duplicates_blocked`), `measurement_skipped`
  with its reason, and `checkout_unavailable` for artifact-only reruns. `type` plus `detail` is the
  deduplication key.
- `reviewers`: model-reported `verification_limitations` from every canonical sidecar of the run,
  merged when their normalized text (lower-cased, whitespace collapsed, trailing punctuation
  removed) is equal, with the contributing `phases`, `agents`, and `finding_refs`.
- `positive_evidence`: completion-level positive evidence merged the same way, labelled
  `verified_safe` when the text names a file or symbol and `no_issue_found` otherwise (a heuristic
  label), capped at twelve entries with the most widely shared first.

The final prompt receives the orchestrator records as a `KNOWN LIMITATIONS` block (one compact JSON
line each, or `none`), and all three contracts state that a failed, pending, or skipped CI check, a
denied or failing tool, or an unavailable file is a verification limitation, never a finding by
itself. A `CONFIRMED` final finding whose every evidence item only reports such an outcome without
naming a file, line, or symbol fails with `diagnostic_only_finding: finding[<id>]`. The final report
renders two sections under language-independent markers, `<!-- review-pr:verification-limitations -->`
(`## Verification limitations` / `## Обмеження перевірки`: orchestrator records with a localized
label and the exact detail, then reviewer limitations with their agents) and
`<!-- review-pr:positive-evidence -->` (`## Positive evidence` / `## Позитивні докази`); empty
sections are omitted and the standalone comparison does not repeat them.

### Real-agent contract test

Use the conformance command before opting a new CLI or model into `ndjson-v1`:

```bash
review-pr contract-test
review-pr contract-test --agent claude --agent codex --phase primary
review-pr contract-test --agent pi --phase final --output "$HOME/review-pr-contract-pi"
```

`--phase` accepts `primary`, `cross`, `final`, or `all` (the default). Repeated `--agent` selects
configured agent keys. With no selection, the command tests all enabled reviewers and adds the
enabled synthesizer if it is not already present. A named agent may remain `enabled: false`, which
allows its command, model, permissions, and output behavior to be checked before it joins a real
pipeline. An explicit `--output` path must be absolute and must not already exist; otherwise output
is written below `<reviews_directory>/contract-tests/<timestamp>/`.

Each selected agent/phase receives a two-record fixed NDJSON fixture: one phase-specific finding and
one terminal completion record. Tests run sequentially even when ordinary review concurrency is
larger. The normal execution path invokes the configured built-in CLI, `command`, or `runner`; the
same production schema, provenance, coverage, changed-line, and rendering code then validates the
response. For the configured synthesizer's `final` phase, `finalization.model` and its configured
effort are used exactly as in a real final synthesis. Testing another agent against `final` uses
that agent's own model and effort.

The artifact directory retains `*-prompt.txt`, exact `*-raw.ndjson`, `*-stderr.log`,
`*-usage.json`, validated `*-findings.json`, deterministic `*.md`, and an aggregate `summary.json`.
Failed raw output and diagnostics remain available, but failed output never becomes a canonical
findings file. A zero exit status means every selected contract passed; any CLI or validation
failure returns non-zero. The command does not read a configured checkout, call Git, contact GitHub,
or inspect a PR. It **does invoke the selected model**, so API charges, subscription quotas, local
context limits, permissions, and inference time still apply. Contract-test artifacts may contain
provider diagnostics and should be treated according to the same retention policy as review output.

This command deliberately checks the first response and does not hide incompatibility behind the
pipeline's bounded repair/retry behavior. Passing proves wire-format compatibility with the fixed
fixture; it does not prove review quality, large-context reliability, or correctness on real code.

## Optional comparison reports

Comparison material can be controlled independently for cross-review and final synthesis:

```json
{
  "reporting": {
    "finding_contract": {
      "primary": "markdown",
      "cross_review": "markdown",
      "final": "markdown"
    },
    "comparison_sections": {
      "cross_review": "none",
      "final": "standalone"
    }
  }
}
```

`cross_review` accepts `none` or `inline`. `final` accepts `none`, `inline`, or `standalone`. The distributed default is `none` / `standalone`: cross-review outputs stay focused on classification, while a second synthesizer pass writes the extended Sources, reviewer matrix, agreements/disagreements, review-depth, conclusion, and agreed-actions material to `<review-stem>-comparison.md`. The core `<review-stem>-final.md` remains complete and actionable on its own. Splitting the output reduces the chance that a verbose local model exhausts its output-token limit before completing the required final review.

`inline` preserves the original embedded layout; `none` suppresses the extended block. The old `reporting.include_comparison_sections` boolean remains supported: `true` maps to `inline` / `inline`, and `false` maps to `none` / `none`. Explicit `comparison_sections` takes precedence. Resolved modes and standalone artifact state are recorded in full-run and final-rerun manifests and shown by `review-pr --show-config`. If standalone comparison generation fails, the valid core final report is preserved, the pipeline is marked failed at the comparison stage, and `--run <timestamp>` can resume only that missing stage.

## Terminal status interface

When a run is resumed with `--run <timestamp>`, agents whose reports were preserved from the earlier
invocation appear as `LOADED` with their recorded token totals; only the agents that actually run
again move through `QUEUED`, `RUNNING`, and `COMPLETE`. The resumed manifest keeps the attempt
counts and statuses recorded for preserved agents.

The live table reserves 79 columns when process IDs are shown (67 without them). Its 29-character `Agent` column displays the configured model ID and, when configured, reasoning effort — for example `Codex (gpt-5.6-terra high)`. A provider prefix such as `lmstudio/` is omitted only to preserve space; the actual model ID is retained. If a finalization-specific effort is configured, it is shown for the final synthesizer; otherwise its agent effort is shown.

In an interactive terminal the default `auto` mode renders one live dashboard divided into `PRIMARY REVIEW`, `CROSS-REVIEW`, and `FINAL SYNTHESIS`, plus `COMPARISON REPORT` when standalone comparison is enabled. Each row shows the configured agent label and model, lifecycle status, PID, elapsed time, and total `Tokens`. Long model identifiers are shortened only in the dashboard. Token usage appears only after a process has completed: it is extracted from the CLI's native structured output, rather than estimated from report text. `-` means the CLI/provider did not return a usage value (which is normal for a custom adapter, and possible for a local-model provider). The count includes the categories reported by that CLI, such as input, output, and cache tokens; it is not a cost estimate.

The compact dashboard cell intentionally remains a single total so the fixed 79-column layout does not wrap. Every successful agent run also writes a normalized `work/*-usage.json` file. It contains `reported_total_tokens`, `input_tokens`, `output_tokens`, `reasoning_tokens`, `cache_read_tokens`, and `cache_write_tokens` when the runner supplied them, plus `agent`, `phase`, `model`, `effort`, `reasoning_effort`, `source`, `available`, `stop_reason`, `raw_stop_reason`, `error_message`, and `output_limit_reached`. `error_message` carries the provider or CLI error text when a turn ends with `stop_reason` `error`; the orchestrator logs it instead of a generic extraction failure. `reasoning_effort` is configuration; `reasoning_tokens` is measured telemetry when exposed. `reported_total_tokens` is the native total when one is supplied; otherwise it is the sum of non-overlapping input/output/cache components. It is telemetry, not an invoice amount. A custom runner receives a summary with `available: false` unless it is extended to emit a supported structured usage response.

For Pi, the orchestrator reads the authoritative final assistant `message_end` event rather than relying on streamed `text_end` fragments. A `stopReason` of `length` is reported explicitly as an output-token-limit failure. The failed attempt preserves `*-usage.json`, raw `*-events.jsonl`, and any extractable `*-truncated.md` beside its error log. This makes the provider limit and incomplete response inspectable instead of presenting the result as a generic empty-output failure. Raw event files can contain the supplied report context and should be treated as review artifacts with the same confidentiality as the reports.

The table refreshes in place by moving the cursor up by the exact fixed frame height, so it does not depend on optional DEC cursor save/restore support and does not append heartbeat lines. A final-only rerun shows `CROSS-REVIEW INPUTS`, `FINAL SYNTHESIS`, and—when enabled—`COMPARISON REPORT`, because no primary agents run. If the terminal is narrower than the table, PID is hidden before the table falls back to logs; if it is too short for the complete dashboard, it also falls back to logs.

When stderr is redirected, the terminal is non-interactive, or `TERM=dumb`, `auto` falls back to timestamped logs. This keeps CI and saved logs free from ANSI cursor-control sequences.

```json
{
  "status": {
    "mode": "auto",
    "color": "auto",
    "refresh_interval_seconds": 1,
    "log_interval_seconds": 30,
    "show_pid": true
  }
}
```

Supported modes are `auto`, `table`, `log`, and `off`. `table` also falls back to logs when stderr is not a TTY. Dashboard colors are controlled by `color`: `auto`, `always`, or `never`; `auto` respects the standard `NO_COLOR` environment variable. Colors are never emitted into the non-TTY log fallback. `refresh_interval_seconds` accepts 1–60 seconds; `log_interval_seconds` accepts 5–3600 seconds. The old top-level `status_interval_seconds` remains a deprecated alias for the log interval.

## Cross-review and final prompts

The orchestrator keeps its core source-verification and safety rules, while output-format instructions are configurable under `prompts`. A prompt may be one string or an array of lines; arrays are joined with newlines.

```json
{
  "prompts": {
    "cross_review": [
      "Start with ## Таблиця класифікацій.",
      "Use one table row per atomic claim."
    ],
    "final": [
      "Start with ## Таблиця класифікацій and classify every atomic input claim.",
      "End with author-ready English blocking and minor PR comments."
    ]
  }
}
```

The distributed cross-review prompt starts with a language-specific classification table. Final synthesis uses a non-overridable `## Classification table` for `EN` or `## Таблиця класифікацій` for `UA`. Its severity column is `Severity` (`EN`) or `Серйозність` (`UA`); every confirmed row must use exactly `P0`, `P1`, `P2`, or `P3` (use `—` only where severity does not apply). The final table must account for every atomic cross-review claim as `CONFIRMED`, `REJECTED`, or `UNCERTAIN`, consolidate duplicates, and show concrete verification.

When the corresponding comparison mode is `inline`, that cross-review or final synthesis embeds a compact conclusion, a Sources table, a `Who found, accepted, or missed what` reviewer matrix, Agreements and Disagreements, a Review-depth comparison table, and a prioritized Agreed actions list. With final mode `standalone`, the same material is generated after the core final synthesis in its own report. The localized UA headings are `## Висновок`, `## Джерела`, `## Хто що знайшов, прийняв або пропустив`, `### Збіги`, `### Розбіжності`, `## Порівняння глибини перевірки`, and `## Узгоджені дії`.

The orchestrator gives the model exact localized table schemas. In Ukrainian they are:

```markdown
| Коротка назва | Файл | Verdict |
|---|---|---|

| Ризик / кандидат | <one column per active agent> | Підсумок |
|---|---|---|

| Репорт | Найсильніша сторона | Що упустив або переоцінив |
|---|---|---|
```

The English equivalents use `Short name / File / Verdict`, `Risk / candidate / <agent columns> / Summary`, and `Report / Strongest aspect / What it missed or overstated`. Cross-review matrices contain only the other agents whose primary reports were supplied; final matrices contain every active review agent. Agent columns are generated from the current configuration, so the table automatically expands or contracts when reviewers are enabled or disabled. A matrix cell may say that a reviewer accepted/rejected a claim only when that report explicitly discussed it; simple absence is recorded as missed. Detailed actionable sections follow only for confirmed findings. The final report ends with `## Blocking PR comments (English)` and `## Minor PR comments (English)`.

Standalone comparison sections also contain invisible HTML comments such as
`<!-- review-pr:comparison:sources -->`. These are stable orchestration identifiers: the validator
checks their presence and order, then validates table shapes by column count. It does not depend on
the visible translated headings or localized table labels. Custom prompts may change reader-facing
wording, but must preserve the orchestrator-owned markers. Reports produced before version 1.11,
which do not contain these markers, remain readable through a legacy compatibility validator.

For Pi, the leading orchestrator phase/output contract is also supplied through
`--append-system-prompt`. This is intentional: Pi treats `@prompt-file` as a file attachment and may
truncate the beginning of a large attachment before sending it to the model. Primary/cross/final
reports and GitHub context remain untrusted user payload; only review-pr's leading control block is
duplicated at system priority.

## GitHub PR context

For each Git-backed run, the orchestrator fetches and saves a timestamped `*-github-context.md` artifact in the run's `work/` directory. It contains the PR description, discussion comments, submitted reviews, inline review comments and replies, review-thread resolution/outdated state, plus check-run and commit-status results for the exact fetched PR head. REST collections and GraphQL review threads are paginated. More than 100 nested comments in one thread are reported as `partial`, because GitHub does not paginate that nested connection through the outer request.

The snapshot is supplied to primary, cross-review, and final agents. Its human-authored content is explicitly untrusted context, not instructions; reviewers must verify it against the checked-out code and exact diff. Mandatory REST-context failure stops the run before agents start. Review-thread GraphQL failure is different: the run continues with thread state explicitly marked `unavailable`, and prompts require conservative handling rather than interpreting it as zero unresolved threads. Reviewers identify an issue already covered by an unresolved thread as confirmation of existing feedback. Resolved or outdated feedback remains historical context and does not automatically suppress a new occurrence in the current diff.

## Authoritative repository facts

Before a new full run starts any agent, `review-pr` measures repository topology once and publishes
two timestamped artifacts under `work/`:

- `*-repo-facts.json` is the machine-readable source of truth;
- `*-repo-facts.md` is the same snapshot formatted for model prompts.

The snapshot records the exact PR base and head SHAs, their merge base, the repository's actual
default branch and fetched tip, whether the PR base differs from that default branch, whether the
base tip is an ancestor of the PR head, and the exact NUL-safe changed-file list from
`git diff BASE...HEAD`. It also resolves unambiguous PR and commit references found in the PR
description where GitHub and the local object database make that possible. An issue-style `#123`
reference is checked before it is called a pull request.

GitHub's `merged` field is context, not proof that a commit exists on the current default branch.
Only a successful local `git merge-base --is-ancestor <commit> <fetched-default-tip>` measurement
produces `true` or `false`; cross-repository, unavailable, or otherwise unmeasurable ancestry is
stored as `null` with a reason. For a merged referenced PR, the merge commit is measured when
GitHub provides one; otherwise its head commit is used. Failed optional reference lookups yield
`complete_with_unknowns`. Failure to establish a structural fact such as the default branch or
merge base stops the run before agents start and publishes no canonical facts pair.

The identical Markdown facts block is supplied to primary, cross-review, and final prompts.
Manifest-backed resume and artifact-only final reruns reuse the source run's declared facts files;
they do not silently re-measure historical state. Older manifests remain usable, but the finalizer
is explicitly told that default-branch, stacking, merge-base, and referenced-commit ancestry facts
are unavailable and must not be inferred from reviewer agreement.

## Changed-line maps and final finding anchors

The orchestrator also gives every primary reviewer, cross-reviewer, and final synthesizer the same migration-certainty rule. A migration that is proven by code/schema evidence to fail must be described as a definite failure with the exact cause. A data-, scale-, locking-, database-, or ordering-dependent concern must remain qualified; the report should name what is unverified and recommend a staging run with production-like data if such an environment exists. The prompt never assumes that staging exists or that the check has already happened.

Every new full run also writes `work/*-changed-lines.json` from the exact `BASE...HEAD` diff before
agents start. It is language-independent and keyed by each RIGHT-side repository path. For every
changed path it records Git status, an old path for a detected rename/copy, binary state, and compact
inclusive `right_side_ranges` containing only added or modified RIGHT-side lines. Deleted files,
deletion-only hunks, pure renames, and binary changes therefore have no fabricated line anchors.
Name/status parsing is NUL-delimited, so spaces, shell metacharacters, tabs, and newlines in Git paths
do not change file boundaries.

Detailed confirmed findings use one invisible, stable marker independent of report language:

```markdown
<!-- review-pr:anchor:changed-line -->
### [P1] Changed behavior can lose data

File: `src/Example.php`
Line: `41-47`
```

For a single line, that line must occur in the file's `right_side_ranges`. For a range, its end is
the inline anchor and must be changed; the start may be earlier context in the same file. Unchanged
code may still appear in `Evidence`, but if this PR makes an old defect newly reachable, the finding
must anchor to the changed reachability line.

A missing test, missing migration, or other genuinely PR-wide omission can avoid a fake line:

```markdown
<!-- review-pr:anchor:pr-level -->
### [P2] Missing integration coverage

File: —
Line: —
```

The final validator requires exactly one detailed marker for every `CONFIRMED` classification row
and writes `work/*-anchor-validation.json` with a result and stable reason for each finding. When a
structurally valid final draft has an invalid anchor, the original draft is preserved and the same
finalizer receives one bounded repair pass. A repair may alter only anchor marker, File, and Line
lines; all other report content must remain byte-equivalent after normalization. The repaired line
is checked against the map again, so the model cannot publish an invented line merely to make the
report pass. A failed or content-changing repair leaves diagnostics and no canonical final report.

Manifest-backed resume and final reruns reuse the recorded map. For a historical manifest created
before this feature, validation status is explicitly `unavailable` for changed-line findings rather
than falsely `complete`; the artifact-only workflow remains compatible and performs no current Git
inspection.

## Report layout

Each repository gets its own stable directory under the configured external `reviews_directory`; the GitHub slug is normalized to lowercase with `/` replaced by `-`. This prevents equal PR numbers from different repositories from colliding. Only completed final reviews are written at a run directory’s top level; all intermediate material stays in `work/`:

```text
$HOME/review-pr/owner-repository/<pr>-<normalized-head-branch>/
├── <review-id>-<timestamp>-final.md
├── <review-id>-<timestamp>-comparison.md
├── <review-id>-<source-timestamp>-final-rerun-<timestamp>.md
└── work/
    ├── <review-id>-<timestamp>-claude.md
    ├── <review-id>-<timestamp>-claude-raw.ndjson       # only with ndjson-v1
    ├── <review-id>-<timestamp>-claude-findings.json    # only with ndjson-v1
    ├── <review-id>-<timestamp>-cross-codex.md
    ├── <review-id>-<timestamp>-github-context.md
    ├── <review-id>-<timestamp>-repo-facts.json
    ├── <review-id>-<timestamp>-repo-facts.md
    ├── <review-id>-<timestamp>-changed-lines.json
    ├── <review-id>-<timestamp>-claude-usage.json
    ├── <review-id>-<timestamp>-cross-codex-usage.json
    ├── <review-id>-<timestamp>-final-usage.json
    ├── <review-id>-<timestamp>-final-raw.ndjson       # only with final ndjson-v1
    ├── <review-id>-<timestamp>-final-findings.json    # only with final ndjson-v1
    ├── <review-id>-<timestamp>-final-anchor-validation.json
    ├── <review-id>-<timestamp>-comparison-usage.json
    ├── <review-id>-<timestamp>-manifest.json
    └── diagnostics and invalid-output artifacts, if any
```

The orchestration prompt deliberately gives agents no report directory or output path. In orchestrated mode, any reviewer-skill instruction about creating, naming, or storing files is manual-mode-only; agents must return Markdown and the orchestrator persists it atomically. Existing historical runs stored directly under `<reviews_directory>/<review-id>/` or the old checkout-local `docs/reviews/` remain readable by `--rerun-final`.

Every newly completed primary and cross-review report receives a canonical orchestrator-generated PR metadata header before it is published. It contains the same linked PR title, task, base/head, diff statistics, and author as the final report, plus `Review stage`, `Agent`, `Model`, and `Reasoning effort`. If a CLI uses an unconfigured default and does not report its exact model, the header says so rather than guessing. The final report deliberately omits synthesizer/model metadata.

## Report headers

Every report begins with a PR-specific header generated by the orchestrator. Primary and cross-review reports add four provenance rows after `Author`:

```markdown
# Code Review: [PR #123](https://github.com/owner/repository/pull/123) — Add request validation

| Field | Value |
| --- | --- |
| **Task** | Add request validation |
| **Base** | `main` → `feature/request-validation` |
| **Files changed** | 4 · +82 / −14 |
| **Author** | Contributor (@contributor) |
| **Review stage** | Independent primary review |
| **Agent** | Claude (`claude`) |
| **Model** | `claude-opus-5` |
| **Reasoning effort** | `high` |
```

The values come from GitHub CLI metadata (`url`, `title`, branch names, changed-file count, additions, deletions, and author name/login) before the exact PR head is fetched. The PR number in the title is a direct GitHub link. The task key is derived from the head branch when it has the usual `ABC-123` form. GitHub does not reliably provide an author's email through this endpoint, so the header deliberately uses the public name and `@login` rather than inventing an email address.

The orchestrator generates these headers itself. Reviewer agents are instructed to return only their report body, after which the primary/cross provenance header is prepended atomically. The final model must begin directly with the configured `## Classification table` (`EN`) or `## Таблиця класифікацій` (`UA`); any title, metadata, or preamble that it emits is discarded, then the canonical header without agent/model rows is prepended. Output without a six-column classification table is preserved as a diagnostic `*-invalid.md` artifact, while the successful `*-final.md` target is not created.

## Re-running only the final synthesis

After primary and cross-review phases have completed, re-run only the final synthesis with the current configured synthesizer, model, and `prompts.final`:

```bash
review-pr --rerun-final 123
```

By default, this selects the newest manifest-backed run with completed primary and cross-review phases for that repository and PR number. It is intentionally independent of the PR's current head commit. The repeated synthesis receives only the preserved cross-review reports; it does not receive primary reports or run any reviewer again. Select an exact source run with its Warsaw timestamp:

```bash
review-pr --rerun-final --run 20260818-154838-CEST 123
```

For a legacy run created before manifests were introduced, explicitly opt into forced discovery of its existing cross-review files:

```bash
review-pr --rerun-final --force --run 20260818-154838-CEST 123
```

`--force` requires `--run`; it is never used for implicit latest-run selection. The orchestrator requires at least two non-empty, regular `cross-*.md` files with safe reviewer names. Because a legacy run has no manifest metadata from which to reconstruct the report header, this compatibility path still reads and checks out the PR's current exact head and clearly warns that the current fetched base/head diff is being used. Use it only when that legacy run is known to belong to the current PR head.

A normal manifest-backed `--rerun-final` is artifact-only. It discovers the selected manifest under `reviews_directory`, restores title, author, branches, diff statistics, and the original base/head commit IDs from that manifest, then loads exactly its recorded cross-review and repository-facts artifacts. It does not invoke `gh`, fetch Git refs, inspect the current PR head, acquire the repository Git lock, switch branches, or provide current GitHub discussion context to the synthesizer. The finalizer runs from the report directory and is explicitly instructed to use only preserved artifacts and the code evidence embedded in the cross-reviews. This permits a historical synthesis after the PR has received more commits, been closed, or become temporarily unavailable. The manifest also records the measured review-thread availability as `review_threads: {status, reason}`; the rerun (and a resumed run) restores it from the source manifest, or from the GitHub context snapshot for runs created before the field existed, so the final diagnostics report the state that was fetched rather than `not_fetched`.

Previous final reports are never overwritten; a new result is written as:

```text
<review-id>-<source-timestamp>-final-rerun-<new-timestamp>.md
```

Every new full run records a `*-manifest.json` with its branches, commits, reviewers, repository-facts pair, other artifacts, and phase statuses. Final-only reruns have a separate manifest recording `input_mode: artifact_only_cross_reviews`, the source manifest, and exact cross-review/facts inputs. Prefer manifest-backed reruns; `--force` exists only as an explicit compatibility path for older artifacts.

## Resume an interrupted run

Resume a failed full run by supplying its timestamp without `--rerun-final`:

```bash
review-pr repository#123 --run 20260901-154503-CEST
```

The command verifies the manifest and exact PR head, then resumes from the first incomplete phase. It runs only agents whose canonical report is missing, empty, or unsafe; completed reports are reused unchanged. A resumed cross-review therefore reruns only its failed reviewer and then continues to final synthesis. A complete run is refused; use `--rerun-final` to create another final report.

## Add an agent without writing code

For the common CLI contract, no adapter script is needed. Configure `agents.<name>.command` as a JSON array: the first element is the executable and the rest are literal arguments. The orchestrator invokes it directly (never through a shell), supplies the full prompt on standard input, captures Markdown from standard output, and captures diagnostics from standard error.

```json
{
  "reviewers": ["claude", "codex", "cursor"],
  "synthesizer": "codex",
  "agents": {
    "claude": {},
    "codex": {},
    "cursor": {
      "label": "Cursor",
      "model": "",
      "command": ["cursor-agent", "--print"],
      "instructions": "Use the PHP review skill configured for this CLI."
    }
  }
}
```

This is the recommended path for a new CLI that can accept a prompt via stdin and write its final Markdown answer to stdout. Each invocation runs in a disposable detached worktree at the exact checked-out PR head; the worktree is removed when it settles, so accidental source edits cannot change the dedicated review checkout. Configure the agent's own read-only/non-interactive mode as well when it offers one.

Arguments are never interpreted by a shell. Exact placeholder arguments can be used when a CLI needs a prompt-file path or PR context rather than stdin:

```json
"command": ["other-agent", "--prompt-file", "{{prompt_file}}", "--model", "{{model}}"]
```

Supported placeholders are `{{prompt_file}}`, `{{repository}}`, `{{model}}`, `{{effort}}`, `{{phase}}`, `{{pr_number}}`, `{{base_ref}}`, `{{head_ref}}`, `{{base_sha}}`, and `{{head_sha}}`. Placeholders must occupy a complete array item. If the CLI requires a model flag, configure a non-empty `agents.<name>.model`; the command array deliberately does not invent or remove CLI-specific flags. A generic command does not have structured token telemetry, so its dashboard `Tokens` value is `-` unless the command itself writes the normalized usage files documented below.

## Custom agent adapters

Use an executable `runner` only when the CLI cannot use the standard input/Markdown-output contract — for example, it needs a JSON event protocol, requires parsing structured output, or needs additional isolation:

```json
{
  "reviewers": ["claude", "codex", "gemini"],
  "synthesizer": "codex",
  "agents": {
    "claude": {},
    "codex": {},
    "gemini": {
      "label": "Gemini",
      "model": "<model-id>",
      "runner": "/absolute/path/to/review-pr-gemini-adapter",
      "instructions": "Use the PHP review skill configured for this CLI."
    }
  }
}
```

`runner` and `command` are mutually exclusive. A runner:

- runs with the review repository as its working directory;
- reads the complete orchestration prompt from stdin;
- writes only the phase payload to stdout: Markdown by default, or NDJSON when the current primary, cross-review, or final phase selects `ndjson-v1`;
- writes diagnostics to stderr;
- exits non-zero on failure;
- must not switch branches or modify repository files.

Custom adapters retain the same stdout contract selected by the orchestrator; they do not gain structured token telemetry from the finding contract. Their `Tokens` cell therefore remains `-` unless the adapter writes the normalized usage files; this is intentional rather than an estimate.

The orchestrator exports these variables to it:

```text
REVIEW_PR_AGENT
REVIEW_PR_PHASE
REVIEW_PR_OUTPUT_CONTRACT
REVIEW_PR_MODEL
REVIEW_PR_EFFORT
REVIEW_PR_ATTEMPT
REVIEW_PR_MAX_ATTEMPTS
REVIEW_PR_REPO
REVIEW_PR_NUMBER
REVIEW_PR_BASE_SHA
REVIEW_PR_HEAD_SHA
REVIEW_PR_TITLE
REVIEW_PR_TASK
REVIEW_PR_AUTHOR
REVIEW_PR_CHANGED_FILES
REVIEW_PR_ADDITIONS
REVIEW_PR_DELETIONS
REVIEW_PR_BASE_REF
REVIEW_PR_HEAD_REF
```

`REVIEW_PR_OUTPUT_CONTRACT` is `ndjson-v1` for an opted-in primary, cross-review, or final-synthesis phase and `markdown` for legacy phases and comparison synthesis. A runner should still treat the prompt as authoritative for the complete phase-specific schema and rules.

When an opted-in primary response is structurally repairable, the same agent may receive one
additional `REVIEW_PR_PHASE=primary findings repair` invocation with
`REVIEW_PR_OUTPUT_CONTRACT=ndjson-v1`. This pass is formatting/schema repair only: it must not inspect
source or change, add, remove, split, merge, translate, or reorder findings. The orchestrator compares
all substantive fields against a parsed baseline and rejects the repair on any difference.

Structured cross-review has an equivalent `REVIEW_PR_PHASE=cross-review findings repair` pass. It
also freezes classification, severity, source provenance, and contributing agents, then reruns the
complete schema, input-coverage, and changed-line validation before publishing any artifact.

A cross-review stream that stops before it answers every required source ref gets a different
pass instead: `REVIEW_PR_PHASE=cross-review findings continuation`. It is not a repair. The agent
keeps its tools and receives the original cross-review prompt again, followed by a continuation
block that names the records it already produced and a `PENDING SOURCE REFS` block that replaces
`REQUIRED SOURCE REFS` for that pass. The model answers only the listed refs and ends with one
`complete` record counting the kept and the new findings together. The orchestrator appends the
reply to the kept records, validates the merged stream as an ordinary cross-review, and compares
the leading findings against the kept ones field by field. Rewriting, reordering, or dropping a
kept finding rejects the continuation and the run falls back to the ordinary retry. The
continuation replaces the repair pass for that attempt, so an attempt still costs at most two
invocations, and it runs only when the failure diagnostic names nothing but `stream.no_complete`
and `source_refs.missing[...]`.

Structured final synthesis uses `REVIEW_PR_PHASE=final findings repair` for the equivalent bounded
pass. It also freezes `include_in_rejected_summary`; primary provenance is still derived by the
orchestrator and must not be emitted by the model. A failed or content-changing repair publishes no
canonical final NDJSON, sidecar, or Markdown report.

Every configured reviewer runs once successfully during primary review and once successfully during cross-review, subject to the configured attempt limit. A cross-reviewer receives every other primary report but never its own. The configured synthesizer then receives all primary and cross-review reports, producing the core `N -> N -> 1` pipeline. When final comparison mode is `standalone`, one additional, bounded synthesis pass produces the optional companion comparison report without changing the core final verdict.

## Parallel pull requests and Git worktrees

`execution.max_concurrency` controls reviewers within one PR only. The current command intentionally takes a repository-wide lock and detaches the dedicated checkout at the exact PR head, so two separate `review-pr <PR>` processes cannot use the same review repository concurrently. It does not currently create Git worktrees automatically. This prevents one PR from changing the checked-out source while another PR’s agents inspect it.

Running distinct PR reviews in parallel requires separate dedicated clones today. Automatic disposable worktrees are a separate future feature: it needs per-run worktree creation, cleanup/recovery rules, and an output/report identity independent of the shared checkout.
