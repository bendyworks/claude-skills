---
name: targeted-specs
description: Select and run just the specs a feature branch plausibly affects, instead of the full local suite -- leaning on CI for the full run, escalating to a declared "this branch needs a full run" whenever blast-radius files are touched, announcing the subset for veto before anything runs, and ending with a fixed verdict line other skills can key off. Lint is never subsetted; only specs are. Rails/RSpec-first. Use ONLY when the user explicitly invokes it ("run targeted specs", "targeted spec run", "targeted verification") or the project's CLAUDE.md or rules files declare Targeted Spec Verification Mode. Never trigger on generic "run the specs" / "run the suite" phrasings -- without the declared mode or an explicit ask, a project's standing rule is the full suite.
---

# Targeted specs

Given a feature branch, run a targeted check without a full local suite
run: compute the branch's scope from its diff, select the specs that cover
it, run whole-project lint plus that subset, and report a machine-keyable
verdict. CI owns the full suite.

Two boundaries keep this skill honest:

- **It is not the project's full-suite runner.** Where another skill or
  rule calls for "the project's suite-runner skill" or the full gate,
  this skill substitutes only where the project's declared targeted
  mode says a subset may stand in -- mode-aware callers (the gauntlet's
  gates and plan-issue's suite steps are examples, not a complete
  list) route here on that declaration. On a project with no
  declaration, the full gate still means the full suite. And even
  under a declaration, a developer asking for a full run or for a
  pre-merge final check gets the full suite.
- **It never redefines done.** The project's quality rules own what "done"
  means; a targeted PASSED satisfies a full-run requirement only where the
  project's declared mode says so.

The skill is **stateless**: every run recomputes scope from the current
diff, so it self-heals when a story's scope expands mid-flight. There is
no maintained list to go stale. When relatedness is uncertain, **err
inclusive** -- and when inclusiveness balloons the subset, the size
ceiling (Step 5) converts the run into a full-run declaration rather than
a bloated subset.

## Step 0 -- Confirm targeted mode is authorized

Targeted runs are a *sanctioned alternative* to the full local gate, not a
default. Before anything else, confirm one of:

- The project's CLAUDE.md or rules files declare Targeted Spec
  Verification Mode (or equivalent wording naming this skill or a
  targeted/subset spec policy). The project's declaration is the authority
  on when the mode applies; this skill does not define the mode.
- The user explicitly invoked this skill or asked for a targeted run in so
  many words -- the developer accepting a targeted run for this check.

Neither true? Recommend **the full gate** -- the project's suite-runner
skill if it provides one, otherwise the project's full lint+test command
-- and end with the ESCALATED verdict line (below), trigger
`targeted mode not authorized`. Do not subset specs on a project whose
standing rule is the full suite.

"The full gate" keeps this meaning everywhere below.

## Step 1 -- Compute the branch's scope (stateless)

**Resolve the project remote before anything else -- the remote this
branch's pull request will target.** Every command in this step says
`<remote>` because the name is a per-clone fact, not a constant. `git
remote` (the first command below) lists the candidates; pick from them:
the sole remote in a single-remote clone, whatever it is called;
`upstream` when both `origin` and `upstream` exist (a fork clone --
`origin` is the fork, and a fork's trunk is normally behind, so
measuring against it sweeps other people's already-landed commits into
the diff and forces spurious escalations); `origin` whenever it exists
without `upstream`, however many other remotes (`heroku`, a mirror) sit
alongside it. Two signals beat that name heuristic: a recorded
`gh repo set-default` answer (`git config --get-regexp 'gh-resolved'`,
readable offline) names the true PR target, and the user's word beats
everything. Two shapes remain -- several remotes with none named
`origin`, and no remotes at all -- and neither is resolvable by rule:
ask the user when a user is present; unattended, run nothing and end
with the ESCALATED verdict, trigger `project remote ambiguous`.

Then refresh remote state -- never reason about the trunk from a stale
ref:

```bash
git remote                                           # the candidates; resolve <remote> per the rule above
git remote set-head <remote> --auto                  # refresh <remote>/HEAD; fetch never updates it, so default-branch renames go stale without this
git symbolic-ref --short refs/remotes/<remote>/HEAD  # the trunk, e.g. upstream/main
git fetch <remote> <trunk-branch>                    # scoped fetch; bare branch name (main, not <remote>/main)
```

If `<remote>/HEAD` cannot be resolved, ask the remote directly:
`git ls-remote --symref <remote> HEAD` names the default branch on most
hosts (the same recipe the stale-branches CLI uses); a server that
answers without the symref line counts as failing. Failing that, try
`gh repo view --json defaultBranchRef,nameWithOwner` -- absent a
`gh repo set-default` answer, gh prefers `upstream` over `origin`, so
its answer normally matches the remote picked above; confirm
`nameWithOwner` corresponds to `<remote>` before trusting it -- or ask
the user. Unattended, try both commands before giving up; when neither
answers, end with the ESCALATED verdict, trigger `trunk unresolved`.
Never hardcode either half of `origin/main`: the remote is resolved
above, and the branch is read from the answer, never assumed.

`git remote set-head <remote> --auto` and `ls-remote` need the network;
right after a default-branch rename `set-head` can print a `Not a valid
ref` error and leave the symref stale -- the new branch name is right
there in the error message, so take the trunk from the error (or from
the `ls-remote` fallback) rather than trusting the symref it failed to
update. Offline, proceed with the existing
`<remote>/HEAD` when it exists -- the three-dot diff uses the merge
base, so a briefly stale trunk rarely inflates scope, and the usual
error direction is over-selection and escalation rather than
under-selection (a revert-shaped branch against a stale ref can still
under-select, one more reason Step 6 names the base it measured). When
the resolved remote has no HEAD symref offline -- normal for a
hand-added `upstream`, which only a networked `set-head` or a fetch on
a newer git creates -- do not substitute another remote's HEAD (in a
fork clone that is the fork's stale `origin/HEAD`, the exact
wrong-trunk measurement this rule exists to prevent): end with the
ESCALATED verdict, trigger `trunk unresolved`.

One exception spans both `trunk unresolved` exits above: a stacked
branch (item 1 below) diffs against its local base branch and never
consults the trunk, so when the base is known, proceed against it
instead of escalating.

> **Why the branch sweep resolves this differently.** The
> `stale-branches` CLI bundled in this plugin asks the remote with
> `ls-remote --symref` and reads the remote-tracking `HEAD` only when
> that fails, where this skill repairs and reads that ref directly. The
> difference is deliberate, and it is not that one of them skips the
> network -- both spend a call. It is what each does with the answer. This
> skill writes it into the ref, so the repair outlasts the run and every
> later command can simply read it, and a failure is survivable: a stale
> trunk usually over-selects or escalates spuriously -- annoying, not
> destructive. The sweep reads without writing, and says out loud when it
> had to settle for the cached copy, because a stale default branch in a
> run that deletes branches can destroy work -- and a quiet degradation is
> exactly what would hide that.

All paths in this skill are relative to the **app root** -- the directory
holding the `Gemfile` and `spec/`, which may be a subdirectory of the
repository (a monorepo app). Run every count and grep below from that
root, or the escalation globs and the Step 5 denominator silently miss.

1. **Stacked branches diff against their base.** If this branch was cut
   from another feature branch rather than the trunk, diff against that
   base instead, or the parent branch's changes inflate scope and force
   spurious escalations.
2. **Collect changed files.** `git diff --name-status <trunk>...HEAD` plus
   `git status --porcelain`. Staged, unstaged, and untracked changes all
   count toward scope.

Status semantics:

- An untracked or added spec file joins the subset.
- A **deleted** spec file (`D`) is itself a finding: removed coverage,
  recorded for the Step 6 announcement.
- Renames (`R`) map by the new path.

This procedure is git-only. On another version control system, translate
the scope computation if you can; otherwise end with the ESCALATED verdict
line, trigger `non-git repository`.

## Step 2 -- Check escalation triggers before selecting anything

Some files' blast radius cannot be predicted, and you cannot select the
specs you did not predict. If the diff touches any of these, **stop**: run
nothing (not even lint), emit the ESCALATED verdict line naming the
trigger, and recommend the full gate. Any escalation whose trigger came
from the diff also names, in the summary above the verdict line, the
base the scope was measured against (e.g. `upstream/main`) -- a wrong
project-remote pick forces exactly these spurious escalations, and this
is the only place an unattended caller's transcript can reveal it. The
verdict line's own shape is a contract (below) and never changes.

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
  `ApplicationHelper`, `ApplicationPolicy` -- and any other
  root-of-hierarchy class much of the app inherits from, whatever its name
  (`Api::BaseController`, `BaseService`)
- Layouts: `app/views/layouts/**`
- Locales: wholesale `config/locales/**` restructuring (files moved,
  split, or renamed) escalates; individual key edits map in Step 3
- Routes: a `config/routes.rb` hunk that modifies or deletes existing
  route lines escalates -- as does an add-only hunk that can shadow routes
  it does not touch (a wildcard or catch-all, a broad `match`, or a line
  inserted above existing entries it could intercept). Plain add-only
  hunks map in Step 3 to the touched controllers' request specs
- **Fan-in rule** (concerns and callbacks): when the diff changes a
  concern, or adds or modifies an ActiveRecord callback or a `touch:`,
  `counter_cache`, or `dependent:` option -- damage that reaches specs
  which merely *build* the model through factories or associations --
  measure fan-in with one scoped grep:
  `git grep -lw "include ConcernName" -- app lib` for a concern (the `-w`
  word match keeps `Sortable` from counting `SortableTree`); factory and
  association references to the model for a callback. Escalate when the
  hits are too many to enumerate each one's specs confidently (rough
  guide: more than ~3, or any application-wide base class among them);
  otherwise keep the hit list -- Step 3 maps those files' specs from it
  without re-running the grep.
- **Anything else whose consumers you cannot enumerate.** This list is
  examples of the blast-radius principle, not its boundary: a test-runner
  config (`.rspec`), a JavaScript dependency manifest
  (`package.json`/`yarn.lock` -- which can break every `js: true` spec), a
  `Rakefile`, a Ruby version file. Treat an unlisted file the same way
  when you cannot predict who it reaches.

When the trigger came solely from an uncommitted or untracked file, name
the file in the escalation: incidental local drift (a regenerated
`db/schema.rb`, lockfile churn left over from another branch) can be
cleaned up and the skill re-invoked, while real story work keeps the
escalation.

**Coarse width pre-gate:** before any mapping, set aside the obvious
no-spec-impact files (docs, images, build outputs -- Step 3's ignore
bucket); if the remaining changed code-file count alone already exceeds
the Step 5 ceiling fraction of the suite's spec-file count, escalate now
(trigger `subset too wide`) rather than paying for per-file mapping Step 5
would throw away.

The trigger list is where the full-run habit's value is preserved; do not
talk yourself past it because the subset "looks fine".

## Step 3 -- Map changed files to specs

First set aside files with **no spec impact** -- documentation (`*.md`),
`.github/**`, images and fonts, generated build outputs
(`app/assets/builds/**`, `public/packs/**`, and kin). Record them under
that label for the Step 6 announcement so the "gap" label below stays
meaningful.

**The generic rule:** every remaining changed code file gets, at minimum,
its convention-mirrored spec (`app/anything/foo.rb` ->
`spec/anything/foo_spec.rb`) plus one grep hop for callers, whose specs
join the subset. Only spec paths that exist in the working tree join it --
a mirrored spec deleted alongside its code belongs to the deleted-coverage
finding (Step 1), not to the subset and not to the gap label. The bullets below instantiate that rule for common Rails
shapes; a shape not listed (a GraphQL resolver, an ActionCable channel, a
ViewComponent, a custom validator) follows the same rule -- it does not
skip to the gap label.

Scope every mapping grep to tracked app code -- `git grep` over `app lib
spec` (plus `config/locales` for locale work) -- never a bare recursive
grep from the repo root that sweeps `node_modules/`, `log/`, or build
output.

- Models -> model spec, plus the fan-in rule's hit list from Step 2 (map
  those files' specs; do not re-run the grep)
- Controllers -> matching controller/request specs, plus system specs
  covering the affected routes
- Views, JavaScript, and helpers -> related system specs and helper specs
- Shared view partials -> grep the partial's directory-qualified path
  (`shared/errors`), never its bare basename -- `form` matches half the
  app -- to find the templates and controllers that render it, and
  remember collection shorthand: `render @items` renders `_item.html.erb`
  with no literal partial name, so grep the model name too. Map renderers
  to their system specs.
- Services, jobs, mailers, serializers, decorators -> their own specs plus
  the specs of callers found by grep
- Policies -> the policy spec plus the resource's request/system specs
- Individual locale-key changes -> one batched alternation grep for all
  changed keys (`git grep -E 'key_a|key_b' app lib spec`), never one grep
  per key. Lazy lookup hides keys from that grep (`t('.title')` in a view
  resolves to `users.show.title` without the literal string appearing), so
  for keys under view-shaped namespaces also map the matching view's
  system/request specs
- `lib/` -> matching lib specs; `lib/tasks/**/*.rake` -> task specs, or a
  named gap when none exist
- Add-only route changes -> request specs for the touched controllers
- VCR cassettes -> `git grep` the cassette name in `spec/` for the specs
  that replay it
- `app/admin/**` (ActiveAdmin and kin) -> matching admin request/feature
  specs
- Changed spec files themselves -> always included (deleted spec files
  excepted -- they are the deleted-coverage finding, never a subset entry)

**Ripple depth is one hop.** Follow callers found by grep once; do not
chase transitive chains. Err inclusive at that one hop.

**Gaps.** A changed code file with no matching spec and no ripple hits is
a named gap recorded for the announcement -- the developer decides whether
that gap is acceptable for this branch.

## Step 4 -- Include manual pins

A story can pin specs that must run every time regardless of the diff.
Look in the story's plan file -- the one the plan-issue skill (bundled in
this plugin) maintains for the branch, by convention
`.claude/plans/<branch-slug>.md` -- for this exact heading:

```markdown
## Always-run specs
```

The heading is matched exactly because pins are collected mechanically,
not interpreted. Each entry is one spec path or glob per `- ` bullet;
include every entry in the subset. No plan file, or no such section:
record "no pins" for the announcement -- and if a near-miss heading exists
(`## Pinned specs`, `### Always-run specs`), say so instead of silently
reporting no pins.

## Step 5 -- Apply the size ceiling

The ceiling exists because a wide subset costs nearly as much as the full
run while keeping targeted-run risk: escalate when the subset's expected
runtime approaches the full run's. The cheap proxy is file count --
selected spec files (pins included) over roughly a third of the suite's
spec files:

```bash
git ls-files -co --exclude-standard spec | grep -c '_spec\.rb$'
```

File counts, not example counts; `-co --exclude-standard` counts untracked
spec files the same way Step 1 counts untracked changes. Over the line:
emit the ESCALATED verdict, trigger `subset too wide`. A project whose
spec costs are skewed (a few system specs dominating runtime) should adapt
the proxy toward what actually tracks runtime there.

## Step 6 -- Announce the subset, then proceed

Step 6 owns the announcement; earlier steps only record findings for it.
Print, before running anything:

- The base the scope was measured against -- the remote-qualified trunk
  (e.g. `upstream/main`), or the stacked branch's base -- so a wrong
  project-remote pick is vetoable here
- Each changed file with its selected specs and a one-line rationale
- Named gaps (changed code with no covering spec found)
- Deleted-spec findings, if any
- The "no spec impact" files, summarized in one line
- Pins included (or "no pins")
- The count: "N of M spec files selected"

Then proceed immediately into Step 7. The announcement is the veto window
-- the developer can interrupt to veto or widen the subset -- but there is
no blocking prompt, so unattended callers work.

## Step 7 -- Run lint, then the subset

Create the log first; both runs write to it, so the verdict's log path
exists even when no specs run:

```bash
LOG="/tmp/targeted-specs-$(date +%s)-$$.log"
<whole-project lint command> 2>&1 | tee "$LOG"
bundle exec rspec <selected files> 2>&1 | tee -a "$LOG"
```

1. **Whole-project lint first, always** -- never subsetted, run exactly as
   the full gate would run it.
2. **One spec invocation over the whole subset**, appended to the same
   log. Adapt both commands to the project's usual runners (container,
   binstub, parallel runner). A caller standing in for a
   coverage-bearing gate (e.g. the gauntlet) may ask for this
   invocation with coverage instrumentation on; delete the previous
   run's raw coverage results first (for SimpleCov,
   `coverage/.resultset.json` and its `.lock`) so the caller reads
   this run rather than a union with an earlier one, then keep the
   coverage artifacts alongside the log for it to consume. Grep the
   captured log for details; never re-run the subset just to re-read
   its output (the clean-and-green guidance's capture rule, where a
   team imports it).
3. An **empty subset skips the spec invocation entirely, however it got
   empty** -- only no-spec-impact files, only named gaps, only deleted
   specs, and no pins. Lint alone decides, and the verdict reports 0 spec
   files with the lint log as its log path. Never invoke the spec runner
   with an empty file list: bare `rspec` runs the entire suite, the exact
   run this skill exists to avoid.
4. Summarize pass/fail from the log and end with the verdict line. **Lint
   offenses make the run FAILED** even when every selected spec passes --
   `<f>` counts failing spec examples, so name the lint failure in the
   summary above the verdict line.

## The verdict line -- a load-bearing contract

Every run of this skill -- including a Step 0 refusal and a non-git
fallback -- ends its final message with exactly one of these lines,
verbatim in shape, placeholders filled:

```
Targeted run: ESCALATED -- full suite required (trigger: <trigger>)
Targeted run: PASSED -- <n> spec files (<p> pinned), 0 failures, log: <path>
Targeted run: FAILED -- <n> spec files (<p> pinned), <f> failures, log: <path>
```

Calling skills key off these lines to decide what happens next (hand off
to the full gate, proceed to ship steps, or stop on failures), so their
shape is not editable in passing -- treat any change as a breaking change
for the skills that consume them.

For a caller standing in for a full-gate step, the verdicts mean:
**ESCALATED** -- run the full gate; no targeted run happened.
**FAILED** -- the branch is red (lint or specs); fix before
proceeding, exactly as with a red full gate. **PASSED** -- the
targeted check passed. One caveat: a PASSED reporting 0 spec files
means lint alone ran; when the announcement listed named gaps
(changed code with no covering spec), that PASSED does not establish
a "specs pass" precondition -- surface the gaps or fall back to the
full gate instead of treating the branch as verified.

## Other stacks (reduced depth)

Outside Rails/RSpec the same skeleton applies with generic mapping:
compute the diff the same way; escalate on shared test infrastructure,
dependency manifests, and schema-shaped files; map source files to tests
by naming convention plus an import/require grep for callers; announce
with rationale; run the whole-project linter; capture lint and one test
invocation to the same /tmp log; end with the same verdict lines.

## Rules already covered elsewhere -- do NOT restate them

The definition of done, failure ownership, zero-warnings, and
no-suppression rules belong to the project's quality rules (and the
clean-and-green guidance where a team imports it); they apply to targeted
runs unchanged. This skill only decides *which specs run locally* -- it
never lowers the bar for what passing means.

## Project-specific overrides

Projects may place a `.claude/skills/targeted-specs/SKILL.md` in their own
repo to override this global default (different plans directory, different
spec layout, different escalation list). When such a file exists, it wins
entirely -- do not try to merge.
