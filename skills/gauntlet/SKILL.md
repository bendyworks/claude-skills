---
name: gauntlet
description: Multi-front quality pass on a feature branch whose business requirements are already met -- specs pass, lint passes, the user-facing feature works. Runs `/code-review` first, then dispatches parallel sub-agents to audit cruft, idioms, test quality, validation-bypass risk, and security, then consolidates findings into one punch list, fixes every clear-cut finding without stopping, and batches the judgment calls into one set of questions at the end. Tuned for Ruby on Rails projects (RSpec, RuboCop, Pundit); runs elsewhere with reduced audit depth. Use when the user says "run the gauntlet", "gauntlet this branch", "gauntlet this PR", "challenge the branch", "stress test this branch", "is this ready to merge?", "audit this branch", or invokes the gauntlet skill.
---

# Run the gauntlet

The user has finished a story to the satisfaction of clients and end-users. Specs pass. Lint passes. The feature works. *Now* they want to improve the code itself -- catch cruft, sharpen idioms, surface false-positive tests, plug validation holes, look for accidental authorization gaps -- before the PR leaves draft.

This skill orchestrates that pass in five phases:

1. **Phase 0** -- pre-flight and scope
2. **Phase 1** -- finding sources: `/code-review`, then parallel sub-agent audits (report-only)
3. **Phase 2** -- consolidate findings into one ranked punch list
4. **Phase 3** -- sort every finding, fix the clear-cut ones without asking, and batch the rest as questions at the end (see "When Phase 3 fixes")
5. **Phase 4** -- a fresh-eyes "find the bug" sub-agent on the final state; runs on its own when its triggers fire and is offered otherwise (see "When Phase 4 runs")

The main agent's job is orchestration: dispatch sub-agents in parallel, merge their reports, dedupe, rank by severity, present a single coherent list. Sub-agents do not make code changes. Fixes happen in Phase 3 with full cross-cutting context.

## Standing pre-approval -- do NOT prompt for component steps

When the user invokes the gauntlet, every component step and nested skill call is **already approved**. Run them all without pausing to ask permission: `/code-review`, `/security-review` (the security agent), every Phase 1 sub-agent dispatch, the suite gate whenever "When the suite gate runs" says to run it, and the Phase 4 "find the bug" pass whenever "When Phase 4 runs" says it runs. Never stop to ask "is it ok to run /code-review?" or "should I dispatch the audit agents?" -- just proceed through the phases.

Fixing is covered too: every finding "When Phase 3 fixes" sorts into its fix bucket is fixed without asking, in Phase 3 and in Phase 4 alike. The run's one built-in stop is the question batch at its end, which carries the judgment calls that subsection names, the Phase 4 offer when "When Phase 4 runs" says to ask rather than run, and whether to file the follow-up drafts. **Filing an issue, or posting anything else to a tracker, is never pre-approved:** it publishes text under the developer's name, so it always waits for the batch. Everything else runs unprompted.

## Rules already covered elsewhere -- do NOT restate

Do not pad sub-agent prompts with rules that already live in:

- **The project's CLAUDE.md files** -- testing philosophy, lint policy, commit conventions, and whatever house rules the project declares.
- **`/code-review` (built-in)** -- generic reuse / quality / efficiency findings. That is its lane: don't ask sub-agents to duplicate it by hunting duplicated code or readability micro-improvements.
- **`/security-review` (built-in)** -- a general security review of pending changes. The gauntlet's security agent should *invoke* `/security-review` and incorporate its findings, not redo that work from scratch.

Each sub-agent should *read* the relevant CLAUDE.md(s) to inform its findings. The briefs below assume that and don't re-list the rules.

---

## Phase 0 -- Pre-flight and scope

### Step 1 -- Confirm preconditions

Before starting, verify:

1. **We're on a feature branch.** Not `main` / `master`. Run `git branch --show-current`.
2. **The branch has changes vs main.** Run `git diff main...HEAD --stat`. If the diff is empty, ask the user what they actually want to gauntlet.
3. **Specs and lint already pass.** Decided by "When the suite gate runs" below, not here. That subsection is the one home of the decision, and it governs the Phase 3 tail's run by the same list.
4. **Working tree is clean, or close to it.** Uncommitted scratch changes muddle the diff. Ask the user to stash or commit first.

Settle preconditions 1, 2, and 4 before entering the gate list, so a ten-minute suite is never spent on a tree the developer is about to stash. If any of the three is off, surface it and pause -- don't push forward on a broken assumption. Those three stay asks because their remedies are the user's to choose: what to gauntlet instead when the diff is empty, whether to stash or commit a dirty tree. Precondition 3's remedy is mechanical -- the gate either has a result already or can produce one -- so it is decided rather than asked, and a run that lands on branch 1 or branch 4 of that list stops or ends there on its own terms.

**Non-git version control:** the commands throughout this skill assume git. If the user works in another VCS (e.g. Jujutsu colocated with git), ask them for the change range ("which revisions are the current work?") and translate the `git diff main...HEAD` commands to that tool's equivalents -- the phases themselves don't change. Don't make the user volunteer this; ask when the working-copy state looks unfamiliar.

**Cost expectations:** a full run is deliberately thorough and correspondingly token-hungry -- /code-review plus five parallel audits, plus a Phase 4 agent when its triggers fire, can consume a noticeable slice of a subscription session's budget. Before starting Phase 1, tell the user the planned agent count so they can trim (Step 3), choose light mode, or exclude Phase 4 -- an opt-out given any time before the Phase 3 tail is honored, and this is the natural moment for it. Say too that Phase 3 fixes clear-cut findings without stopping. These choices are the run's only cost levers: once findings exist, cost is never a reason to leave one unfixed (see "When Phase 3 fixes"). Phase 0 can only predict Phase 4: all three triggers are measured at the Phase 3 tail, and two cannot be known earlier (see "When Phase 4 runs"). On a large diff, say explicitly that this will be an expensive pass and that Phase 4 is expected to run on its own.

### When the suite gate runs

The gauntlet decides the project's lint+test gate at three points: Phase 0 Step 1, to establish the branch is green before auditing it; the Phase 3 tail, to establish the fixes did not break it; and again after any Phase 4 fix, which re-enters as the tail. **All three are decided here, by this one list.** Step 1's precondition 3, the standing pre-approval, and the Phase 3 tail defer to it rather than restating any of it. Step 4's patch coverage is not a fourth gate run: it reads the facts this list records, and runs a coverage suite of its own only when they say no usable one exists.

**Evidence, and when it goes stale.** Evidence is either a gate result -- a run that reported pass or fail -- or a statement the developer volunteered, in this session and about this branch, that specs and lint pass. The skill's own premise that specs and lint pass is not that statement: it describes when to reach for the gauntlet, not a claim about the tree in front of you, so invoking the gauntlet is never itself the evidence. Both kinds are evidence about *the tree as it stood when they were obtained*, and both go stale by the same test, whichever branch is reading them.

A piece of evidence holds until any file in the working tree is added, changed, or deleted -- tracked or not, staged or not, matching what the targeted-specs skill counts toward scope. Files the project ignores never count: a gate run writes coverage artifacts, logs, and scratch output as it goes, and counting those would make every result stale the instant it was produced. Three things are not changes for this purpose: committing content that has already been tested; an experiment's edit (Phase 3's sort, step 2) that was restored to exactly its prior content before anything else ran; and writing the bookkeeping files this skill and the plan-issue skill maintain (the record file under `.claude/gauntlets/`, a plan file under `.claude/plans/`), which no suite exercises. Judge that by whether a suite or a project check could read the file, never by its extension -- in a repository whose deliverable is prose, a shipped markdown file is production code.

Evidence from another session, or from a sibling worktree, is not evidence here until it has been re-checked against the current tree by that same test.

**Where to read it.** At Phase 0 Step 1 the evidence is what this session has seen. At the Phase 3 tail and afterwards, read it from the record file's header rather than from memory -- Phase 1 is the run's most compaction-prone stretch, and the header is written precisely so the decision survives it.

**How to announce.** Evaluate the branch fully *before* announcing it: the searches and mode checks a branch's condition depends on all happen first, and only the announcement has to precede the action. Then announce in a sentence of its own, in one of these forms, and **substitute every `<...>` -- a placeholder that reaches the transcript verbatim is a bug, not an announcement**:

    Suite gate: stop (red evidence: <the failing run and what it reported>)
    Suite gate: proceeding past red at the user's direction (<the failing run and what it reported>)
    Suite gate: satisfied (green evidence: <the run this session observed, or the developer's statement and when it was given>)
    Suite gate: running (<full|targeted>; <no evidence|escalated: the targeted verdict established nothing>)
    Suite gate: cannot run (<no runner found|user declined the run>)
    Suite gate: unestablished, continuing at the user's direction (declined the run)
    Suite gate: could not complete (<what the runner reported>)

**What ending means depends on which of the three call sites entered the list.** At Phase 0 Step 1 it is literal: nothing has happened yet, so the gauntlet ends and the developer starts it again once the branch is green or a gate exists. **At the Phase 3 tail, and at the re-entry after a Phase 4 fix, branch 1 and branch 4 end the gate, never the run.** The tail still owes this gauntlet a Phase 4 decision, and a run that reaches Phase 1 and ends without one is a bug by the rule in "When Phase 4 runs". So there: announce as written, record the gate's state in the record file's header, skip the patch-coverage re-check that would have nothing to read, and continue to the tail's remaining steps. Say plainly in the closing message that the post-fix gate did not pass or did not run, so "ready for human review" cannot be read as "verified green".

Then work the list top to bottom and act on the first branch that matches.

1. **Red evidence in hand -- stop.** A gate result on this tree that failed, whoever obtained it, subject to the staleness test above: a failure the Phase 3 fixes have since invalidated is not evidence, and the list is re-entered without it. Announce `Suite gate: stop`, and stop: the gauntlet is a *quality* pass, not a *rescue* pass, and a red branch gets fixed first, separately. This branch is ordered ahead of branch 2 so a red result cannot be laundered into a green one -- branch 2 accepts a statement the developer volunteers, and "gauntlet it anyway" is such a statement. Accepting a red suite is a call only the developer gets to make, so honor an explicit one: announce the `proceeding past red` form instead, so a transcript never reads as stopped when the run continued, and record **both halves** in the record file's header -- the failure and the waiver, as in `gate: failed; user override: proceed`. Recording only the failure loses the waiver by construction: the tail is required to read the header rather than memory, so a header holding a bare failure sends the tail straight back to this branch to stop on a failure the developer already waived. Before stopping here, check the header for a recorded override covering this same failure; where one stands, this branch does not fire.
2. **Green evidence in hand -- satisfied, run nothing.** Announce `Suite gate: satisfied`, naming in the parenthetical which kind of evidence it was.

   A targeted verdict is evidence only where the project declares Targeted Spec Verification Mode, and only on the terms the targeted-specs skill sets: read that skill's opening boundaries, which say when a subset may stand in for a caller at all, together with its verdict contract, which says what a given verdict establishes. Do not reinterpret either here. What it does not establish as green is not evidence, and falls through to branch 3.
3. **No evidence, and the gate can run -- announce it, run it, then re-enter this list with the result.** Announce `Suite gate: running` and run it in the same message, without waiting for permission: the standing pre-approval covers this run, and waiting for an acknowledgement that may never come is the stall this list exists to remove. Say `escalated` in the parenthetical when a targeted verdict sent the run here, so two attempts on one branch are told apart.

   Which gate: the targeted-specs skill (bundled in this plugin) where the project declares the mode, since that skill confirms the declaration itself and ends with a verdict line; the project's full lint+test gate otherwise.

   **A targeted verdict that left the precondition unestablished goes to the full gate, however it arrived** -- as a fall-through from branch 2, or as this branch's own result. A second targeted run selects from the same diff and returns the same verdict, which is a loop.

   When the run finishes, state its facts on their own line before doing anything else, so they are greppable later and survive a compaction:

       Suite gate result: <full|targeted>; <passed|failed|escalated>; coverage <on|off>; resultset <deleted first|not deleted>; log <path>

   `escalated` is for a targeted attempt that ended ESCALATED rather than reporting pass or fail. Write that line before escalating, so the header shows a targeted run was tried and abandoned; the full gate that follows writes its own.

   Then take the result back to the top of this list, where a pass lands on branch 2 and a failure on branch 1.
4. **The gate cannot run -- announce it and end.** Only two things put a run here, and both are evidence you can state: no runner could be found, or the developer has said not to run it. "No runner" means all five of these came back empty -- a suite-runner skill at any level, the project's CLAUDE.md or rules files, a Rakefile default task, `package.json` scripts, and the test job in the project's continuous-integration config. Four of the five are checkable with a command; the first is not -- it is whatever suite-runner skills this session can actually see -- so say which you checked and how. Anything short of that is branch 3; an unverified hunch that the gate is unrunnable is not an entry form.

   Announce `Suite gate: cannot run`, say what would unblock it, and end. **Do not make this turn on whether a user is watching.** A session has no reliable test for its own attendance, so a rule that asks when someone is present and ends otherwise fires its asking branch precisely when a session wrongly believes it can tell -- the one case where it is wrong. Ending and naming the blocker serves both worlds: a developer who is watching reads it as the question it is and acts at once, and a run nobody is watching leaves the reason in the transcript rather than waiting for an answer that will never come.

   One exception, for the `user declined the run` condition only: the developer who declines the gate has not declined the audits. Announce the `unestablished, continuing` form, record it in the header, and continue the run from wherever the gate was entered -- the run goes on without the precondition, exactly as branch 1's override does. `no runner found` at Phase 0 Step 1 ends the run, because nothing has happened yet and the developer can start it again once a gate exists.

**A run that never returns a verdict is not a result.** A gate that dies before reporting pass or fail -- a database container that is down, a missing binstub, a runner that exits non-zero with no summary -- is neither branch 1 nor branch 2, and re-entering at branch 3 would re-run the same broken command forever. Announce `Suite gate: could not complete`, quoting what the runner reported. It then takes branch 4's `no runner found` continuation, not the declined one: at Phase 0 Step 1 the run ends, and at the tail the gate ends while the run continues. The developer did not choose to skip this gate, so nothing here is waived -- the environment is simply not able to answer, and that is worth stopping a not-yet-started pass over. Fixing the environment is the developer's, not this pass's.

**Running the gate.** Invoke a suite-runner skill or script if one is available, at any level -- project, user, or one a plugin ships -- instead of hand-typing the command. Otherwise run the project's own gate command once, teeing all stdout and stderr to a uniquely-named log under /tmp, and answer every follow-up by grepping that log; never re-run a suite just to re-read its output. That is the clean-and-green guidance's capture rule, where a team imports it, and a suite-runner skill or script that already captures this way satisfies it as-is -- do not add a second capture on top.

Where the project measures coverage at all, run the gate **with coverage on**, having first deleted the coverage tool's raw resultset and its lock (for SimpleCov, `coverage/.resultset.json` and `coverage/.resultset.json.lock`), so Step 4 can reuse the artifacts instead of paying for a second run. Step 4 explains why a resultset from a run not started that way cannot be trusted. On a project with no coverage tooling this paragraph does not apply, and Step 4 says so too.

**What to record.** The Phase 0 decision is made at Step 1, one step before the record file exists, so carry the branch and the `Suite gate result:` facts to Step 2, which says what the header holds. The tail's decision is appended to that header when it is made. Step 2 says which facts the header holds and why; do not restate the list here.

### Step 2 -- Snapshot the scope

Capture once, near the top of the run, and refer back to it:

```bash
git diff main...HEAD --stat
git diff main...HEAD --name-only
git diff main...HEAD
```

Note the categories present: Ruby code, specs, JS, SCSS, migrations, Gemfile / Gemfile.lock, config. This drives which Phase 1 agents are worth spawning.

Also write a **risk note**: name, by file, anything in the diff that falls in the four categories the Phase 4 `risky by scope` trigger reads -- a migration; authorization (a policy, a `before_action` auth filter, a role column, a route-scope change); money or units; an external integration (an outbound HTTP client or API-client gem, a webhook controller, VCR cassettes or WebMock stubs in the spec diff) -- or "none" explicitly. The file list alone cannot answer this; reading the diff can, so do it here while the diff is in front of you.

Then create the record file, `.claude/gauntlets/<branch-name>-gauntlet.md`, with a header carrying the risk note, what the Step 1 suite gate established, and any Phase 4 opt-out or request the user has already given. Record the gate as facts rather than as a branch label -- which gate ran or what evidence stood in for it, whether it passed, whether coverage was on, whether the run began from a deleted resultset, and the log path -- because Step 4's question is not which branch decided the run but whether a trustworthy coverage-bearing run happened against this tree. Phase 2 adds the findings below that header later. It is created this early because Phase 1 is the most compaction-prone stretch of the run, and a note that lives only in context until then is lost before anything wrote it down. Write the file directly -- do NOT pre-run `mkdir -p .claude/gauntlets` as a precaution; that probe is wasted overhead on every run after the first. Only if the write fails because the directory does not exist (a project that has never run the gauntlet) do you `mkdir -p .claude/gauntlets` once and retry. Phase 2 explains the filename.

### Step 3 -- Decide which Phase 1 agents to spawn

The default set is five: `cruft`, `rspec-quality`, `idioms`, `data-validation`, `security`. Trim based on the scope snapshot:

| Agent             | Skip when ...                                                                          |
|-------------------|----------------------------------------------------------------------------------------|
| `cruft`           | Never -- always runs.                                                                  |
| `rspec-quality`   | No spec files changed.                                                                 |
| `idioms`          | Only config / docs / migrations changed (no app code).                                 |
| `data-validation` | No app code, services, controllers, jobs, or migrations changed.                       |
| `security`        | Only test / config changed AND no new routes, policies, params, or external endpoints. |

If the user explicitly asked to skip something ("gauntlet but skip security") or focus on one thing ("just the rspec audit"), honor that.

### Step 4 -- Patch coverage on the added lines

Reviewers and CI (Codecov, etc.) flag **patch coverage**: lines *added by this branch* that no test executes. The Phase 1 audits reason about test *quality*, not line coverage, so an untested new line slips past them -- catch it here mechanically instead of in a review round-trip.

The record file's header says what the Phase 0 gate established, and nothing edits the tree between Step 1 and this step. On a project with no coverage tooling at all, this step has nothing to measure: say so and move on, rather than inventing an invocation. Everywhere else, the record file's header decides, and it reports exactly one of four states.

   - **A run that passed, with coverage on** -- reuse its artifacts.
   - **The gate satisfied from evidence rather than run, or a run without coverage** -- run the suite (or the relevant suites) with coverage on now and capture the artifacts.
   - **A run that failed**, which branch 1's override path allows -- neither reuse nor re-run. A failed run's resultset stops at the failure, so every spec that never executed reads as uncovered and intersecting against it manufactures a flood of false findings. Report that patch coverage could not be measured against a red gate.
   - **The gate unestablished because the developer declined it** -- report patch coverage as not measured, exactly as for a red gate. Do not read this as "satisfied from evidence" and run a coverage suite: the developer declined that suite, and the decline covers this step too. **Either way, the resultset must come from a run that started with `coverage/.resultset.json` (and its `.lock`) deleted** -- raw results are keyed by a per-process command name, so an entry an earlier session left under a name this run does not reproduce is never overwritten and merges into the union as stale coverage, hiding a genuinely uncovered added line. That applies to the reuse path too, and merging with the age check disabled (below) removes the last thing that would have dropped such an entry: a header that does not say the run began from a deleted resultset is not a promise of a clean start, so unless the deletion is recorded or you performed it yourself, delete and re-run rather than trust the artifacts. Delete those two files specifically rather than all of `coverage/` -- removing `.last_run.json` silently disables a project's `maximum_coverage_drop` gate, which passes unconditionally when no last run exists. Subset coverage is not ground truth: one-hop selection can miss a spec that covers an added line transitively, so treat a subset-uncovered added line as a candidate to verify (or defer to CI's full-run patch coverage) rather than an automatic finding. Then intersect added lines with uncovered lines:

1. **Added lines** -- `git diff main...HEAD --unified=0` (or parse `+` hunks) gives the new-file line numbers per file.
2. **Uncovered lines** -- from the coverage run's machine-readable output. **Always read the tool's *merged* artifact, never per-process raw data.** A suite that forks (parallel runners, per-file loops, sharded CI) writes one raw entry per process, and a file that process never loaded is either absent from that entry or, when the tool simulates tracked-but-unloaded files, present as all zeros. Read one entry directly and an entire untouched file looks uncovered.
   - Ruby / SimpleCov -> `coverage/coverage.json` is already merged, but it exists only when the project enables the JSON formatter (SimpleCov adds it only when `CC_TEST_REPORTER_ID` is set), so usually only `coverage/.resultset.json` is on disk -- and that one is raw. Merge it with `SimpleCov::ResultMerger.merge_results`, which takes an explicit path and an `ignore_timeout:` keyword and returns a `SimpleCov::Result` without re-running anything. Take `missed_lines` off the resulting files rather than selecting on a hit count of `0`: `:nocov:`-skipped lines carry a `0` too, and only `missed_lines` excludes them. Two cautions on the reading process. It inherits SimpleCov's own defaults, including autoloading any `.simplecov` found by walking up from the root -- in a project whose `.simplecov` calls `SimpleCov.start`, merely requiring simplecov begins a coverage run that writes its own junk entry at exit, so require `simplecov/no_defaults` (or set `external_at_exit`) when reading. And SimpleCov filters out every file stored outside its root, which defaults to the working directory -- a resultset a container wrote with `/app/...` paths yields an empty file list, so treat "no files at all" as a wrong-root error rather than a clean report.
   - `ignore_timeout` matters: SimpleCov's merge silently drops entries older than `merge_timeout` (default 600s), so a slow per-file loop loses its earliest processes. **`coverage.json` is subject to that same timeout** -- it is generated through the merge path with no override -- so on a slow suite it can under-report. Reading it directly: hit count `0` is uncovered, `null` is non-executable, and the string `"ignored"` marks a `:nocov:` skip. **Do not sum hit counts across entries by hand.** SimpleCov merges nil-wins (`nil + 0 = nil`), and a simulated entry marks far more lines executable than a real measurement does, so summing reports non-executable lines as uncovered -- on a two-process run of this plugin's own suite, summing claimed 189 uncovered lines for `bin/gh-issue-sync` alone against a true 53.
   - JS / Istanbul -> read the merged artifact, not per-worker output. Jest and Vitest merge their workers themselves; a raw nyc setup writes per-process `.nyc_output/*.json` and needs `nyc report` first. Which files appear depends on the configured reporters -- `lcov.info` and `cobertura-coverage.xml` are each written only when that reporter is enabled -- so check what the project actually emits rather than assuming (`<line number=.. hits="0"/>` / `DA:line,0`). Note JS coverage is usually a **separate** run from the Ruby suite (e.g. an `npm test` invocation with coverage on) -- run it too when the diff touches JS, or the JS patch stays invisible.
   - Other stacks: `coverage.py` (`coverage combine` first **only** if the run used parallel mode -- it errors when there is nothing to combine, and consumes its inputs unless given `--keep` -- then `coverage json`), `go test -coverprofile`, etc.
3. **Intersect.** Added line numbers the merged artifact reports as uncovered are the uncovered patch. Two matching hazards, both of which fail toward a silent clean result: file paths are relative to different roots in the two inputs (the diff's are relative to the repository root, a coverage artifact's to whatever root the coverage tool used -- these differ whenever the app is not at the repository root, and cobertura/lcov paths may be absolute), and the diff's base branch is whatever this project actually uses, not necessarily `main`. **A changed source file that appears nowhere in the coverage artifact is not "covered" -- it is unmeasured.** That is the normal shape of a brand-new file no test loads, which is the highest-value patch-coverage finding there is; report every added line in it rather than skipping the file. Use the diff's `+` side for line numbers.

Surface each uncovered added line as a **should-fix** coverage finding in the Phase 2 list (`file:line -- added by this branch, no test exercises it`). Beware two traps the categorical agents won't: a *partial* branch (line runs but one side of a conditional never does -- still a gap a reviewer will flag; branch data exists only when the suite ran with branch coverage enabled, and reading it back requires branch coverage enabled in the reading process too, so an empty branch list means "not measured", not "no gaps"), and a new line landing inside a method that had **no** prior coverage (easy to miss because the whole method reads as "unchanged-looking"). If a line is genuinely not worth testing (defensive guard, logging), say so explicitly rather than leaving it unexplained.

The Phase 3 tail decides whether a further coverage run happens at all, per "When the suite gate runs"; when one does, it starts from a deleted resultset like any other, because the fixes have shifted line numbers and results carried over from the pre-fix run describe a file that no longer exists.

### Light mode for small PRs

If the diff is under ~50 lines across fewer than ~5 files, sub-agent dispatch overhead probably isn't worth it. Tell the user, then run the same checks (including `/code-review`) **sequentially in the main agent** without spawning sub-agents. Keep the same Phase 2 / Phase 3 structure (consolidate, then sort and fix, then batch the questions). Light mode does not change the Phase 4 decision; see "When Phase 4 runs".

---

## Phase 1 -- Finding sources (report-only)

First invoke `/code-review` (the built-in) in the main agent and capture its findings for Phase 2. It is a peer finding source: it reports a findings list and makes no edits and no commits, exactly like the sub-agents below. (If a future version of the built-in applies edits instead, commit those edits, re-snapshot the diff, and redo the Step 4 patch-coverage check before dispatching.)

Then dispatch the chosen agents **in a single message** so they run concurrently. Use `Agent` with `subagent_type: "general-purpose"` unless an agent's brief calls for a different one.

Every sub-agent prompt MUST tell the agent to:

1. Read the relevant CLAUDE.md(s) for project context and rules.
2. Run `git diff main...HEAD` (and `--name-only` / `--stat` as helpful) to see exactly what changed.
3. **Report only -- do not make code changes.** Fixes happen in Phase 3.
4. Return findings in this exact format:

   ```markdown
   ## Findings

   ### must-fix
   - `path/to/file.rb:42` -- one-line description of the issue. Suggested fix: brief sketch.

   ### should-fix
   - `path/to/file.rb:107` -- ...

   ### nit
   - `path/to/file.rb:88` -- ...

   ## Considered but ruled out
   - One-line note on anything that looked suspicious but checked out, so the main agent doesn't re-investigate.
   ```

5. Stay in lane. The cruft agent doesn't comment on RSpec patterns; the rspec-quality agent doesn't comment on security; etc.

The agent-specific briefs below are starting templates. Adjust wording to match the project's stack and conventions.

### Agent: cruft

> Audit the current branch for cruft -- code or dependencies added on this branch that aren't actually used. Focus areas:
>
> - Methods, classes, or modules defined in this branch but never called.
> - Gems added to the Gemfile but not `require`d or referenced.
> - Version constraints on Gemfile entries. Flag any new version pin (and any pre-existing pin touched by this branch) so the user can confirm it is deliberate -- unpinned entries are the default preference.
> - Requires / imports added but unused.
> - Routes, partials, helpers, JS modules, or assets added but unreferenced.
>
> Read `CLAUDE.md` first. Run `git diff main...HEAD --name-only` and `git diff main...HEAD` to scope. Report only -- do not edit. Use the standard findings format.

### Agent: rspec-quality

> Audit the spec files changed on this branch for RSpec quality. Focus areas:
>
> - **False positives**: tests that pass for the wrong reason. Read the `describe` / `context` / `it` strings and verify the test actually exercises the behavior they describe (vs. passing because a stub returned the right value, or because a setup callback happened to satisfy the assertion).
> - **Arrange-Act-Assert discipline**: tests where setup leaks into the `it` block, or where logic moved out of a `before` block ended up *inside* the `it` block. Both are smells.
> - **Single-assertion via `match_array`**: where two paired `expect(...).to include(...)` + `not_to include(...)` calls could be one `match_array`.
> - **Modern RSpec syntax**: prefer `is_expected.to` over the deprecated `should`; prefer `aggregate_failures` over exempting the file from `RSpec/ExampleLength` in `.rubocop_todo.yml`.
> - **Factory opportunities**: 5+ lines of setup that could become a new factory trait, even if used only once, when the trait improves readability.
> - **Mock-heavy tests** that would benefit from real factory objects. Preference order: real factory > `instance_double` > `double` > `nil`.
> - **Hand-rolled validation/association specs**: multi-line specs asserting a validation or association that shoulda-matchers expresses as a one-liner (`it { should validate_presence_of(:email) }`), when the project uses shoulda-matchers.
> - **External HTTP in specs**: new specs whose code path talks to an external service should go through the project's stubbing layer (VCR cassettes / WebMock), never live HTTP. Also flag overly-broad stubs (`stub_request(:any, /./)`-style) that hide request-shape regressions.
> - **Unused `let!` variables** that should be `_`-prefixed.
> - **Coverage gaps from removed or altered specs**: diff the spec files against `main` and check whether any deleted or weakened tests left a real coverage gap. If a spec was deleted, was the behavior re-covered elsewhere -- and was the removal intentional?
>
> Read `CLAUDE.md` first and honor any spec-writing conventions it declares. Run `git diff main...HEAD -- 'spec/**/*'` to scope. Report only.

### Agent: idioms

> Audit this branch for Rails / ActiveRecord / Capybara / CI idioms that `/code-review` is least likely to catch. /code-review already covers general readability and duplication; you focus on idioms specific to *this* stack and *this* project's preferences. RSpec structure and quality belong to the rspec-quality agent -- do not comment on them here. Focus areas:
>
> - **Scopes vs. inline queries.** Where a named scope would dramatically improve readability or reuse, suggest one.
> - **Associations vs. IDs.** Code passing `foo_id` instead of `foo`, or querying through ID where the association is already loaded or available.
> - **Callbacks under suspicion.** Flag any newly-added `before_save` / `after_create` / etc. and ask whether overriding a method, using a service object, or handling it explicitly in the controller would be clearer. Check CLAUDE.md for the project's stance on callbacks. Do not flag callbacks that already existed on `main`.
> - **N+1 queries.** New queries or loops over associations missing `includes` / `preload` / `eager_load`. If the project runs Bullet, check its test-log output for the changed code paths.
> - **Rails built-ins reinvented.** `counter_cache`, `enum`, `delegate`, `alias_attribute`, `has_secure_password`, `dependent: ...`, and similar -- if the branch hand-rolls something Rails offers, flag it.
> - **Symbols over enum hash literals.** Enum values should be set and queried via symbols (`status: :active`), not raw integers or the enum hash, outside the rare raw-SQL case.
> - **Capybara idioms**: `have_current_path` with a regex over hard-coded strings when pagination or params can vary; `js: true` for any UI-behavior test when the project prioritizes integration tests.
>
> Read `CLAUDE.md` first. Run `git diff main...HEAD` to scope. Report only.

### Agent: data-validation

> Audit this branch for ActiveRecord methods that bypass model validations, and for database constraint vs. validation alignment. Focus on the diff, not the entire codebase.
>
> **Why this lane exists:** Rails' validations and callbacks only run on the normal save path, and ActiveRecord offers **more than a dozen** write methods that skip one or both -- with no naming convention separating the safe calls from the bypassing ones. `update` validates but `update_attribute` doesn't; `toggle!`'s bang means "saves immediately, skipping validation" while `update!`'s bang means the opposite. That makes this an extremely easy error for careful people to commit, which is why it gets a dedicated audit lane. A single bypassing call can plant rows the rest of the app assumes are impossible, and the failure surfaces much later, far from the write that caused it. The DB-constraint checks below are the same risk from the other side: a `null: false` or foreign key without a matching model validation doesn't prevent bad input, it just converts it from a friendly form error into a 500 at write time. Judge each finding by that lens: how far from this line would the damage surface, and who hits it first -- a validation message, an exception tracker, or a customer?
>
> **High-priority bypass methods to grep for in the diff:**
> - `update_column`, `update_columns`, `update_all`
> - `insert_all`, `upsert_all`
> - `increment_counter`, `decrement_counter`, `update_counters`
> - `toggle!`, `touch`, `delete_all`
> - Raw SQL: `connection.execute`, `ActiveRecord::Base.connection.exec_query`
>
> **For each instance:**
> 1. File path, line number, and short snippet for context.
> 2. Risk assessment: HIGH / MEDIUM / LOW. Controllers handling user input = HIGH. Admin / internal tools = MEDIUM. Migrations, seeds, one-shot data repair = LOW. Background jobs processing external data = MEDIUM.
> 3. Intent analysis: does this look intentional (explanatory comment, descriptive method name, batch-performance reason)?
> 4. Safer alternative if the bypass looks unintentional.
>
> **Also audit constraint/validation alignment** (defer to CLAUDE.md where the project declares its own rules):
> - New migration columns with `null: false` -- is there a corresponding model `validates :col, presence: true` (or `inclusion: { in: [true, false] }` for booleans)? Is the form input `required: true`?
> - New `foreign_key: true` references -- does the parent's `has_many` / `has_one` declare an explicit `dependent: ...` strategy?
> - New `_cents` columns -- does the model use `monetize :col` from money-rails rather than plain numericality validations?
> - New integer / float / decimal columns -- are bounds enforced (numericality validations + HTML5 min/max on inputs)?
> - If the project uses strong_migrations, flag any `safety_assured` block added by this branch without a stated reason -- it is the validation-bypass pattern in migration form.
>
> Read `CLAUDE.md` first. Report only.

### Agent: security

> Audit this branch for security gaps introduced by the change.
>
> **Step 1**: invoke the built-in `/security-review` skill, which already runs a general security review of pending changes. Incorporate its findings into your report.
>
> **Step 2**: go beyond it with branch-specific checks the general reviewer is less likely to catch:
>
> - **Authorization.** For each new or modified controller action, is there a Pundit policy method (or the project's authorization equivalent, e.g. a CanCanCan ability)? Is it actually invoked (`authorize @record` / `authorize!`)? Are roles that should not have access (e.g. a customer-level role) excluded by the policy?
> - **New routes** -- does each new route fall under the right scope (admin? authenticated?)? Is anything accidentally public? If the project uses rack-attack, should a new public or unauthenticated endpoint be rate-limited?
> - **Strong params.** Are any new attributes accepted via mass assignment that should not be (status fields, ownership IDs, role flags)?
> - **Search allowlists.** New Ransack (or similar user-driven search) usage needs explicit attribute/association allowlists -- an unallowlisted search surface lets users filter on fields they should never see.
> - **Cross-tenant data leaks.** If the change introduces a new query, can a user of one tenant, account, or organization hit it for another's data?
> - **Authentication bypass.** Any new endpoints that should require login but don't?
>
> Read `CLAUDE.md` first. Report only -- do not write fix code. The user wants to see all findings before triaging.

---

## Phase 2 -- Consolidate findings

When all sub-agents return, the main agent assembles **one** punch list:

0. **Fold in the /code-review findings and the Step 4 patch-coverage findings** alongside the sub-agent findings before deduping -- they belong in the same list and the same sorting. Map /code-review's findings onto the severity bands by their stated severity or impact; a finding that carries neither clearly defaults to should-fix.
1. **Dedupe -- the only thing Phase 2 drops.** Same `file:line` flagged by multiple agents = one entry, listing both reasons. Whether a finding is in scope, or right at all, is Phase 3's call, so every other entry reaches it.
2. **Sort by severity first, then by file.** `must-fix` block at the top, then `should-fix`, then `nit`.
3. **Cross-reference.** When one agent's "considered but ruled out" covers another agent's finding, note both on the entry rather than dropping either: Phase 3 settles the disagreement with evidence (see "When Phase 3 fixes"). (/code-review reports findings only -- it has no "Considered but ruled out" section to cross-reference.)
4. **Persist.** Add the consolidated list to the record file Step 2 created (`.claude/gauntlets/<branch-name>-gauntlet.md`), below its header, so it survives a `/clear`, context compaction, or session resume. Write it even when the list is empty -- a zero-findings run still reaches the Phase 3 tail, and its Phase 4 decision line lands in this file. The `-gauntlet` suffix is mandatory: plan files under `.claude/plans/` often share the same slug-based basenames, and the harness permission prompt shows only the basename, so the suffix is what lets the user tell a gauntlet write from a plan write at approval time. This is a local working file -- suggest the user gitignore `.claude/gauntlets/` if it isn't already.
5. **Count, and keep going.** Note the counts ("12 findings: 2 must-fix, 6 should-fix, 4 nit") for the report, and go straight on to Phase 3 in the same turn. The list reaches the user in the batch at the end of the run; a message showing it on its own would end the turn and stall the run here.

---

## Phase 3 -- Sort, fix, and batch the questions

### When Phase 3 fixes

**The default is fix. A finding leaves the fix bucket only on one of the grounds below; severity, time, and tokens are never grounds.** A nit is fixed like a must-fix: many developers are exacting about idioms and quality, and a nit in lines the branch already touches is cheaper now than it will ever be again. What a run costs is settled in Phase 0, before any finding exists, and is never a reason to leave one unfixed. This subsection is the one home of what happens to a finding; the overview, the standing pre-approval, Phase 2, and Phase 4 point here.

**Sort.** **Every finding ends in exactly one of four buckets -- none is dropped -- and each is checked against the code before it is sorted.** Read the lines the finding names and the lines its claim rests on: an "unused" method gets a search for its callers, a "bypass" gets the line that bypasses. A finding that looks clear on paper is only clear once that check agrees with it. Then take the finding down this list and put it in the bucket of the first ground that matches, writing the ground next to it. A bucket with its reason is one the developer can overrule in a sentence; a bare one costs a round trip.

1. **Disproved -> `[disproved: <evidence>]`.** The code or a test shows the finding is wrong. State the evidence (`called at app/jobs/x.rb:19`). "Looks pre-existing" and "seems minor" are not disproof.
2. **Audits disagree -> test, then sort again.** When one audit's finding contradicts another's "considered but ruled out", or two findings contradict each other, never pick the more confident report. Settle it with evidence: read the line both depend on, or run a cheap experiment -- usually a mutation, breaking the thing on purpose to see whether a spec fails. Restore every mutated file to exactly its prior content and confirm `git status` and `git diff` match what they showed before the experiment ("When the suite gate runs" says why that keeps its evidence standing). Step 2 has no bucket of its own: evidence against the finding makes it `[disproved: <evidence>]`, evidence for it sends it on to step 4, and evidence that settles nothing makes it `[ask]`.
3. **A judgment the developer owns -> `[ask]`.** Only these: **a design or architecture tradeoff**; **a behavior change a user or stakeholder would notice** beyond what the branch set out to do, such as a changed URL or a different email -- fixing a bug so the branch does what it evidently set out to do is not one; **a new validation or constraint on an existing column**, which rows already in the database may fail; **a performance change** that needs measuring first; **a fix the size rule below sends here**; **an experiment in step 2 that settled nothing**.
4. **Outside the branch -> `[follow-up]`.** The finding sits in a file that is not in Step 2's `--name-only` list and the branch did not introduce it, or it is a refactor of code that predates the branch and would outgrow it. That list is frozen when Step 2 captures it: a fix that edits another file does not bring that file's findings in. Nits in untouched files go into **one** grouped draft, never a draft each. A bug the branch introduced is never follow-up, wherever it shows -- a PR owns the bugs it introduces.
5. **Everything else -> `[fix]`.**

Findings that are one gap seen from two places -- a nil the mailer cannot handle, and the missing validation that lets the nil in -- are sorted together: the same bucket, or an entry saying how the fix to one settles the other.

**Size.** Measure the PR the way the tail's step 2 does, when sorting and again after each fix, and state the latest figure in the batch. A fix whose own lines would carry the measured size past 400 goes to `[ask]`. Once the measured size is past 400 -- from the start, or after the fixes so far -- every remaining fix except a bug the branch introduced goes to `[ask]` as one grouped question naming the size, because a PR past 400 lines should almost always be split. Measure rather than estimate: a running total of guesses is a number nobody checked.

**Record, then fix.** Write every entry's bucket into the record file before fixing anything, as `- [ ] [fix] <entry> -- <ground>`, and likewise `[disproved: <evidence>]`, `[follow-up]`, and `[ask]`. Then fix the `[fix]` bucket without asking:

1. **TDD where applicable.** A behavior fix gets a failing spec first -- write it, watch it fail, then fix and watch it pass. A spec that cannot be made to fail is evidence: re-tag the finding `[disproved: <what the attempt showed>]`, or `[ask]` when the attempt was inconclusive. A pure-refactor fix needs no new spec.
2. **One logical change per commit**, its message about the change itself, never about the gauntlet.
3. **A fix that outgrows its finding** -- a new file, a changed public interface, far more lines than the finding implied -- is reverted and re-tagged `[ask]` with what it turned out to need.
4. **Mark it off with its commit**, `- [x] [fix] ... (<short sha>)`, so overruling any automatic fix later is one revert. Append `(guard rewrite)` when the fix touched a guard as "When Phase 4 runs" defines one: the tail's `risky by fixes` trigger reads these tags, and after a compaction they are the only evidence.

**Follow-up drafts.** Write each follow-up issue's full title and body into the record file under `## Follow-up drafts`. Filing publishes text under the developer's name, so it is never automatic: it is one question in the batch. Once the batch approves, file each draft and write `filed as <ID>` next to it the moment it is filed, checking for that line before filing any draft, so a resumed run never files one twice.

**The batch.** Every question goes in one message at the end of the run, after the tail and the Phase 4 decision (and after Phase 4 itself, when it runs), so a run nobody is watching finishes everything mechanical before it stops. The message lists, in order: the fixed findings with their commits, the follow-up drafts, the disproved findings with their evidence, and then the questions -- each `[ask]` from Phase 3 and Phase 4, whether to file the drafts, and the Phase 4 question when "When Phase 4 runs" says to ask. With no questions, that message is the close-out.

When the answers come: fix each accepted `[ask]` under the same four rules, file the approved drafts, and tag each declined entry `(declined)`. If anything was fixed, re-run step 1 of the tail -- the suite gate -- on the result. An accepted Phase 4 offer dispatches Phase 4 now, on the final state. Then close out per "When Phase 4 runs".

**Opt-out.** When the developer asks to triage the findings themselves ("gauntlet, but let me triage"), append `Phase 3: developer triages` to the record file's header at once. Sort and record as above, then present the sorted list as recommendations and wait for their pick before fixing anything; entries they turn down are tagged `(declined)`. The tail reads the header, never memory -- and the same goes for a Phase 4 opt-out or request given at any point: append it to the header the moment it is given.

### The Phase 3 tail

After the fix bucket is done -- or immediately, when it is empty -- this tail runs on every gauntlet:

1. Decide the gate again by "When the suite gate runs" (Phase 0), which owns this run as much as Phase 0's, including what still counts as evidence here. When Phase 3 changed nothing the staleness test counts, the Phase 0 evidence still stands, the gate lands on its branch 2 -- and the Step 4 artifacts still stand too, so skip to step 2. Otherwise re-run the Step 4 patch-coverage check: the fixes added lines, and those should be covered before the branch leaves draft.
2. Report the PR size in lines changed across files -- insertions plus deletions from `git diff main...HEAD --shortstat`, excluding generated files such as lockfiles, schema dumps, and recorded cassettes -- and whether it is more than 400 lines, the easy-review threshold, or not. This is the number the `large` trigger reads.
3. Decide whether Phase 4 runs, per "When Phase 4 runs" in Phase 4 below: write the record line, then announce and dispatch, ask, or close out, exactly as that subsection says. It owns the triggers and the closing sentence; do not re-derive them here. An ask goes in the batch.
4. Send the batch, per "When Phase 3 fixes".

---

## Phase 4 -- Find the bug

### When Phase 4 runs

Phase 4 is decided, not offered. At the end of Phase 3 the main agent checks the triggers below, writes the decision to the record file, announces it, and acts. **Every gauntlet run that reaches Phase 1 ends with Phase 4 running, offered, or recorded as opted out; such a run ending with none of those is a bug in this skill.** The one exception is a run that never got that far: "When the suite gate runs" can end a run at Phase 0 Step 1, before any audit and before Step 2 has created the record file, and a run with no Phase 1 has no Phase 4 decision to make or record. This subsection is the only home of that rule: the overview, the standing pre-approval, the Phase 0 cost paragraph, the suite-gate subsection, the Phase 3 tail, and the findings section point here rather than restating it.

All three triggers are measured at the end of Phase 3, after the fixes, because two of them cannot be known any earlier:

| Trigger          | Fires when ...                                                                                                                                                                                                                                              |
|------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `large`          | The size report from step 2 of the Phase 3 tail is more than 400 lines; 400 or fewer does not fire.                                                                                                                                                         |
| `risky by scope` | The Step 2 risk note names anything in a risk category (a migration; authorization; money or units; an external integration), or the tail's own `git diff main...HEAD --name-only` shows a file the note does not cover whose path puts it in one (`db/migrate/`, `app/policies/`, a webhook controller, a cassette or stub directory) -- a fix may have added it. |
| `risky by fixes` | Phase 3 fixed any must-fix finding (a must-fix that was not fixed -- disproved, sent to follow-up, still waiting in the batch, or declined -- does not count), or a Phase 3 fix is tagged `(guard rewrite)` in the record file -- a guard as defined next. |

A **guard** is code or prose whose job is to refuse, skip, or stop: something whose failure lets the wrong thing proceed silently rather than produce a visibly wrong answer. In code: a `before_action` filter, a policy method, a validation or database constraint, an early-return guard clause, an idempotency check, a rate limit, a strong-params allowlist, a `rescue` that swallows. In a skill or guidance file: a precondition, a STOP rule, a detection or recognition rule.

Why fixes are a trigger at all: fixes are code too, and they ship without the review the original change got. The suite and coverage re-run after Phase 3, but no judgment pass looks at the fixes unless this trigger fires, and Phase 1 audited the pre-fix state, so it could not have caught a bug the fixes introduced.

**When a trigger clearly fires:** announce in a sentence or two that Phase 4 is running and which trigger fired, then dispatch the sub-agent in the same message. Do not wait for acknowledgement -- the run may be unattended, and a stall at this point is the cost this rule exists to remove. **When no trigger fires, or when unsure:** ask, in the batch at the end of the run (see "When Phase 3 fixes"), and say which case this is -- "none of the Phase 4 triggers fired" when nothing did, or name what you are unsure about ("the second fix may have rewritten a guard: ...") when that is the reason, because the user decides differently in the two cases. Then wait; the answer decides. **A direct request** ("run phase 4", "run it anyway") outranks every rule here. Given at or after the tail -- including after a decline or an opt-out -- it runs at once and appends a further decision line rather than editing an earlier one. Given before the tail, it is a pre-commitment: append it to the record file's header like an opt-out, and dispatch at the tail, on the final state, as with every other run.

**The up-front opt-out.** An opt-out given at any point before the Phase 3 tail ("gauntlet but no phase 4" at invocation, or "skip phase 4" in reply to the cost note) is honored the same way Phase 0 Step 3 honors "gauntlet but skip security": Phase 4 neither runs nor is offered, and the record line says so. An opt-out given after Step 2 wrote the record file is appended to its header at once (Phase 3 says the same); the tail decides from the header, because an opt-out that lives only in memory is one a compaction can erase. One exception: when `risky by fixes` fires after an opt-out, ask anyway, naming the must-fix fix or the guard -- the fixes that created the risk happened after the opt-out was given, so the premise of the opt-out changed. Never auto-run through an opt-out; only a direct request does that.

**The record line.** Before dispatching or asking, append one line to `.claude/gauntlets/<branch-name>-gauntlet.md` (a shell append such as `printf '\n%s\n' '<line>' >> <file>` is fine and needs no prior read; the leading newline keeps the line from gluing onto a file that lacks a trailing one) in exactly one of these forms, so the decision is greppable after the fact:

- `Phase 4 decision: ran (<triggers>)`, naming every trigger from the table that fired, e.g. `ran (risky by fixes: guard rewrite)` or `ran (large; risky by scope: migration)`; a direct request is `ran (user request)`
- `Phase 4 decision: asked (<reason>)`, with the reason the ask named: `asked (none fired)`, `asked (unsure: <what>)`, or `asked (opted out; risky by fixes)` -- followed, once the user answers, by a second appended line, `Phase 4 answer: accepted` or `Phase 4 answer: declined`; two write-once lines, never an in-place edit
- `Phase 4 decision: opted out up front`

Writing it before dispatch means a crash mid-Phase-4 still leaves evidence that the decision was made.

**Closing out.** However Phase 4 ends -- declined, opted out, ran and found nothing, or ran and its findings were sorted and fixed -- the gauntlet closes in its final message: the batch, when it holds no questions, or the message after its answers are acted on. Tell the user the gauntlet is complete and the branch is ready for human review. In the same breath name everything still open, and leave those entries unchecked in the record file: a declined finding, a question not yet answered, a draft not yet filed, a must-fix sent to follow-up, and a fix accepted from the batch after Phase 4 ran, which no review pass has seen. Otherwise "ready for review" reads as "nothing known". That sentence lives here; the Phase 3 tail and the findings section point to it.

**Two things the decision does not change.** Light mode (Phase 0) runs the Phase 1 checks in the main agent, but Phase 4 is always a dispatched agent, and light mode does not alter the triggers: a sub-50-line diff can still carry a migration or a guard rewrite. And the trigger is for the announcement and the record only; the brief below stays as written regardless of why Phase 4 ran ("Dispatch a fresh sub-agent" says why).

### Why this pass is different

The mental shift from Phase 1 is significant: Phase 1 agents look in narrow lanes for *categories* of issues. Phase 4 assumes a real bug exists in this branch's behavior and goes hunting laterally. The adversarial framing ("I'll bet you can't find the bug") is intentional and should be preserved -- it pushes the agent past surface-level review.

### Dispatch a fresh sub-agent

Use `Agent` with `subagent_type: "general-purpose"`. Do NOT pass the Phase 1 reports (including /code-review's) or the consolidated findings file to this agent -- the value is fresh eyes. Anchoring it on prior findings narrows its search.

### Sub-agent brief

> The user is challenging you: **"I'll bet you can't find the bug in our work!"** Take this as a serious adversarial framing -- assume a real bug exists in this branch's changes, and your job is to find it.
>
> This is a fresh-eyes pass. You may notice things the categorical reviewers missed because their lanes were too narrow.
>
> Read `CLAUDE.md` first for project context. Then read the diff (`git diff main...HEAD`), the files it touches, and -- crucially -- the *callers* of any changed methods. Mentally execute the changed code paths for representative inputs and look for:
>
> - **Boundary inputs**: nil, empty string, empty collection, single-item collection, very large collection, negative numbers, zero, max integer.
> - **Wrong field used**: `created_at` vs `updated_at`, `id` vs `external_id`, `name` vs `slug`, `email` vs `username`, `amount` vs `net_amount`.
> - **Unit / money errors**: cents vs dollars, signed vs unsigned, percentage vs fraction, gross vs net.
> - **Time-related bugs**: time-zone confusion, DST boundaries, end-of-day vs start-of-day, leap days.
> - **Inverted boolean logic, off-by-one, wrong comparison operator** (`<` vs `<=`, `&&` vs `||`).
> - **Concurrent or repeated invocations**: race conditions, double-submits, idempotency holes, re-entry of a callback.
> - **Bad data states**: orphaned records, partially completed migrations, inconsistent state across associations.
> - **Cross-tenant / cross-record data leaks** that don't trip explicit authorization checks but leak via query shape (a query missing its tenant / account scope, etc.).
> - **Sibling bugs of the same shape as a fix.** If this branch fixes a bug, is the same bug shape present elsewhere in the codebase that the fix didn't touch?
> - **Cache invalidation gaps**: anything new that writes data an existing cached read won't reflect.
>
> Use the same `## Findings` format as the Phase 1 agents. If you genuinely cannot find a bug after a thorough pass, say so explicitly under "Considered but ruled out" with a one-line summary of where you looked -- so the user knows the time was spent, not skipped.
>
> Report only. The main agent will sort your findings and act on them.

### What to do with the findings

If the agent finds something credible:

1. Append the findings to `.claude/gauntlets/<branch-name>-gauntlet.md` under a new "Phase 4 -- find-the-bug" section, so the persisted record stays complete.
2. Sort them by "When Phase 3 fixes", exactly as Phase 3's findings: a credible bug with an unambiguous fix is fixed without asking, and anything on a judgment ground joins the batch. A bug found here is almost always `must-fix` by nature, and a clear one is not a question.
3. Fix the fix bucket through the same four rules -- write the failing spec that captures the bug, watch it RED, then fix and confirm GREEN. Then re-run step 1 of the Phase 3 tail, which re-enters "When the suite gate runs" as the tail: Phase 4 fixes are unreviewed fixes too. Phase 4 runs once per gauntlet; its own fixes do not trigger a second pass. Then send the batch, and close out per "When Phase 4 runs".

If the agent finds nothing:

1. Relay the agent's "where I looked" summary in the batch. This is signal, not noise -- it tells the user the bug-hunt happened and what it covered.
2. Send the batch, and close out per "When Phase 4 runs".

---

## Project-specific overrides

Projects may place a `.claude/skills/gauntlet/SKILL.md` in their own repo to override this skill -- different sub-agent set, different file conventions, different gate command, different severity bands. When such a file exists, it wins entirely -- do not try to merge.
