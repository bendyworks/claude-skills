---
name: targeted-specs
description: Select and run just the specs a feature branch plausibly affects, instead of the full local suite -- scope recomputed statelessly from the branch diff every run, blast-radius escalation triggers that force declaring "this branch needs a full run" instead, whole-project lint always, the subset announced with per-file rationale before anything runs, complete output captured to a uniquely-named /tmp log, and a fixed verdict line other skills can key off. Rails/RSpec-first. Use ONLY when the user explicitly invokes it ("run targeted specs", "targeted spec run", "targeted verification") or the project's CLAUDE.md or rules files declare Targeted Spec Verification Mode. Never trigger on generic "run the specs" / "run the suite" phrasings -- without the declared mode or an explicit ask, a project's standing rule is the full suite.
---

# targeted-specs -- run the specs a branch plausibly affects

Given a feature branch, prove a targeted clean-and-green without a full local
suite run: compute the branch's scope from its diff, select the specs that
cover it, run whole-project lint plus that subset, and report a machine-keyable
verdict. CI owns the full suite. This skill fills the "project's suite-runner
skill" slot for targeted mode; when a full run is what's needed, it says so
and steps aside.

The skill is **stateless**: every run recomputes scope from the current diff,
so it self-heals when a story's scope expands mid-flight. There is no
maintained list to go stale. When relatedness is uncertain, **err inclusive**.

## Step 0 -- Confirm targeted mode is authorized

Targeted runs are a *sanctioned alternative* to the full local gate, not a
default. Before anything else, confirm one of:

- The project's CLAUDE.md or rules files declare Targeted Spec Verification
  Mode (or equivalent wording naming this skill or a targeted/subset spec
  policy), or
- The user explicitly invoked this skill or asked for a targeted run in so
  many words.

Neither true? Recommend the full gate instead -- the project's suite-runner
skill if it provides one, otherwise the project's full lint+test command --
and stop. Do not subset specs on a project whose standing rule is the full
suite.

## Step 1 -- Compute the branch's scope (stateless)

Run `git fetch origin` first -- never reason about trunk state from a stale
remote-tracking ref. Then:

1. **Resolve the trunk.** Use `git symbolic-ref --short refs/remotes/origin/HEAD`
   (e.g. `origin/main`, `origin/master`). If unset, fall back to
   `gh repo view --json defaultBranchRef` or ask the user. Never hardcode
   `origin/main`.
2. **Stacked branches diff against their base.** If this branch was cut from
   another feature branch rather than the trunk, diff against that base
   instead, or the parent branch's changes inflate scope and force spurious
   escalations.
3. **Collect changed files.** `git diff --name-status <trunk>...HEAD` plus
   `git status --porcelain`. Staged, unstaged, and untracked changes all
   count toward scope.

Status semantics:

- An untracked or added spec file joins the subset.
- A **deleted** spec file (`D`) is itself a finding: announce it as removed
  coverage.
- Renames (`R`) map by the new path.

This procedure is git-only; on another version control system, adapt the
scope computation or fall back to the full gate.

## Step 2 -- Check escalation triggers before selecting anything

Some files' blast radius cannot be predicted, and you cannot select the specs
you did not predict. If the diff touches any of these, **stop**: run nothing
(not even lint), emit the `ESCALATED` verdict line (below) naming the
trigger, and recommend the full gate -- the project's suite-runner skill if
it provides one, otherwise the project's full lint+test command.

- Spec infrastructure: `spec/spec_helper.rb`, `spec/rails_helper.rb`,
  `spec/support/**` (matchers, shared examples, shared contexts, helpers)
- Factories: `spec/factories/**`
- Fixtures: `spec/fixtures/**`, `test/fixtures/**`
- Dependencies: `Gemfile`, `Gemfile.lock`
- Database shape: `db/migrate/**`, `db/schema.rb`, `db/structure.sql`
- Application-wide config: `config/application.rb`,
  `config/environments/**`, `config/initializers/**`
- Application-wide base classes: `ApplicationRecord`,
  `ApplicationController`, `ApplicationJob`, `ApplicationMailer`,
  `ApplicationHelper`, `ApplicationPolicy`
- Layouts: `app/views/layouts/**`
- Wholesale `config/locales/**` restructuring (files moved, split, or
  renamed). Individual key edits map normally in Step 3.
- Concerns with wide reach: escalate when a changed concern is included by
  any `Application*` base class, or when
  `grep -rl "include <ConcernName>" app lib` finds more than ~3 includers.
  Fewer includers: map their specs in Step 3 instead.
- Routes: a `config/routes.rb` hunk that **modifies or deletes** existing
  route lines escalates. Add-only hunks map normally in Step 3.
- Callbacks with wide reach: see the callback rule in Step 3 -- high fan-in
  escalates.

The trigger list is where the full-run habit's value is preserved; do not
talk yourself past it because the subset "looks fine".

## Step 3 -- Map changed files to specs

First set aside files with **no spec impact** -- documentation (`*.md`),
`.github/**`, images and fonts, generated build outputs
(`app/assets/builds/**`, `public/packs/**`, and kin). Announce them under
that label so the "gap" label below stays meaningful.

Then map each remaining changed file (Rails/RSpec heuristics):

- `app/models/foo.rb` -> `spec/models/foo_spec.rb`, plus the specs of models
  that include a changed concern
- Controllers -> matching controller/request specs, plus system specs
  covering the affected routes
- Views, JavaScript, and helpers -> related system specs and helper specs
- Shared view partials -> grep the partial's basename to find the templates
  and controllers that render it, then map those to their system specs
- Services, jobs, mailers, serializers, decorators -> their own specs plus
  the specs of callers found by grep
- Policies -> the policy spec plus the resource's request/system specs
- Individual locale-key changes -> grep the changed keys for the specs and
  views that use them
- `lib/` -> matching lib specs; `lib/tasks/**/*.rake` -> task specs, or a
  named gap when none exist
- Add-only route changes -> request specs for the touched controllers
- VCR cassettes -> grep the cassette name for the specs that replay it
- `app/admin/**` (ActiveAdmin and kin) -> matching admin request/feature
  specs
- Changed spec files themselves -> always included

**Callback rule.** When the diff adds or modifies an ActiveRecord callback,
or a `touch:`, `counter_cache`, or `dependent:` option, the damage can reach
specs that never call the model -- they merely build it through factories or
associations. Measure fan-in by grepping the factories and association
declarations that reference the model. Low fan-in: include those specs.
High fan-in (the model is built everywhere): escalate per Step 2.

**Ripple depth is one hop.** Follow callers found by grep once; do not chase
transitive chains. Err inclusive at that one hop.

**Gaps.** A changed code file with no matching spec and no ripple hits is a
named gap in the announcement -- the developer decides whether that gap is
acceptable for this branch.

## Step 4 -- Include manual pins

A story can pin specs that must run every time regardless of the diff. Look
in the story's plan file (`.claude/plans/<branch-slug>.md`) for this exact
heading:

```markdown
## Always-run specs
```

Each entry is one spec path or glob per `- ` bullet. Include every entry in
the subset. No plan file, or no such section: note "no pins" in the
announcement and move on.

## Step 5 -- Apply the size ceiling

Compare the selected spec-file count (pins included) against the suite's
total spec-file count (`git ls-files 'spec/**/*_spec.rb' | wc -l`) -- file
counts, not example counts. When the subset exceeds roughly a third of the
suite, or the rationale column is mostly speculative ripple guesses, a full
run is cheaper than a subset this wide: emit the `ESCALATED` verdict line
with `subset too wide` as the trigger and stop.

## Step 6 -- Announce the subset, then proceed

Print the selection before running anything:

- Each changed file with its selected specs and a one-line rationale
- Named gaps (changed code with no covering spec found)
- Deleted-spec findings, if any
- The "no spec impact" files, summarized in one line
- Pins included (or "no pins")
- The count: "N of M spec files selected"

Then proceed immediately into Step 7. The announcement is the veto window --
the developer can interrupt to veto or widen the subset -- but there is no
blocking prompt, so unattended callers work.

## Step 7 -- Run lint, then the subset

1. **Whole-project lint first, always.** Lint is fast; only specs get
   subsetted. Run the project's linter over the whole project, exactly as
   the full gate would.
2. **One spec invocation over the whole subset**, output captured completely
   to a uniquely-named log, e.g.:

   ```bash
   bundle exec rspec <selected files> 2>&1 | tee /tmp/targeted-specs-$(date +%s).log
   ```

   Adapt the command to the project's usual spec runner (container, binstub,
   parallel runner). Grep the captured log for details; never re-run the
   subset just to re-read its output.

   An **empty subset** (every changed file landed in the "no spec impact"
   bucket and there are no pins) skips the spec invocation entirely: lint
   alone decides, and the verdict line reports 0 spec files.
3. Summarize pass/fail per the log and end with the verdict line.

## The verdict line -- a load-bearing contract

The run's final message MUST end with exactly one of these lines, verbatim
in shape, with the placeholders filled:

```
Targeted run: ESCALATED -- full suite required (trigger: <trigger>)
Targeted run: PASSED -- <n> spec files (<p> pinned), 0 failures, log: <path>
Targeted run: FAILED -- <n> spec files (<p> pinned), <f> failures, log: <path>
```

Calling skills key off these lines to decide what happens next (hand off to
the full gate, proceed to ship steps, or stop on failures), so their shape
is not editable in passing -- treat any change as a breaking change for the
skills that consume them.

## Other stacks (reduced depth)

Outside Rails/RSpec the same skeleton applies with generic mapping: compute
the diff the same way; escalate on shared test infrastructure, dependency
manifests, and schema-shaped files; map source files to tests by naming
convention plus an import/require grep for callers; announce with rationale;
run the whole-project linter; capture one test invocation to a /tmp log; end
with the same verdict lines.

## Rules already covered elsewhere -- do NOT restate them

A failing subset is owned exactly like a failing full suite -- the
clean-and-green guidance owns that rule and everything downstream of it
(zero warnings, no suppression comments, done means fully passing). This
skill only decides *which specs run locally*; it never lowers the bar for
what passing means, and CI's full run is owned like any red gate.

## Project-specific overrides

Projects may place a `.claude/skills/targeted-specs/SKILL.md` in their own
repo to override this global default (different plans directory, different
spec layout, different escalation list). When such a file exists, it wins
entirely -- do not try to merge.
