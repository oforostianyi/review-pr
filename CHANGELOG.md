# Changelog

All notable changes to `review-pr` are documented in this file. The project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `--run last` selects the most recent full run of the pull request, for a resume, a `--rerun-final`
  and `findings` alike, so an identifier no longer has to be copied out of a directory listing. It is
  resolved once, before anything looks a run up, and the chosen run is logged — a command that picks
  its own target silently is one a reader cannot check. "Most recent" is decided by the instant the
  manifest recorded, not by the identifier as text, so it survives a timezone change like every other
  selection now does. A re-synthesis is never the answer, because a resume and a final rerun both work
  from a full run.

- `effort` accepts `auto` for every built-in adapter, meaning what an empty effort already meant: no
  flag is sent and the CLI uses its own default. It is a name for that rather than a value passed on,
  because neither CLI takes it — `claude --effort auto` warns that the value is unknown and uses its
  default anyway, and Codex answers HTTP 400, which would have failed the phase. A value that merely
  resembles it, such as `automatic`, is still refused.

### Changed

- The model reference in `README.md` is a 2026-09-23 snapshot and gained the models both vendors
  released this week, `claude-opus-5-5` and `gpt-6-sol`. It also gained a Pi row, which the table
  could not describe before: `pi --list-models` reports the provider, context window, maximum output
  and whether a model takes a thinking level at all, per account, so it is authoritative where the
  other rows are a snapshot. That last column matters — `dirk-qwen3.8-27b@iq3_s` supports a thinking
  level and `@iq3_xxs` does not, though they are one model at two quantisations. Artificial Analysis
  is linked as the other half of the question: the table says what a CLI accepts, not which model is
  worth the tokens.

### Fixed

- A key that only says how a finding is presented no longer costs the finding: a missing or
  undefined `existing_feedback` becomes `unknown` (what the model wrote is kept among its
  verification limitations), a final finding without `include_in_rejected_summary` gets `false`, a
  REJECTED or UNCERTAIN verdict without `failure_scenario` or `recommendation` gets `null`, and a
  key a `complete` record does not define is dropped. Repair baselines get the same defaults, so a
  faithful repair of such a draft passes its stability check.
- An anchor that covers changed lines may end on a context line of its own diff hunk, recorded as
  `right_side_hunks` in the changed-line map: git often prints the closing brace of a new block as
  unchanged, and a finding anchored to the whole block was rejected for that one line.
- A record closed early by a stray brace no longer leaves a truncated copy behind: a line's objects
  are kept only when the whole line parses.
- Everything the run writes to stderr while the live table is up is printed above the next frame,
  not into it, so a stray warning no longer leaves copies of a section title; nothing appended to the
  message file during a redraw is lost, and a failure while the table is up still prints its ERROR
  line.
- Prompts no longer call every pull request a PHP one, and they say that text addressed to models
  inside the code under review is its subject, never an instruction.
- Each structured prompt ends with a checklist of every record's keys and every closed value set, a
  final synthesis is salvaged only after every attempt and the fallback have failed, and prose ahead
  of the first record is dropped without a model call.
- A measurement can no longer write a file. The policy refused an absolute path, but read the whole
  argument, and an option carries its path after an equals sign — `--output=/etc/x` begins with a
  dash, so it passed. The value after an equals sign is now examined on its own, and `--output` is
  refused whatever it points at, because a measurement reads the checkout and never writes. Reachable
  only with `reporting.execute_measurements = true`, which is off by default.
- A continued or repaired final answer keeps the finalization model, the finalization effort and, in
  a `--rerun-final`, artifact-only mode. Those three were keyed on the phase names `final synthesis`
  and `comparison synthesis`, and a continuation, a schema repair or an anchor repair runs under a
  name of its own, so each fell back to the agent's own model and reached into the checkout for source
  the same prompt forbids it to read — and would fail outright once that checkout had moved on.
- `findings` exports the most recent synthesis. A re-synthesis is named after the run it was made
  from, so ordering the candidates as text ranked it by that older source run: a rerun of Monday's run
  lost to Tuesday's ordinary report, and the agent sent to fix the findings received a list that had
  already been superseded. The manifest beside each artifact records when it was produced, and that is
  what decides now.
- The Pi tool guard ends a model that loops on one call. The duplicate branch returned before the
  termination check, so repeats were blocked forever and the attempt ran to the agent's wall-clock
  timeout — an hour, where the per-call timeout is disabled. Only an unbroken run of repeats is fatal;
  an occasional re-read between real calls is ordinary and resets the count.
- The published schema accepts `auto` wherever the orchestrator does. Added to the validator without
  the schema, it left a working configuration marked as an error by every editor.

- The portable copy of a configured skill is found by agent key and then by adapter type, the way the
  skill name itself is resolved. It was found by key alone, so an agent given a key of its own ran
  without the skill its configuration named: the instruction still said to use it, and the whole text
  was missing from the prompt. A four-agent run showed the cost -- two Pi agents, meant to differ only
  by model, received prompts 22KB apart, and the comparison measured the missing skill rather than the
  models.

### Changed

- The prompt claims precedence over a configured skill for the output format, not only for
  persistence and safety. A skill is review methodology, but the ones written for this project also
  carry a Markdown report template and a verdict vocabulary of their own, and the wrapper granted the
  prompt authority over neither. A reviewer that follows the skill's format drops the fields only the
  contract defines: on PR 29024 one emitted cross-review records in the final phase's shape with no
  `source_refs` at all. The wrapper now says the response format, its structure, its field names and
  its classification words come from the prompt alone, and that a layout the skill prescribes applies
  to running that skill directly.

## [1.21.0] - 2026-09-22

### Added

- `timezone` names the zone every timestamp is written in: the run identifier that names a run's
  directory and is passed back to `--run`, the manifest and run-history times, the log prefix, and
  the dashboard clock. It was `Europe/Warsaw`, compiled in at sixteen call sites, so a tool about to
  be published named every run in one maintainer's local time. Omitting the key follows the machine's
  own zone, which is what most people want and what the old default happened to be on the machine it
  was written on. A zone that is not installed is refused when the configuration loads, because `TZ`
  reports nothing for an unknown name — it silently gives UTC, and a typo would have renamed every
  run without a word.
- An identifier may now end in any zone's abbreviation, or in the numeric offset that zones without
  one produce, including the hours-only form `America/Sao_Paulo` gives. Six places accepted only
  `CET` and `CEST`, so outside Central Europe a run could not be selected with `--run` at all.
- A completed final rerun is recorded on the run it was made from, as an entry appended to
  `final_reruns` naming its timestamp, synthesizer, model, published report, manifest, and
  completion time. The rerun manifest already named its source; nothing pointed the other way, so a
  run whose final phase failed and was rescued afterwards read as a dead end — its status said
  `failed` and nothing said where the report that replaced it went. That status is still never
  rewritten, because the run did fail. Entries accumulate, so re-synthesising one set of inputs with
  two models leaves both, and a `--force` rerun records nothing because it deliberately works
  without a source manifest.

### Fixed

- A failing phase no longer leaves a broken table on the terminal. The live frame is redrawn by
  moving the cursor up its own height, which assumes the frame below it is whole, and the background
  refresher was killed wherever the signal found it. Caught in the middle of drawing, it left the
  cursor inside the frame, so the redraw that follows moved up from there, landed above the frame and
  covered only part of the old one — its tail stayed on screen, below the error and the shell prompt.
  A frame takes milliseconds and the pause between frames a second, so a stop landed inside one only
  now and then, which is what made the damage look random. The refresher is now asked to stop rather
  than killed where it stands: the handler raises a flag, bash runs it between commands, and the
  frame in progress is finished first. It still stops at once when idle, because the pause is waited
  on as a child and a trap interrupts the wait immediately.
- The newest run is chosen by the instant it started rather than by comparing identifiers as text.
  A zone abbreviation does not order chronologically: `GMT` follows `IST` but sorts before it, so on
  the night the clocks go back in Ireland `--rerun-final` without `--run` would silently synthesise
  from the older run. Travel does the same without any transition — a run made three hours after
  flying from Warsaw to New York carries an earlier clock time than the one before the flight.
  Manifests already recorded `created_at` with a numeric offset, which names an instant exactly, and
  that is what is compared now; runs written before the field existed still fall back to the
  identifier.

### Changed

- `README.md` explains that an agent's key is a label and `type` names the adapter that runs it, with
  a worked configuration of two Pi agents and two Claude agents. The capability shipped in 1.20.0 and
  was described only in the reference, which is not where someone meeting the tool first looks. Its
  example configuration also showed the `markdown` contract while the distributed one has run
  `ndjson-v1` since 1.20.0, so a fresh installation did not match what the front page showed.
- A release tag is tested on macOS as well. macOS runners were restricted to the default branch to
  keep private-repository minutes down, which left the tag build — the one people install — as the
  only build that skipped a platform, and 1.20.0 went out with a test suite that was broken there.

## [1.20.0] - 2026-09-22

### Added

- An agent's key no longer decides which CLI runs it. `type` names the built-in adapter — `claude`,
  `codex`, or `pi` — and defaults to the key, so every existing configuration keeps working untouched.
  Naming it lets several agents share one adapter with different models, which the key could not
  express: a local Pi and a hosted Pi, or two Claude models at different efforts, in one review. The
  adapter now decides which executable is required, how effort is spelled, whether `max_tool_calls` is
  accepted — it was restricted to the literal key `pi`, which blocked a second Pi outright — and
  whether an event stream is kept for diagnosis. Artifacts stay named after the key, so agents sharing
  an adapter never collide, and a review skill is resolved by key first and by type second, so a new
  agent inherits its adapter's skill instead of silently losing one.


### Fixed

- The dashboard documentation matched an older layout. The `Agent` column is 27 characters, not 29,
  since the retry counter took two of them, and the retry status the counter produces — `RETRYING[2]`
  in place of `RUNNING` — was not described at all. `README.md` still announced two ways to obtain the
  package after a third, downloading a published release, was added in 1.19.0.
- A lone backslash inside a string no longer throws away a finished stream. JSON gives a backslash
  one job, so a backslash before a character that starts no escape can only have meant a literal
  backslash; the orchestrator doubles it and parses the line again. Reviewing PHP makes this the
  likeliest way for a valid review to be rejected — every fully qualified class name carries
  backslashes — and it already had: on PR 28956 the reviewer finished a complete twelve-record stream,
  eleven findings and the terminal record, and the run failed after 65 requests and 84 tool calls over
  one unescaped `GuzzleHttp\Handler\MockHandler`. A line that still does not parse fails as before.
- The three `ndjson-v1` contracts now show how to escape a backslash, with the PHP class name that
  causes the failure as the example. The blocks sit in heredocs with different quoting, so the same
  source text does not reach the model the same way; a test reads the generated prompts and checks
  that the wrong example really carries one backslash in all three.

### Changed

- The distributed example configuration runs `ndjson-v1` in all three stages and no longer carries
  `prompts`. It shipped the `markdown` contract with cross-review and final prompts that describe
  Markdown classification tables — instructions the orchestrator discards under `ndjson-v1`, where the
  model returns records and the Markdown is rendered deterministically. A new installation therefore
  started on the older mode, and anyone who switched contracts kept prompts that contradicted them.
  The example also pins `claude-opus-5` and `gpt-5.6-terra` at `high` effort for its two enabled
  agents instead of leaving the model empty.
- `docs/review-pr.md` says that `prompts` apply only to the `markdown` contract and are not sent under
  `ndjson-v1`, which was true in the code but stated nowhere.


## [1.19.0] - 2026-09-21

### Added

- Pushing a `v*` tag publishes the archive. CI already built and verified the package on every push,
  but only as a workflow artifact that expires after two weeks, so the install instructions had
  nothing durable to point at. The release job runs after the test jobs, refuses a tag that disagrees
  with `VERSION` — an archive whose contents claim another version is worse than no archive — builds
  the package, and attaches `review-pr-<version>.tar.gz` and its `.sha256` to the GitHub release.
  Re-pushing a tag replaces the attached files instead of failing, so a corrected build can be
  published without deleting the release.
- `packaging/release-notes.sh` prints one version's `CHANGELOG.md` section, which the release job
  uses as the release notes. It lives in a script rather than inline in the workflow so it can be
  tested: the section runs from its own heading to the next one, never includes `Unreleased` or the
  file preamble, and a version with no section fails rather than publishing an empty release page.

### Changed

- The README says where the package comes from. It opened at "extract the archive" without naming
  anything that produces one, and no release asset exists to download, so the first step led nowhere.
  A checkout is now the documented primary path — it installs directly, with no packaging step — and
  building the archive with `packaging/build-package.sh` is documented for handing the tool to a
  machine that will not clone the repository, including what it writes and what makes it refuse. The
  upgrade and rollback sections no longer assume an archive is the only form.
- Documentation examples no longer put review checkouts under a `Work` directory, which is one
  maintainer's personal layout rather than a convention worth prescribing. They use `$HOME/Review`
  and a neutral `Reviews/` in the configuration example.


### Added

- Every run appends itself to `run-history.jsonl` at the root of the reviews directory, one log across
  every configured repository, so finding out what ran overnight no longer means reading through review
  directories. Two lines per run: one when it starts, one when it ends. Both, because a run that was
  interrupted or refused would otherwise leave nothing behind, and the end record is appended from the
  exit path, so it survives a failure or a Ctrl+C rather than only a clean finish. A record carries the
  time, pull request, repository, mode, review id, run timestamp, exit status, duration, version,
  configuration file, and pid. `findings` and `--show-config` read rather than run, and are not logged.

### Fixed

- A shortened agent label keeps its ellipsis. The label was trimmed to 29 characters while the row
  printed it at 27, so a long one lost the ellipsis and ended mid-word (`Claude (claude-sonnet-5 hig`).
  One constant now sets the column width, and the label builder, the header, and the row all read it.
- The live table no longer prints its section header two or three times. Anything written straight
  to the terminal while the table is up leaves the cursor one row below where the next redraw
  expects it, and every later frame strands a copy of its own top line; two stray lines in a run
  were enough to show `PRIMARY REVIEW` three times. While the table is up the renderer is now the
  only writer: `log` hands it the line, and it prints what is waiting where the frame begins, so
  messages scroll into the history above a table that keeps its exact height. The same defect was
  fixed once before by moving one particular message onto the suppressed logger, which left the
  class open; the suite only ever exercised log mode, so the table path was never covered. It is
  covered now.

### Changed

- A rejected configuration now says what is wrong with it. Validation is one long boolean, so the
  reader was told only that the file was invalid and had to bisect a hundred conditions by hand: a
  real `clcd.json` failed because it named a disabled agent as its synthesizer, and finding that
  meant evaluating the clauses one at a time. Failures are now listed, each naming the setting and
  quoting the offending value, with the allowed values for an enum. The validator itself is
  untouched and remains the authority on what is accepted; the diagnostic runs only after it
  refuses, and falls back to the old message for anything it does not recognise, so it cannot widen
  what the orchestrator accepts.


## [1.18.0] - 2026-09-15

### Added

- Usage summaries now report what a phase actually cost. A CLI that reports usage per request —
  Pi does — was read for its last request only, so a ten-request synthesis was recorded at a tenth
  of its size: on PR 28816 the file said 77318 tokens where the conversation billed 792393. Those
  per-request figures are summed now, and two fields say what the totals are made of: `requests`,
  the number of model calls, and `final_context_tokens`, the last request's context, which is what
  bounds the model's window. A CLI that reports once is unchanged.
- Usage summaries count `context_compactions`, and a run whose context overflowed says so in its
  diagnostics. After a compaction the agent continues from a summary of what it read rather than
  from what it read, which is worth knowing when weighing its findings. Measured on a real primary
  review, the context climbed to 102445 tokens over 80 requests before Pi compacted it back to
  37780. The count is `null` for a CLI that does not report compaction, never a guessed zero.
- The status column names the attempt on screen. A retry used to look exactly like a first attempt,
  so `RUNNING` becomes `RETRYING[2]` while the second attempt runs and while it waits to start; the
  spinner still marks the live row. The column took three characters from `Agent` and `Tokens`, both
  of which had slack; `Elapsed` did not, since a run can pass an hour.

### Fixed

- A final synthesis or cross-review that mislabels the agent key of a record it cites is now
  corrected instead of being thrown away, when the cited `source_id` belongs to exactly one supplied
  record. On PR 28812 the synthesizer wrote `cross-review-pi` and `cross-review-claude` for records
  owned by claude, codex, and pi; the bounded repair then produced the right pairs and was rejected,
  because the repair may not change `source_refs`, and the run paid a 45-minute retry for a name it
  could derive. An unknown or ambiguous `source_id` is still a provenance failure and is never
  guessed at, and the correction is logged.
- The three contracts no longer describe `source_refs` with a placeholder that reads like a value.
  `{"agent":"cross-review-agent-key",...}` invited exactly the output above; the contracts now say to
  copy `record_ref` verbatim and name the failure mode explicitly.
- `--rerun-final --force` works again on a structured run. It resolves the run's own
  `work/<timestamp>/` directory, which only the manifest used to supply and which a forced rerun
  deliberately skips, and it loads the canonical cross-review sidecars the synthesis needs; without
  them the run died on an unbound variable before reaching the model. This is the only way to
  re-synthesise a run whose pull-request head has moved.
- `packaging/release-dry-run.sh` is executable, like the other packaging scripts.

## [1.17.0] - 2026-09-15

### Added

- A structured run now publishes its actionable findings as
  `<review-id>-<timestamp>-fix-list.json` beside the final report, so the copy meant for a fixing
  agent travels with the review. `reporting.findings_export` selects `confirmed` (the default),
  `uncertain`, `all`, or `off`; a run whose final contract is `markdown` publishes nothing. The
  manifest records the file as `artifacts.final_findings_export`.
- `review-pr findings <pull-request>` prints the actionable part of a finished structured review as
  JSON, for an agent that will do the fixing: id, classification, severity, category, exact anchor,
  title, claim, failure scenario, recommendation, and verification limitations. Confirmed findings
  are exported by default; `--include uncertain` and `--include all` widen the set, and `--run`
  selects a specific run instead of the freshest one. It reads only the canonical final sidecar, so
  it needs no agent CLI, no network, and no Git work, and it writes nothing.

### Changed

- Reviewers now receive the annotations a check run produced, not only its conclusion. A red
  `phpstan` or `phpunit` told a reviewer nothing beyond the fact that it was red, so the contracts
  made it a verification limitation; the annotations carry the file, the line, and the message, which
  a reviewer can use as evidence. At most 20 annotations per check and 60 per run are attached, each
  message trimmed to 200 characters, and a failure to read them never fails the review.
- The check state is read again before the final synthesis. Checks still running when the reviewers
  started often settle during the review, and the finalizer reasoned about the opening snapshot: on a
  real run `phpstan` and `phpunit` were both still `in_progress` and were reported to it as pending.
  The snapshot the reviewers saw is preserved as published; only the finalizer's view is refreshed,
  and an artifact-only rerun does not read GitHub at all.
- A run's working files now live in `work/<timestamp>/` instead of directly in `work/`, so repeated
  runs of the same pull request stay separable. File names are unchanged, and the final and
  comparison reports still sit at the top of the review directory. Runs made before this keep their
  flat layout: resume and `--rerun-final` recognise it from the manifest's own location and continue
  to work on them.

### Fixed

- `install.sh` now writes each file beside its destination and renames it into place instead of
  rewriting it where it stands. A review that is running reads its own script incrementally, so an
  in-place rewrite feeds the live process new bytes at offsets computed for the old ones, which is
  how an installer can corrupt a review already in flight. A rename leaves that process on the inode
  it opened.
- Every canonical record supplied to a reviewer now carries `record_ref`, the exact
  `{"agent":…,"source_id":…}` object to copy when citing it. A final synthesis failed on PR 28958
  because it cited two Pi cross-review records under the Claude agent key: the record's own id and
  the agent key that owns it were in different places, and the record's `primary_provenance` shows a
  different agent right next to the id. The contracts now say to copy `record_ref` verbatim and never
  to assemble the pair.

## [1.16.1] - 2026-09-14

### Fixed

- The three `ndjson-v1` contracts now state that the terminal `complete` record's
  `verification_limitations` and `positive_evidence` are arrays of plain strings, and show how one
  positive-evidence string carries a file and a symbol. The primary contract asked for an entry
  "naming the file and symbol" without giving the element type, and a reviewer answered with
  `{"file":...,"symbol":...,"note":...}` objects; validation rejected the stream, the bounded repair
  could not rewrite it because that would change content, and the whole review failed after two
  attempts. The same contracts now also spell out that `title`, `claim`, `recommendation`, and
  `category` are non-empty strings, and the cross-review contract lists those shapes instead of
  referring to shapes it never shows.

## [1.16.0] - 2026-09-13

### Added

- Final synthesis now honours `execution.retry.max_attempts` like the other phases, so a failed
  synthesis no longer ends the run while every primary and cross-review report is already finished.
  An attempt is repeated only when the synthesizer produced something: the decision reads the
  attempt's own output and usage record instead of matching each CLI's error text, so an attempt
  that never got a turn, from a usage limit, an authentication failure, or a timeout, ends the run
  as before. An attempt stopped by the output token limit is not repeated either, because an
  identical request meets the same ceiling. Failed attempts keep attempt-scoped diagnostics.
- A cross-review whose `ndjson-v1` stream stops before it answers every required source ref is now
  continued instead of retried from scratch. The orchestrator keeps the records the interrupted
  pass produced, asks the same agent for the unanswered refs alone, and validates the merged stream
  as one review; a continuation that rewrites, reorders, or drops a kept finding is rejected and the
  ordinary retry takes over. The continuation replaces the bounded schema repair for that attempt,
  so an attempt still costs at most two agent invocations. Failures that a no-tools repair can fix,
  including a stream that answered every ref and only omitted `complete`, keep using the repair.

### Fixed

- A Codex answer spread over several agent messages is joined in order before validation instead
  of keeping only the last message, which made a structured cross-review fail with
  `stream.no_complete` and missing source refs although every record had been produced. The raw
  Codex event stream is now preserved as `*-events.jsonl` next to the other failure diagnostics,
  as it already was for Pi.
- The Pi tool-guard extension is located from the script directory captured at startup. When
  `review-pr` was started through a relative path, the lookup ran after the orchestrator had
  changed into the review checkout and failed with "review-pr-pi-guard.js was not found", which
  aborted a resume before its first agent finished.
- The three `ndjson-v1` contracts now state that the whole stream must arrive in one single final
  message, because a hosted CLI ends the turn on the first message and a record sent as a first
  instalment left the review with `stream.no_complete` and missing source refs.
- A REJECTED or UNCERTAIN cross-review or final record may carry a `null` or empty
  `recommendation`, like `failure_scenario` already could; Codex rejected a claim with
  `recommendation: null` and the strict rule failed an otherwise complete cross-review twice.
- Cleanup terminates the whole process tree of every running agent subshell, so an orchestrator
  that exits early no longer leaves `codex`, `claude`, or `pi` processes running and spending quota.

## [1.15.0] - 2026-09-12

### Added

- GitHub Actions workflow `.github/workflows/ci.yml`: syntax check, `shellcheck`, private-data audit,
  and the full test suite on Linux (macOS for `main` and manual runs), then a package build with
  checksum and content verification uploaded as an artifact.
- `packaging/build-package.sh` honours `REVIEW_PR_DIST_DIR` for the output directory, and
  `packaging/package-manifest.txt` documents the exact archive contents; the test suite builds the
  archive into a temporary directory, verifies its checksum, modes, and manifest, and installs from
  the extracted archive.
- `agents.pi.effort` and, for a Pi synthesizer, `finalization.effort` now map to Pi's `--thinking`
  level (`off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`), so a reasoning model's thinking
  budget can be bounded instead of exhausting the output token limit; an empty value keeps the model
  default. Previously any non-empty Pi effort was silently accepted and ignored.
- `packaging/release-dry-run.sh` performs the release-candidate dry run (build, checksum, manifest,
  isolated install, launcher smoke test, optional `contract-test` per agent, uninstall with and
  without `--purge-config`) and writes a machine-readable checklist without private paths.

### Changed

- README documents the security model (agents run as the user without a shell, disposable review
  checkout, untrusted PR context, allow-listed measurements, bounded Pi tool calls, read-only GitHub
  access), rollback and backup restoration, report compatibility across releases, a team overlay
  guide without company content, and troubleshooting for agent timeouts, tool-call loops, output
  token limits, and invalid structured output.

### Fixed

- Run manifests record the measured review-thread state as `review_threads: {status, reason}`, and a
  resumed run or an artifact-only `--rerun-final` restores it from the source manifest (or, for older
  runs, from the GitHub context snapshot) instead of reporting `github_review_threads_unavailable:
  not_fetched` in the final diagnostics.
- The jq programs compile on jq 1.6 again, the documented minimum: `label` and `end` are reserved
  words there, so object keys, field accesses, and a `--arg` variable using those names were
  rewritten; CI runs the full suite against a pinned jq 1.6 release.
- Measurement redaction no longer depends on the GNU-only `sed` `I` flag, so credential
  assignments are redacted on macOS as well; the test suite itself is portable to BSD `sed`, `wc`,
  and the `/private` temporary directory, and CI runs it on `macos-latest`.

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
