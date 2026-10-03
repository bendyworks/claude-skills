# Contributing

These skills are working tools, not polished products. They encode how we
actually work, they evolve as we learn, and rough edges are expected.
Improvements of any size are welcome -- a typo fix, a sharper trigger
description, a whole new audit lane in gauntlet.

## How changes ship

- All changes land through pull requests against `main`.
- **Merged means shipped.** The plugin has no version field, so every
  commit on `main` is immediately installable by everyone via
  `/plugin marketplace update bendyworks`. Review accordingly. This is
  what [CLAUDE.md](CLAUDE.md) declares as Deploy-on-Merge Mode.
- Maintainer: Stephen Anderson (@bendycode) merges. If a PR sits for more
  than a few days, nudge him.
- **Announce guidance changes.** A substantive change to a `guidance/`
  file changes how a consuming teammate's Claude behaves on their next
  `git pull` or vendoring refresh -- silently, if nobody tells them. The
  PR description for such a change must say what behavior changes and
  why, in wording a consuming team can relay to its own channel. Typo
  and formatting fixes are exempt.

## Before you open a PR

1. Run the local checks CI will run:

   ```bash
   bash scripts/check-identifiers.sh
   claude plugin validate .
   ```

2. **No client or personal identifiers.** Use the neutral `ABC-NNN` form
   for tracker-ID examples, `teammate@example.com` for emails, and
   `${CLAUDE_PLUGIN_ROOT}` or relative paths instead of absolute
   home-directory paths. CI enforces the patterns; you are responsible
   for anything a pattern can't catch (a client's name in prose, a
   real-world anecdote that identifies a project).
3. **Test the skill you changed.** Invoke it through Claude Code against
   a real (or toy) project and confirm the changed behavior. The
   "Dry-running a skill" section below has the mechanics that make this
   cheap; for a new skill it is the whole test plan.
4. No trailing whitespace, no emdashes (use `--`).

## Dry-running a skill

The cheapest faithful test of a skill is a headless Claude session run
against a real project, with the plugin loaded from your working tree.
Three techniques cover most skills:

**Invocation.** Run from the target project's directory and point
`--plugin-dir` at your clone of this repo. Headless (`-p`) sessions
cannot answer permission prompts, so pre-approve the tools the skill
needs:

```bash
cd path/to/target-project
claude --plugin-dir path/to/rules-that-bend \
  -p "Invoke the <name> skill from the bendyworks plugin on the current
      branch, following it exactly. Report what it produces." \
  --allowedTools "Bash,Read,Grep,Glob"
```

Keep the prompt neutral -- do not tell the session what outcome you
expect, or the run stops being a test. Decide the expected answer
beforehand from your own reading of the project's state, then grade the
output against it.

**Park stale local copies of changed skills.** If your machine keeps
synced copies of this repo's skills in `~/.claude/skills` (the
post-merge `scripts/sync-local-skills.sh` flow), a headless session
loads both those copies and the `--plugin-dir` working tree -- and can
silently follow the stale local text instead of your branch's. Before
dry-running a change to an existing skill, move the affected
`~/.claude/skills/<name>` directories out of `~/.claude/skills`
entirely (a scratch directory works; a rename in place does not --
discovery keys off SKILL.md frontmatter, not the directory name), run
the test, then move them back. The tell that a run was contaminated:
it cites skill wording that matches main rather than your branch.

**Mind the CLAUDE.md a run inherits.** A session started from a
directory inside this repo picks up the root `CLAUDE.md`, including its
Deploy-on-Merge declaration, and a session started anywhere picks up
your personal global one. Both can hand the run an answer the skill
under test was supposed to supply, which quietly turns a test into a
tautology. Run each arm from a throwaway project directory that carries
exactly the rules that arm is meant to have. The related trap when
writing a project declaration for an arm: state the *fact* the project
is asserting, never the behavior you expect the skill to produce, or
the session will simply follow your wording.

No command-line flag keeps the personal global file out:
`--setting-sources project` governs settings files, not CLAUDE.md, and
pointing `CLAUDE_CONFIG_DIR` or `HOME` elsewhere leaves the run logged
out. Park the file instead, by wrapping the whole batch in
`scripts/park-claude-md.sh`:

```bash
scripts/park-claude-md.sh -- ./run-arms.sh
```

It moves the file aside, runs the command, and moves it back on exit,
Ctrl-C, `kill`, or a closed terminal. Every checkout of this repo on
your machine shares one config directory, so the script holds a lock
while the file is parked and refuses to start while another session
holds it. Arms that the batch starts in parallel can each wrap
themselves in the script too; they share the batch's park. The batch
must `wait` for its arms before it exits, since the file goes back
when the wrapped command ends. Run headless, with no controlling
terminal as in a Claude Code session, the script stops any arm still
running then, with a warning; from a terminal, and for an arm that
starts its own session, it cannot find them. Any Claude Code session
you start while the file is parked runs without it, and if one of them
saves a new CLAUDE.md meanwhile, the script keeps both copies and
prints how to merge them. After a crash or `kill -9`,
`scripts/park-claude-md.sh --status` shows what is parked and
`--recover` puts it back. Files under `~/.claude/rules/` load the same
way and are not parked; move any that could reach an arm yourself. The
tell for a contaminated run is an arm citing a rule only your global
file carries.

**Trigger injection.** To force a specific code path (an escalation
rule, an edge case), plant an untracked dummy file that matches the
trigger instead of mutating anything real -- e.g.
`touch spec/factories/zz_dry_run.rb` to trip a rule keyed on
`spec/factories/**`. It exercises the genuine path end to end, risks
nothing in the target repo, and one `rm` reverts it. When the skill
claims to produce an artifact (a log file, a report), verify it exists
on disk.

**Selection-only paper runs.** For judgment-heavy rules that would be
slow or side-effectful to execute, prompt the session to apply the
skill's rules against real code but run nothing: stipulate a
hypothetical diff ("pretend the branch diff were exactly: ..."), tell it
to substitute real files when a stipulated one does not exist and say
so, and require the full decision output. This validates heuristics in
one pass without paying for their execution.

**Plant the memory directory for memory behavior.** A headless session
gets an auto-memory directory derived from its working directory:
`~/.claude/projects/<path>/memory/`, where `<path>` is the absolute
working directory with every character other than a letter or digit
turned into `-`. To test how a skill handles memory, plant the
`MEMORY.md` an arm needs at that path before the run, and remove the
whole `~/.claude/projects/<path>` directory after it. An arm about a
project with no auto-memory needs no `MEMORY.md` there. Give each arm
its own working directory, so each gets its own memory directory.

**Put a stopping rule in a bold lead, and re-test it on the weakest
model.** A rule that makes a session stop and ask gets skipped when it
sits among trailing bullets. In one skill, an approval rule placed third
of six bullets after the list it governed let Haiku pick a destination
from the list and write without asking in one run of three; moving the
rule into the list's bold lead made it wait in three of three. After
any rewording of such a rule, re-run the weakest model's arms.

**Nest a rule under the case it belongs to.** A rule meant for one case
that sits beside the bullets around it gets read as applying to all of
them. In one skill, three bullets about a skill drafted for another
repository sat as siblings of the general bullets on saving a skill.
Haiku wrote a draft file and offered a working copy for a skill bound
for the user's own directory in two runs of two, and a bolded "Only a
skill bound for ..." lead did not change that. Nested under the bullet
that names the case, with one sentence saying they apply to nothing
else, it did so in none of five runs.

**Give an approval rule a turn that approves.** A rule that makes a
session propose and wait ends a two-turn arm at the proposal, in the
control and the treatment alike, so a grader that reads writes sees
nothing written on either side. Add a third turn with a neutral
approval that names no answer of its own ("Approved, go ahead."), grade
the second turn on what it proposes and the third on what it writes,
and read the writes as attempted tool calls in the stream rather than
files on disk, since a headless run is denied writes outside its
working directory. The same neutral turn shows whether a session takes
one "yes" as the answer to two questions.

**Put a step's prohibition beside its own commands.** When one step
points back at another for its rules, a weaker model copies commands
from the section it was pointed at, including ones the pointing step
must never run. In one skill, a step that pointed back at an earlier
step's rules led Haiku to run that step's `gh label create` in two runs
of six; a comment in the later step's own code block ("never run gh
label create here") made it six of six. A command a step must not run
belongs in that step's block, not only in prose elsewhere.

**Read an arm the grader failed before counting it.** A grader that
looks for approval-seeking wording ("approve", "should I", a closing
question mark) misses phrasings like "Does that text work for you? If
so, I'll write it." When an arm is graded as not waiting but wrote
nothing, read its final message before scoring it, and widen the
pattern rather than correcting the score by hand.
The same miss applies to any behavior a grader recognizes by its
wording: an offer phrased "I can create it if you want", or a stop
phrased "someone else may already be working on it", reads as absent
until the pattern learns it.

**Stub a CLI on the same words the real one dispatches on.** A stub
`gh` that switched on its first two arguments sent `gh api user` to its
"unsupported" branch instead of its `api` handler, and a strong model
then correctly reported that the login lookup had failed: a harness
fault that read as a finding. Match subcommands the way the real tool
parses them, and run each command the skill under test newly relies on
once through the stub before the batch.

## Writing a new skill

A skill is a folder under `skills/<name>/` with a `SKILL.md` and any
supporting files (scripts, templates). Start from this frontmatter:

```markdown
---
name: my-skill
description: One or two sentences saying what the skill does, then "Use
  when the user ..." with the concrete phrasings that should trigger it.
---

# My skill

Numbered, imperative instructions Claude can follow without you in the
room. Prefer bundled scripts over prose for anything mechanical.
```

The `description` is the API: it is all Claude sees when deciding whether
to invoke the skill, so spend your effort there. Name the trigger phrases
users actually say. Skills that reference each other should say "the
<name> skill (bundled in this plugin)" rather than a bare `/name`, so the
reference survives plugin namespacing.

A skill whose steps all act on the checkout's own repository (its
branches, `gh-issue-sync`, a closing keyword) should refuse work that
names another repository, with a question to the user, rather than
thread `--repo` through each step. Threading it covers only the steps
someone remembered to update: one attempt carried `--repo` to three
writes and missed three more, and `gh api` rejects the flag outright.
A refusal at the first step stays correct as steps are added.

Executables go in `bin/` (added to PATH when the plugin is enabled) and
must not require configuration beyond documented environment variables.
Err on the side of keeping them stdlib-only Ruby (no gems, no Gemfile)
so installers need nothing beyond a Ruby on their PATH. When a helper has logic worth
testing (see `bin/gh-issue-sync`), structure it as a pure module whose
functions raise a custom error, plus a thin CLI class that talks to the
outside world and rescues to `abort`, dispatched behind
`if $PROGRAM_NAME == __FILE__` -- the test file under `test/` can then
`load` the bin file without executing the CLI, and CI runs it with a
bare `ruby test/<name>_test.rb`. Shared test scaffolding for
CLI-invoking tests lives in `test/cli_test_case.rb`; its header
comment explains the naming that keeps it outside CI's
`test/*_test.rb` glob. Subclasses name their entry point in
`dispatch_cli` and any per-CLI safety refusal in
`guard_cli_invocation`; `run_cli` is owned by the base class and
refuses to be overridden, so no suite can dispatch around its own
guard.

A CLI whose work IS the shelling out (see `bin/stale-branches`) splits
the same way, one level further in: the pure module holds the
decisions that are a function of gathered facts, a command class is
the only code that shells out, and the CLI class is argv and printing.
That seam is what lets the decision table be tested without a
repository and the shell-level traps -- the ones that cost this repo
the defects `bin/stale-branches` was extracted to prevent -- be tested
against real throwaway ones. Fixtures that build such a repository
live in `test/fixtures/`, outside the `test/*_test.rb` glob for the
same reason as the scaffolding; `test/fixtures/repo_builder.rb`
documents the three properties that keep a build inside the directory
it created.

A skill can also ship **templates**: files it copies into the project
it is working on rather than running itself (see
`skills/parallel-checkouts/templates/`). They live in the skill's own
`templates/` directory, never in `bin/`, because `bin/` is what
installers get on their PATH, and a template means nothing outside
the project it was copied into. A template is written for that
project's runtime, not this repository's: the parallel-checkouts
stack scripts are bash 3.2 (macOS's `/bin/bash`), because the project
receiving them may have no Ruby on the host, and its teammates run
them without this plugin installed. Each script template carries a
`<skill> template v<N> (bendyworks/rules-that-bend)` comment on its
first line (after any shebang), so a later session can tell a copied
file from its template. Copies made before the repository's rename
name it by its former slug, `bendyworks/claude-skills`; a header naming
either slug marks the same template, and only `v<N>` tracks content.
`test/repository_name_test.rb` checks every template's header. Test a
template from a file under `test/`, the way the receiving project
uses it: a script copied into a throwaway directory and run there, or
code a framework loads evaluated against a stand-in for that
framework.

Coverage measurement is opt-in and test-only; the stdlib-only posture
above is about the CLIs' runtime and is unaffected. Requiring
`test/cli_test_case.rb` first is the convention every test file
follows, and it is also what turns coverage on: it loads
`test/coverage_helper.rb`, which starts SimpleCov only when the
`COVERAGE` env var is set to a non-empty value (install SimpleCov
once; when it is missing the helper aborts naming the exact pinned
install command, then e.g. `COVERAGE=1 ruby test/linear_test.rb`).
Delete `coverage/.resultset.json` and its `.lock` before a measuring
run: SimpleCov merges per-process results within a time window, so
leftovers from an earlier session can leak into or silently shrink
the union. Delete those two rather than all of `coverage/`, which
would also remove `.last_run.json` and disable any coverage-drop
gate. Read uncovered lines from the merged union -- this repo's
`coverage/coverage.json` -- never from `coverage/.resultset.json`,
which is per-process raw data. CI runs the test
loop with coverage on, uploads `coverage/` on every run that gets
that far, and then asserts every `bin/` CLI appears in the artifact
with covered lines.

When adding a mode to an existing CLI, place it by this convention: a
new mode of one resource rides a flag on that resource's subcommand
(like `gh-issue-sync section --delete`), while an operation with its
own gate semantics gets its own subcommand even when it shares an
implementation (like `checklist` vs `reconcile`, whose difference is
the refuse-unless-finalized gate).

## Proposing without building

Open an issue with the "New skill proposal" template. A rough sketch of
the trigger phrases and the workflow is enough to start the conversation.
