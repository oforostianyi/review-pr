# review-pr

`review-pr` runs a configurable `N → N → 1` pull-request review pipeline in dedicated Git checkouts, with an optional standalone comparison report after the core final synthesis. It supports Claude Code, Codex, Pi, and custom command-line adapters. This package installs the same orchestrator on Linux and macOS; it does not bundle or purchase agent CLIs or models. This release is version `1.19.0`.

The public core is repository- and language-agnostic. Repository-specific profiles, prompts, and
review skills belong in user configuration or separately distributed team overlays.

## Requirements

Required on every platform:

- Bash 5.1 or newer (the macOS system Bash 3.2 is not sufficient);
- Git 2.23 or newer, including `git switch`;
- GitHub CLI (`gh`), authenticated for the repository;
- `jq` 1.6 or newer;
- a dedicated clone used only for PR reviews, with an `origin` remote;
- at least two configured review-agent commands and one configured final synthesizer.

Built-in agent commands are `claude`, `codex`, and `pi`. Only commands referenced by the active configuration are required. A team member without a local LLM may omit Pi and use two hosted agents, or add another CLI declaratively through `agents.<name>.command` without writing code.

The orchestrator itself has no PHP, Composer, Docker, Node.js, or Python dependency.

## Source test suite

Contributors working from the source repository can run the deterministic orchestration suite with:

```bash
./tests/review-pr/run.sh
```

It uses disposable local Git repositories, a fake `gh`, and mock agent runners. It exercises the
complete `N → N → 1` flow, failure/resume/rerun behavior, and installer configuration preservation
without contacting GitHub, invoking a real model, or touching the user's configuration. It also
tests default-branch and stacked-PR facts, reference ancestry, explicit unknowns, and atomic failure
before agents start. It also covers RIGHT-side line maps, renames, deleted/binary/context lines,
PR-level findings, and bounded final-anchor repair. The suite is a source-development asset and is
not included in the current end-user archive.

`packaging/private-data-audit.sh` scans every Git-tracked text file for personal home paths,
company or ticket identifiers, private network addresses, and credential-like values. It runs as
part of the test suite and again before `packaging/build-package.sh` stages a release, so a private
path or internal identifier cannot reach the public repository or package unnoticed. Generic
placeholder paths used in documentation are declared in `packaging/private-data-allowlist.txt`.

## Test real agent contract compatibility

Before enabling `ndjson-v1`, test a configured CLI/model without fetching or reviewing a pull
request:

```bash
review-pr contract-test --agent codex --phase all
review-pr contract-test --agent pi --phase final --output "$HOME/review-pr-contract-pi"
```

The command sends a small fixed fixture through the selected `primary`, `cross`, and/or `final`
contract, then runs the production validators and deterministic Markdown renderers. It runs agents
sequentially and preserves the prompt, raw output, stderr, normalized usage, canonical findings,
rendered Markdown, and `summary.json`. No configured review checkout, Git operation, GitHub request,
or real PR is involved. The selected CLI/model is still invoked, so hosted API usage, subscription
limits, and local inference time still apply. An explicitly named configured agent may be tested
while disabled; with no `--agent`, enabled reviewers plus the enabled synthesizer are selected.

## macOS prerequisites

Install Homebrew if it is not already present, then:

```bash
brew install bash git gh jq
gh auth login
```

Both Apple Silicon (`/opt/homebrew`) and Intel Homebrew (`/usr/local`) are detected. The installed launcher executes Homebrew Bash directly, so changing the login shell is unnecessary.

Install and authenticate the chosen agent CLIs separately. Confirm that each configured command is available:

```bash
command -v claude
command -v codex
command -v pi
```

## Linux prerequisites

Use the distribution package manager for Bash, Git, and jq. For Debian/Ubuntu-based systems:

```bash
sudo apt-get update
sudo apt-get install bash git jq
```

For Fedora-based systems:

```bash
sudo dnf install bash git jq
```

Install GitHub CLI using the package or official repository appropriate for the distribution, then authenticate:

```bash
gh auth login
```

Check that Bash is new enough:

```bash
bash --version
```

## Install optional agent CLIs

Install only the agents enabled in your `config.json`. `review-pr` needs at least two enabled reviewers and an enabled synthesizer, but they do not have to be all of the built-in agents. The commands below are the vendors' current macOS/Linux instructions; use the linked official documentation as the source of truth if a vendor changes its installer or authentication flow.

### Claude Code

If `claude` is absent, install the native CLI and then start it once to authenticate:

```bash
command -v claude >/dev/null 2>&1 || curl -fsSL https://claude.ai/install.sh | bash
claude --version
claude
```

See the [official Claude Code quickstart](https://code.claude.com/docs/en/quickstart) for Homebrew, Windows, account, and update options.

### Codex CLI

If `codex` is absent, install it and run it once to choose a sign-in method:

```bash
command -v codex >/dev/null 2>&1 || curl -fsSL https://chatgpt.com/codex/install.sh | sh
codex --version
codex
```

See the [official Codex CLI documentation](https://learn.chatgpt.com/docs/codex/cli) for supported installation methods, authentication, and updates.

### Pi

Pi is optional. If you enable it, leave its model/provider empty in `review-pr` when you want Pi to use its own configured default. `agents.pi.effort` (and `finalization.effort` when Pi synthesizes) maps to Pi's `--thinking` level: `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, or `max`; leave it empty to keep the model default. Install the current Pi CLI only when `pi` is absent:

```bash
command -v pi >/dev/null 2>&1 || curl -fsSL https://pi.dev/install.sh | sh
pi --version
pi
```

On its first interactive run, use `/login` or configure the desired provider as documented by the [official Pi documentation](https://github.com/earendil-works/pi/tree/main/packages/coding-agent/docs). Leave Pi's `model` empty in `review-pr` to use the provider/model configured as Pi's current default.

### Google Antigravity CLI

Google Antigravity's terminal agent is named `agy`. Install and authenticate it once before enabling it in `review-pr`:

```bash
command -v agy >/dev/null 2>&1 || curl -fsSL https://antigravity.google/cli/install.sh | bash
agy --version
agy
```

The first interactive run uses the local secure keyring or opens Google sign-in. See the [official Antigravity installation and authentication guide](https://antigravity.google/docs/cli/install/) for API-key and enterprise setup.

The package installs a safe custom runner at `<prefix>/libexec/review-pr/review-pr-agy`. It creates a disposable Git worktree for every run, so Antigravity can inspect the exact PR but any accidental source edits are discarded. Add it as a reviewer with an absolute path matching the selected prefix:

```json
{
    "agents": {
      "agy": {
        "label": "Antigravity",
        "enabled": true,
        "model": "gemini-3.1-pro-high",
        "effort": "",
        "runner": "/Users/example/.local/libexec/review-pr/review-pr-agy"
      }
    },
    "profiles": {
      "php": {"skills": {"agy": "php-code-review"}}
    },
    "reviewers": ["claude", "codex", "pi", "agy"]
}
```

Leave `model` empty to use Antigravity's current default. Its CLI accepts `low`, `medium`, and `high` as an optional `effort` value, but support is model-specific. Do not set a separate effort when selecting a model slug that already encodes it, such as `gemini-3.1-pro-high`; set `"effort": ""`. In particular, current AGY rejects `--effort` for `claude-sonnet-4-6`, so use `"model": "claude-sonnet-4-6", "effort": ""`; its `Thinking` capability is part of the selected model. It also forwards Antigravity's native JSON token usage into `work/*-usage.json` and the dashboard's `Tokens` column. The public core does not bundle an Antigravity review skill; configure an optional native or team-provided skill name when needed.

Before enabling AGY in a headless pipeline, configure its project-scoped `/permissions` for the selected review checkout. `review-pr` uses AGY's preview terminal sandbox and a disposable worktree; it does **not** use `--dangerously-skip-permissions` and must not receive a broad `unsandboxed(*)` or write permission. The installed `reference.md` documents the minimal read-only allowlist, failure messages, and recovery steps.

### Cursor Agent CLI

Cursor provides the `cursor-agent` CLI. It can be configured directly with `agents.<name>.command` when its selected non-interactive mode accepts stdin and returns final Markdown on stdout; a wrapper is needed only for a non-standard JSON/event protocol.

```bash
command -v cursor-agent >/dev/null 2>&1 || curl https://cursor.com/install -fsS | bash
cursor-agent --version
```

See the [official Cursor CLI installation guide](https://docs.cursor.com/en/cli/installation) and [headless/automation guide](https://docs.cursor.com/en/cli/headless) for authentication and non-interactive use.

## Current model reference

This table is a convenience snapshot checked on 2026-09-01. Providers can change model availability, names, and account entitlements without a `review-pr` release; use each vendor's linked documentation and the CLI's own selector as the source of truth before pinning a model.

| CLI | Model IDs / slugs in the current reference | How to verify current availability |
| --- | --- | --- |
| Claude Code | `claude-fable-5`, `claude-mythos-5`, `claude-opus-5`, `claude-opus-4-8`, `claude-opus-4-7`, `claude-opus-4-6`, `claude-opus-4-5-20251101`, `claude-sonnet-5`, `claude-sonnet-4-6`, `claude-sonnet-4-5-20250929`, `claude-haiku-4-5-20251001` | [Anthropic model status](https://docs.anthropic.com/en/docs/about-claude/model-deprecations) and `claude --model <id>`; a subscription or organization may expose only a subset. |
| Codex | `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`, `gpt-5.3-codex-spark` | [OpenAI Docs model selector](https://learn.chatgpt.com/docs/models) or Codex's `/model`; the visible selection depends on the account and plan. |
| Google Antigravity (`agy`) | `gemini-3.7-flash-high`, `gemini-3.7-flash-medium`, `gemini-3.7-flash-low`, `gemini-3.6-flash-high`, `gemini-3.6-flash-medium`, `gemini-3.6-flash-low`, `gemini-3.1-pro-high`, `gemini-3.1-pro-low`, `claude-sonnet-4-6`, `claude-opus-4-6-thinking`, `gpt-oss-120b-medium` | Run `agy models`. The official [headless CLI documentation](https://antigravity.google/docs/cli/headless/) lists supported flags and examples; results vary by account and configured provider. |

The Antigravity list above is from `agy models` on the maintainer's Antigravity CLI 1.1.23 account on the stated date, not a guarantee that every account receives every model.

## Prepare the dedicated repository

Create a separate clone for each repository you want to review. Never point a configured repository checkout at a development checkout containing unrelated work:

```bash
git clone git@github.com:YOUR-ORG/YOUR-REPOSITORY.git "$HOME/Review"
```

The configured path must be absolute.

## Get the package

`review-pr` is distributed as a source checkout, not as a binary. There are two
ways to reach an installable tree, and the first one is enough for most people.

### From a checkout

Clone the repository and check out the release you want. `main` is the current
development line; a tag is a released version:

```bash
git clone git@github.com:oforostianyi/review-pr.git "$HOME/src/review-pr"
cd "$HOME/src/review-pr"
git checkout v1.19.0        # or stay on main for the development version
```

The checkout is directly installable — skip to **Install** and run `./install.sh`
from this directory. Nothing has to be packaged first.

### As an archive

Build the distributable archive when you need to hand `review-pr` to a machine
that will not clone the repository, or to pin exactly what was installed:

```bash
packaging/build-package.sh
```

It writes two files into `dist/` and refuses to build when `VERSION` and
`bin/review-pr` disagree or when the private-data audit finds anything:

```text
dist/review-pr-1.19.0.tar.gz
dist/review-pr-1.19.0.tar.gz.sha256
```

Copy both to the target machine. `REVIEW_PR_DIST_DIR=<path>` writes them
somewhere else.

### From a release

Tagged releases carry the same two files, built and checked by CI from the tagged
commit, so a target machine needs neither a clone nor a build:

```bash
gh release download v1.19.0 --repo oforostianyi/review-pr --pattern 'review-pr-*'
```

## Install

From a checkout, run the installer in place:

```bash
./install.sh --repo "$HOME/Review" --reviews-dir "$HOME/review-pr"
```

From an archive, verify the checksum first, then extract and run the same
installer. Verifying is the point of shipping the `.sha256` beside it — a
truncated download otherwise fails much later and much less clearly:

```bash
sha256sum -c review-pr-1.19.0.tar.gz.sha256   # Linux
# or: shasum -a 256 -c review-pr-1.19.0.tar.gz.sha256  # macOS
tar -xzf review-pr-1.19.0.tar.gz
cd review-pr-1.19.0
./install.sh --repo "$HOME/Review" --reviews-dir "$HOME/review-pr"
```

`--repo` is the dedicated review checkout created above and must be absolute;
`--reviews-dir` is where reports are written and defaults to `$HOME/review-pr`.
Run `./install.sh --help` for the full set, including `--prefix` and
`--config-dir`.

The installer detects the GitHub `owner/repository` slug from that checkout. Pass `--github-repository OWNER/REPOSITORY` only when automatic detection is not available.

The default installation is user-local and needs no `sudo`:

```text
$HOME/.local/bin/review-pr
$HOME/.local/libexec/review-pr/review-pr
$HOME/.local/share/review-pr/
${XDG_CONFIG_HOME:-$HOME/.config}/review-pr/config.json
```

If `$HOME/.local/bin` is not on `PATH`, add it to the shell profile:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

For zsh on macOS this normally belongs in `~/.zshrc`; for Bash it normally belongs in `~/.bashrc` or `~/.bash_profile`.

Custom locations are supported:

```bash
./install.sh \
  --repo "/absolute/path/to/Review" \
  --reviews-dir "$HOME/review-pr" \
  --prefix "$HOME/tools" \
  --config-dir "$HOME/.config/review-pr"
```

The installed launcher records the chosen config path, so no persistent environment variable is required for `--config-dir`.

Re-running the installer is the supported upgrade path: it updates package-managed files without replacing `config.json`. Before every repeat installation it writes an immutable timestamped copy to `<config-dir>/backups/config-YYYYMMDD-HHMMSS.json`; no old backups are deleted automatically. `--repo` updates only the default repository entry (and migrates an old single-repository config), while `--reviews-dir` updates only its artifact directory. All other personalized configuration remains intact.

## Configure agents

Edit the installed `config.json`. A hosted-agent-only setup can be as small as:

```json
{
  "$schema": "./review-pr.schema.json",
  "agents": {
    "claude": {
      "label": "Claude",
      "enabled": true,
      "model": "claude-opus-5",
      "effort": "high"
    },
    "codex": {
      "label": "Codex",
      "enabled": true,
      "model": "gpt-5.6-terra",
      "effort": "high"
    }
  },
  "reviewers": ["claude", "codex"],
  "synthesizer": "codex",
  "default_repository": "repository",
  "repositories": {
    "repository": {
      "github": "YOUR-ORG/YOUR-REPOSITORY",
      "checkout": "/absolute/path/to/Review"
    }
  },
  "reviews_directory": "/absolute/path/to/review-pr-output",
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

Pi is not present in the distributed default pipeline, so a clean installation only needs Claude and Codex. Add Pi later if wanted; set `"enabled": false` to keep its configuration while excluding it from a run. A profile or repository may name an agent skill (for example, `"pi": "php-code-review"`), but no absolute skill path is required or validated and Pi is never passed a hardcoded `--skill` path. Leaving Pi's model empty makes Pi use its currently configured default provider/model.

`reporting.finding_contract.primary`, `cross_review`, and `final` accept `markdown` (the backward-compatible default) or opt-in `ndjson-v1`. Structured cross-review requires structured primary findings and `comparison_sections.cross_review: "none"`; structured final synthesis additionally requires both earlier stages to be structured and `comparison_sections.final` to be `none` or `standalone`. Primary agents return atomic records, cross-reviewers classify canonical primary refs, and the finalizer classifies canonical cross-review refs. The orchestrator validates completeness, provenance, severity, and exact changed-line anchors, derives transitive primary provenance itself, preserves `work/*-raw.ndjson`, publishes canonical `work/*-findings.json`, and renders localized Markdown deterministically. A structurally repairable response receives one content-stable schema-repair pass; cross and final repair additionally freeze classification, severity, provenance, and rejection-presentation decisions. A cross-review or final stream that simply stopped before answering every required source ref is continued instead: the records it already produced are kept, the same agent is asked for the unanswered refs alone, and the merged stream must pass the full contract with those records unchanged. Invalid structured output never falls back to Markdown. Resume uses the modes saved in the manifest, and final reruns reuse canonical cross-review sidecars. The installed `review-pr-findings-v1.schema.json` documents the portable record shape.

`reporting.comparison_sections.cross_review` accepts `none` or `inline`; `final` accepts `none`, `inline`, or `standalone`. The distributed default keeps cross-reviews compact and generates the extended Sources, reviewer matrix, Agreements/Disagreements, review-depth, conclusion, and agreed-actions material as a separate `<review-stem>-comparison.md` after the core final report. This reduces final-output pressure for local models. The deprecated `include_comparison_sections` boolean remains compatible (`true` = inline/inline, `false` = none/none).

Pi output is extracted from its final assistant `message_end` event. If Pi reports `stopReason: length`, the run fails with an explicit output-token-limit reason and preserves normalized usage, raw JSONL events, and any partial Markdown next to the error log. Increasing the model's configured `maxTokens` can resolve a genuinely truncated response; splitting comparison content into the standalone report often reduces the required final-output size.

## Resume a failed run

Use the timestamp already printed by the failed run to continue it without repeating successful reviewers:

```bash
review-pr repository#123 --run 20260901-154503-CEST
```

The command verifies the manifest and PR head, runs only missing/failed reports in the first incomplete phase, and then continues the remaining phases. Use `--rerun-final` only when primary and cross-review are already complete.

A run can only be resumed for the exact PR head it recorded. If new commits were pushed to the pull request since then, the preserved reports describe older code, so the command refuses to resume and names the head change; start a new run for the current head instead.

To re-synthesize a completed historical run without touching Git or GitHub, select its timestamp explicitly:

```bash
review-pr --rerun-final repository#123 --run 20260901-154503-CEST
```

Manifest-backed final reruns are artifact-only: metadata comes from the source manifest, and its preserved cross-review reports plus repository-facts snapshot are supplied to the finalizer. The current PR head may have changed. No fetch, checkout, branch switch, GitHub request, or current-source inspection is performed. The legacy `--force --run` compatibility path is the exception because pre-manifest artifacts lack reliable recorded metadata.

## CI checks as review evidence

Every reviewer receives the check runs GitHub reports for the exact PR head, with each check's status and conclusion, plus the annotations it produced. Annotations carry a level, a file, a line, and a message, so a red `phpstan` or a coverage gap becomes usable evidence instead of a bare conclusion. At most 20 annotations per check and 60 per run are attached, each message trimmed to 200 characters; failing to read them never fails the review.

A failed, pending, or skipped check is never a finding by itself, in any phase. It is recorded as a verification limitation, because a review states what the code does, not what a pipeline reported.

Checks that are still running when the reviewers start often settle before the synthesis, so the check state is read again just before the final phase. The snapshot the reviewers received stays published as it was; only the finalizer sees the settled state. An artifact-only rerun never reads GitHub.

## Authoritative repository facts

Every new full run measures shared repository facts before agents start and stores
`work/*-repo-facts.json` plus `work/*-repo-facts.md`. They include exact base/head SHAs, merge base,
the fetched default-branch tip, stacked-PR status, the exact changed-file list, and resolvable PR or
commit references from the description. Primary, cross-review, and final prompts receive the same
Markdown snapshot.

GitHub `merged=true` is retained only as context. The `ancestry_on_current_default.value` field is
set only from local `git merge-base --is-ancestor` against the fetched default tip; unmeasurable
facts remain `null` instead of being guessed. Optional reference lookup failures produce a
`complete_with_unknowns` snapshot, while failure to determine a structural fact stops the run
before agents start and does not publish a partial canonical facts pair.

Resume and manifest-backed `--rerun-final` reuse the facts named by the source manifest. Historical
manifests without facts remain compatible, but their finalizer is told not to infer missing
topology from agreement between reports.

## RIGHT-side anchors for final findings

All three review stages receive a common database-migration verification rule: report deterministic failures unequivocally when code/schema evidence proves them; keep data-dependent risks qualified and recommend validation on staging with production-like data when such an environment exists. The tool does not assume that staging exists or claim it was used without evidence.

Git-backed runs also capture paginated GitHub review-thread state and map GraphQL threads to REST inline-comment IDs. Reports can therefore distinguish new feedback from confirmation of an existing unresolved thread. GraphQL failure or nested-thread truncation is explicitly `unavailable` or `partial`; it is never treated as proof that no unresolved feedback exists. Resolved and outdated threads remain historical context and do not automatically suppress a current occurrence.

New full runs write `work/*-changed-lines.json`, a compact map of added/modified RIGHT-side line
ranges from the exact diff. A detailed confirmed finding uses
`<!-- review-pr:anchor:changed-line -->` with one repository-relative File and a Line or range whose
end exists in that map. Missing tests, migrations, and genuine PR-wide omissions instead use
`<!-- review-pr:anchor:pr-level -->` with `File: —` and `Line: —`; the finalizer is not forced to
invent a location.

Validation results are stored in `work/*-anchor-validation.json`. An invalid but otherwise useful
draft receives one bounded repair attempt. Only marker/File/Line fields may change, the result is
validated against the map again, and byte-level comparison rejects any attempt to rewrite the
finding itself. The original invalid draft remains available as a diagnostic. Historical manifests
without a map continue to work with validation explicitly marked unavailable.

### Add any stdin/stdout CLI without a runner

For a new agent, use a JSON argument array — not a shell command string. `review-pr` invokes the command directly, streams its prompt to stdin, accepts only Markdown from stdout, and sends diagnostics to stderr. This means adding a compatible agent is a config-only change:

```json
{
  "agents": {
    "other": {
      "label": "Other CLI",
      "enabled": true,
      "model": "chosen-model",
      "command": ["other-agent", "--non-interactive"]
    }
  },
  "reviewers": ["claude", "codex", "other"]
}
```

For a CLI that accepts a prompt file rather than stdin, use an exact placeholder argument: `"command": ["other-agent", "--prompt-file", "{{prompt_file}}"]`. Other safe placeholders are `{{repository}}`, `{{model}}`, `{{effort}}`, `{{phase}}`, `{{pr_number}}`, `{{base_ref}}`, `{{head_ref}}`, `{{base_sha}}`, and `{{head_sha}}`. Each generic command receives its own disposable detached worktree at the exact PR head, which is removed afterward; select the CLI's read-only mode as an additional guard when it has one. `command` and `runner` are mutually exclusive.

Use `runner` only for protocols which cannot fit this contract, such as Antigravity's streaming JSON mode, structured-output parsing, or a runner that provides additional workspace isolation. Generic commands receive the same `REVIEW_PR_*` context environment variables as runners, but their Tokens field remains `-` unless they write the documented normalized usage files.

## Optional review skills

The public package does not bundle repository-specific methodology. A profile may configure a skill
name for each agent, but skills remain optional: the agent may resolve the name from its native skill
installation, or the orchestrator may append a local copy from
`${XDG_CONFIG_HOME:-$HOME/.config}/review-pr/skills/<agent>/<skill>/SKILL.md`. A missing skill never
prevents a review. Teams can distribute their own skills as a separate overlay without patching the
core executable or replacing the user's `config.json`.

A team overlay is an ordinary directory tree that each member copies into place, for example:

1. Ship `skills/<agent>/<skill-name>/SKILL.md` for every agent that should receive the methodology
   (`claude`, `codex`, `pi`, `agy`, or a custom agent name); the installer preserves existing copies
   and never overwrites a member's own edits.
2. Ship a JSON fragment for `profiles.<profile>.skills` that maps agents to `<skill-name>`, plus the
   `repositories.<alias>` entries with `profile` set, and merge it into `config.json` with `jq`.
3. Keep repository rules the skill relies on (contribution guides, ADRs, lint configuration) inside
   the reviewed repository itself, so a finding can cite an explicit rule with its path.

Nothing in the overlay is executed: skill text is appended to the agent prompt as methodology, and
the orchestrated-mode safety rules in the core prompt take precedence over it.

Review repository and config can also be overridden without editing JSON:

```bash
REVIEW_PR_REPO="/other/dedicated/clone" \
REVIEW_PR_CONFIG="/other/config.json" \
review-pr --show-config
review-pr --version
```

The complete custom-command and runner contract is documented in `reference.md` after installation.

## Verify and run

Verification does not start a PR review:

```bash
review-pr --show-config
```

Then run a review explicitly. A bare number selects `default_repository`; aliases, `owner/repo#number`, and GitHub PR URLs select a configured repository directly:

```bash
review-pr 123
review-pr repository#123
review-pr YOUR-ORG/YOUR-REPOSITORY#123
review-pr YOUR-ORG/YOUR-REPOSITORY/pull/123
review-pr https://github.com/YOUR-ORG/YOUR-REPOSITORY/pull/123
```

The command fetches and detaches the dedicated checkout at the exact PR head. It refuses tracked changes and never operates on another checkout.

## Hand a finished review to a fixing agent

The final report is written for a human. An agent that will do the fixing needs the actionable part, not the prose, so `findings` prints it as JSON:

```bash
review-pr findings 123
review-pr findings --include uncertain 123
review-pr findings --run 20260914-120000-CEST 123
```

A structured run also publishes that set on its own, as `<review-id>-<timestamp>-fix-list.json` beside the final report, so the fixing agent's copy travels with the review instead of being regenerated by hand. `reporting.findings_export` chooses its scope: `confirmed` (the default), `uncertain`, `all`, or `off` to publish nothing. Runs whose final contract is `markdown` publish nothing either, because there is no structured set to export. The subcommand stays useful for a different scope, or for a run finished before the file existed.

The subcommand reads only the canonical final sidecar a structured run already published, so it needs no agent CLI, no network, and no Git work, and it writes nothing. Each entry carries the id, classification, severity, category, exact anchor, title, claim, failure scenario, recommendation, and the verification limitations that qualify it.

Confirmed findings are exported by default. `--include uncertain` adds the claims that could not be settled, and `--include all` adds refuted ones too; an agent should act on the confirmed set and reproduce an uncertain claim before touching anything. Findings with no natural changed-line anchor, such as a missing test or migration, keep an empty anchor and are listed after the anchored ones instead of being dropped. Without `--run`, the freshest final synthesis for that pull request is used, including one produced by `--rerun-final`. A run without `reporting.finding_contract.final = ndjson-v1` publishes no such sidecar and is refused with that reason.

## Upgrade

Get the newer version the same way you got the first one — pull the checkout and check out the newer tag, or extract a newer archive — and run its `install.sh` with the same prefix/config options. The existing configuration is retained, and a timestamped pre-upgrade backup is written to `<config-dir>/backups/`. Uninstalling first is neither needed nor recommended. Each file is renamed into place rather than rewritten where it stands, so a review already running keeps reading the build it started with instead of a half-replaced script.

Use `review-pr --version` to identify the installed release. See `CHANGELOG.md` in the checkout or the release archive for release notes and compatibility-impacting changes.

Rollback works the same way: check out the previous tag, or extract the previous archive, and run
that `install.sh` with the same options. Program files are replaced wholesale and the configuration is backed up again first. If a
newer release migrated `config.json` (for example the legacy single `review_repository` field into
`repositories`), restore the matching pre-upgrade copy from `<config-dir>/backups/config-<timestamp>.json`
before running the older version; backups are byte-for-byte copies and are never pruned by the
installer or the uninstaller.

Report compatibility: Markdown reports and `*-manifest.json` files written by earlier releases stay
readable, and `--rerun-final` and `--run` accept them as long as the recorded PR head still matches.
Structured `ndjson-v1` artifacts carry `schema_version: 1`; a release that introduces a new schema
version says so in `CHANGELOG.md`, and the default configuration keeps the Markdown contracts, so an
upgrade never changes the output format of an existing configuration by itself.

## Uninstall

Remove installed program files while preserving configuration:

```bash
./uninstall.sh
```

To remove the configuration too:

```bash
./uninstall.sh --purge-config
```

Review reports and the dedicated Git checkout are never deleted by the uninstaller.

## Security model

- **Agents run with your privileges.** Every configured `command`, `runner`, or built-in CLI is
  started as the invoking user without a shell: `agents.<name>.command` is an argv array, so
  configuration values are never re-parsed by `sh`. Only commands named in the active configuration
  are required or executed.
- **The review checkout is disposable.** The orchestrator works in the dedicated clone at the exact PR
  head, refuses tracked changes there, and never touches other repositories. The Antigravity runner
  goes further and reviews a throwaway Git worktree, so accidental edits are discarded.
- **PR text is untrusted input.** PR descriptions, comments, and review threads are passed to agents
  inside a clearly delimited context block with an instruction to treat them as data, never as
  instructions; the checked-out source and exact diff remain the source of truth.
- **Orchestrator-executed commands are allow-listed.** With `reporting.execute_measurements`
  enabled, the orchestrator runs only read-only tools (`rg`, `grep`, `git show|log|diff|...`, `ls`,
  `cat`, `head`, `wc`, `test`) proposed by the finalizer, without a shell, inside the review checkout,
  with a ten-second timeout and bounded, credential-redacted output. Anything else is recorded as
  skipped and never run. The feature is off by default.
- **Pi tool calls are bounded.** `agents.pi.max_tool_calls` loads a small extension that blocks
  duplicate tool calls and terminates the agent after the budget, so a looping local model cannot run
  indefinitely.
- **Antigravity permissions are explicit.** Headless AGY denies any command not covered by an allow
  rule; the reference documents the read-only rule set the runner expects. Grant only those.
- **Nothing is uploaded by the orchestrator.** GitHub access is read-only through `gh` (PR metadata,
  comments, review threads, check runs). Reports stay in `reviews_directory`; publishing them is a
  manual step.

## Troubleshooting

- **Bash 5.1 or newer is required:** on macOS run `brew install bash`; the launcher searches Apple Silicon and Intel Homebrew paths automatically. `REVIEW_PR_BASH=/custom/path/bash` is also supported.
- **Required command not found:** install or add the configured `claude`, `codex`, `pi`, generic agent command, or custom runner to `PATH`.
- **GitHub errors:** run `gh auth status` and verify access to the repository and its pull requests/checks.
- **Configured skill unavailable:** it is advisory only. Install the named skill for that agent, change the name, set it to `""`, or remove the mapping; the orchestrator does not fail because a local skill file is absent.
- **Review repository has tracked changes:** preserve or commit them elsewhere; this checkout is intentionally dedicated to reviews.
- **An agent times out:** the phase log reports `timeout after <n>s` and the manifest records the
  attempt under `attempt_failures`. Raise `agents.<name>.timeout_seconds` for slow local models, or
  lower `execution.max_concurrency` so agents do not compete for the same GPU or API quota. A resume
  with `--run <timestamp>` re-runs only the agents that did not complete.
- **A local model loops on tool calls:** set `agents.pi.max_tool_calls` (a few hundred is generous
  for a large PR). The guard blocks repeated identical calls, terminates the agent when the budget is
  spent, and writes a summary into the agent log; the final diagnostics record it as
  `pi_guard_budget_exhausted` or `pi_guard_duplicates_blocked`.
- **A local model hits its output token limit** (`stop_reason: length`, failure reason
  `repair_output_token_limit`, or a truncated NDJSON stream): reasoning models can spend most of the
  budget thinking before they print the contract. Use a larger output limit in the model server,
  pick a non-reasoning finalizer with `finalization.model`, or reduce the input by running with fewer
  reviewers. The orchestrator never publishes a truncated report; the partial output is kept as
  `*-error-partial-raw.ndjson` for inspection.
- **A structured stream stops after the first records** (`stream.no_complete` together with
  `source_refs.missing[...]`): the agent treated one record as the whole answer. A cross-review or
  final synthesis is continued automatically in that case, and the interrupted draft is kept as
  `*-error-continuation-source-raw.ndjson`. A continuation that answers an unlisted ref or repeats
  an answered one is refused with `continuation_changed_kept_findings_or_remained_invalid`, and the
  run falls back to the ordinary retry.
- **Invalid structured output:** the failure reason names the field, for example
  `schema_or_completeness_validation_failed: finding[F-2].anchor`. One bounded repair pass asks the
  same agent to fix only the schema; substantive fields are frozen and a changed decision is rejected.
  The invalid response and the repair exchange are kept next to the run's `*-error*` artifacts.
