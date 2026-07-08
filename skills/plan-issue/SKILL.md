---
name: plan-issue
description: Plan a story end-to-end -- interview the user about a Linear or Shortcut issue, research the code, propose a plan, optionally challenge the plan from a fresh perspective, record it as a markdown file under `.claude/plans/` and start working through the to-dos, then finish by confirming the work shipped and cleaning up the local branch. Use when the user says "let's plan a new issue", "let's work on a new issue", "plan this story", "challenge the plan", "record the plan", "write up the plan", "finish up the plan", "we shipped X, clean it up", or similar.
---

# Plan an issue

This skill drives the create -> challenge -> record -> finish arc that
spans the whole life of a story. It has four phases. Pick the phase that
matches the user's request:

- **create** (default) -- start a new plan for an issue. Triggered by "let's
  work on a new issue", "let's plan ...", or a Linear/Shortcut URL with no
  other context.
- **challenge** -- critique the current plan. Triggered by "challenge the
  plan", "poke holes in the plan", or after the user says the plan looks done.
- **record** -- write the agreed plan to a file and start executing.
  Triggered by "record the plan", "write up the plan", "start working
  through it".
- **finish** -- after the PR is merged AND the change is live in production,
  confirm the plan is wrapped up and delete the local working branch.
  Triggered by "finish up the plan", "we shipped X, clean it up",
  "we're done with X", or similar.

If the user invokes the skill without specifying a phase, default to
**create**. After **create** finishes, do NOT auto-advance into challenge or
record -- wait for the user. Likewise, do NOT auto-advance from **record**
into **finish** -- the gap between merge and production deploy is real, and
finish only runs once both have happened.

## Rules the user's CLAUDE.md files typically already cover -- do NOT restate them in the plan

The user's global and project CLAUDE.md files typically already require:

- TDD by default (failing spec first for production code changes).
- Small PRs (<300-400 lines), incremental commits.
- Clean and green: lint + tests must pass before commit/push/PR.
- Open `- [ ]` checkboxes for incomplete items, `- [x]` for completed.
  Never use the green checkmark to mean "todo".
- Use the bundled `linear` CLI for Linear access rather than raw GraphQL
  curl calls.
- No emdashes in user-facing prose.
- Title-case noun-phrase commit titles, not mechanism verbs.

The plan should *behave* consistently with these rules but should not
duplicate the rules themselves. Keep the plan focused on this specific
issue's why, what, and how.

## One canonical title; three artifacts share it by default

A single succinct title is chosen up front and used as the base for
**all three** artifacts:

1. The Linear (or Shortcut) issue title.
2. The plan filename under `.claude/plans/`.
3. The git branch name.

Per CLAUDE.md guidance, target roughly 40 characters or fewer for the
title -- a short verb-led phrase with one concept. Detail belongs in
the description, not the title. **Always pull the canonical branch name
from the issue tracker** rather than inventing a slug -- this guarantees
the tracker can auto-link the branch/PR to the story.

- **Shortcut**: if a Shortcut MCP server is configured, call its
  `stories-get-branch-name` tool (the
  `mcp__shortcut__stories-get-branch-name` action) for the story's public
  ID; it returns the valid, tracker-recognized slug, e.g.
  `sc-30818-fix-flakey-specs`. Otherwise derive the branch name from the
  story's public ID and title, or ask the user. Use that exact string
  for the git branch **and** the plan filename. Do this immediately
  after the story is created (or as soon as its ID is known) and before
  creating the branch.
- **Linear**: use the "Copy git branch name" action, which produces the
  slugified form (e.g. `abc-525-fix-pdf-uploads`); prefer that exact slug.

Never hand-roll a slug like `fix-flakey-specs` when a tracker story
exists -- the SC-/ABC- style tracker prefix is what lets Shortcut/Linear
detect the PR.

If the existing Linear/Shortcut title is too long or restates a whole
sentence, propose a rename **before** creating the plan file or branch
so all three artifacts can match. Do not silently use a different name
across artifacts.

### When deviation is allowed

Occasionally a single Linear/Shortcut story spawns multiple plan files
(separate up-front refactor + main work, or a follow-up cluster). In
that case, the plan filename and the corresponding git branch are
allowed to diverge from the original story title -- they should still
share a base name with each other (the plan and its branch), but they
do not have to match the parent story. When this happens, mention the
parent story ID inside the plan file and the branch name when
practical (e.g. `abc-502-followup-report-cleanup.md` paired with branch
`abc-502-followup-report-cleanup`).

### Rename the Claude Code session to match the slug

As soon as the canonical slug is locked in (after the issue title is
agreed and the branch name is known, but before creating files or the
branch), rename the current Claude Code session to match. This makes
the session discoverable later from a glance at the session list.

The Claude Code built-in `/rename` slash command is a UI command. It
cannot be invoked from a tool call, and writing the equivalent
`{"type":"custom-title", ...}` JSONL record into the current session's
transcript does NOT update the live terminal title -- the title bar is
set by an OSC escape sequence the real `/rename` emits in-band, and a
file write can't reach the TTY mid-session. The JSONL record only takes
effect on the next session load.

So: prompt the user to run `/rename` themselves. Pick the slug:

- If a Linear or Shortcut issue exists (or has just been created) and
  the canonical git branch slug has been chosen, use `<branch-slug>`
  (e.g. `abc-525-fix-pdf-uploads`).
- If no issue exists and none will be created (planning-only
  exercise, exploratory spike, pure-refactor plan with no tracker),
  use the same slug that will be the plan filename under
  `.claude/plans/`.

Then ask the user to run:

```
/rename <slug>
```

Do this exactly once per plan, immediately after the slug is chosen.
If the slug changes later (e.g., a parent-story plan spawns a
follow-up plan with its own slug per the deviation rule above),
ask the user to `/rename` again with the new slug.

---

## Phase: create

### Step 1 -- Interview for the issue

Ask the user:

1. Is there an existing Linear or Shortcut issue? If yes, get the URL.
2. Is this story going to use the canonical Linear/Shortcut title for
   the plan file and branch (the default), or is this a follow-up
   plan that needs its own deviating name?
3. Are we already on a clean copy of the right branch and good to go,
   or do we need to create/checkout/rebase first? (Before answering
   this from `origin/main`'s state, `git fetch origin` -- see Step 3.)

Pull the suggested branch name from Linear's "Copy git branch name"
action (or the Shortcut equivalent). Do not invent a slug from
scratch when the issue tracker already has one.

If the user has no issue yet, offer to create one in Linear before
going further. Do not proceed without an issue to anchor the plan.

When creating any Linear issue, **ask the user which project it belongs
to** rather than guessing from a heuristic (e.g. "bug -> maintenance").
The same work can be classified as contracted maintenance or as billable
requested-additional-work depending on context only the user knows, and
that choice has billing consequences. Offer the likely candidates (e.g.
the maintenance project vs. the requested-additional-work project) and
let the user pick; do not silently default. This applies to spun-off /
follow-up issues too.

If the existing issue title is overly long or sentence-shaped, propose
a rename now so the plan filename and branch can share the base name.

### Step 2 -- Read the issue

- **Linear URL or identifier** (`linear.app/...` or `ABC-NNN`): use the
  `linear` CLI bundled with this plugin (on PATH when the plugin is
  installed; requires Ruby and a `LINEAR_API_TOKEN` env var) -- not raw
  curl.
  ```bash
  linear get ABC-NNN --full      # title, state, description, project, comments, parent, children
  linear comments ABC-NNN        # just the comment thread
  ```
  Skim the description, comments, parent, and children for context. If
  the user invoked `/plan-issue ABC-NNN` (or just `ABC-NNN`), run
  `linear get ABC-NNN --full` as the first action of this step. If a
  subcommand is missing, suggest an improvement PR to the plugin repo.
- **Shortcut URL** (`app.shortcut.com/...`): use the Shortcut REST API or
  ask the user for the story body if no token is configured. Refer to
  Shortcut stories as "Shortcut", never "Linear".

Read the title, description, comments, and any linked parent or sibling
issues. Note the current workflow state.

### Step 3 -- Research the code

**Fetch before reasoning about remote state.** Run `git fetch origin`
as the first action of this step, before drawing any conclusion that
depends on what is on a remote branch -- "is ABC-NNN merged?", "does
main already contain X?", "where should this branch from?", "how many
commits is this branch ahead/behind?". The local `origin/main`
remote-tracking ref and the session-start git snapshot are both
point-in-time and go stale the moment someone else merges; trusting
them without fetching has produced confidently-wrong branching
decisions. After fetching, query `origin/main` (e.g.
`git show origin/main:path`, `git rev-list --count HEAD..origin/main`),
never a bare local ref you have not refreshed this session.

Then learn what you can from the repo:

- Find the models, controllers, services, jobs, views, and specs that the
  issue touches.
- Identify existing patterns for similar work (look at recent merged PRs
  on similar features if possible).
- Note where tests for affected code already live.
- For bug fixes, locate the suspected source and any related code paths.

For broad exploration use the Explore agent; for targeted lookups use
grep/find directly.

### Step 4 -- Frame the end-user story first (before implementation)

Before discussing *how* to build anything, pin down *what changes for
the end user* -- the person or client who will actually use the result.
State the change as a user story plus acceptance criteria written
entirely in terms of what the user sees, does, inputs, and gets back.
Keep implementation out of it: no models, no controllers, no "we'll add
a column." If a non-technical stakeholder (the client stakeholder who
requested it) read this story, it should make plain sense and
they should recognize their own request in it. This step exists because
it is easy to leap straight to a mechanism and end up with a technically
correct change that does not match what the user actually wanted; the
story is the contract the implementation then serves.

Produce:

1. **A user story** in the form "As a <role>, I want <capability>, so
   that <outcome>." Use the real persona (an admin user, a customer user,
   ...), not a generic "user" when a specific role applies.
2. **Acceptance criteria** as a short walkthrough of the interaction:
   what the user sees today, the action they take, the inputs they
   provide, and the observable outputs -- including the downstream
   artifacts they rely on (the receipt, the report, the email, the next
   screen), not just the screen in front of them. "Done" is when every
   line of this is observably true from the user's seat.
3. **The user-facing decisions that define "done"** -- the product/UX
   choices the story cannot be built without, surfaced as questions in
   end-user terms and explicitly separated from implementation
   questions. Typical shapes: does the affected item disappear after the
   action (consumption / idempotency)? whole-amount or partial? what is
   the guard when an input is out of range? which screens carry the new
   affordance? what does the user see on failure? Propose a sensible
   default for each, and say which genuinely need the requesting
   stakeholder's input versus which you can settle from existing
   behavior.

Confirm this story with the user (and, where the answer is theirs to
give, flag what should be confirmed with the requesting client or
stakeholder) *before* moving to the implementation interview.

Append the agreed user story and acceptance criteria to the Linear (or
Shortcut) issue, and carry them into the plan file (Step 6) so the
end-user definition of done travels with the work.

**When this step is light or N/A:** for changes with no end-user-
observable surface -- pure refactors, infra, dev tooling, internal
performance -- the "user" is the developer or operator. State the story
in their terms (what an engineer or operator can now do, or no longer
has to worry about) in a sentence or two, or note explicitly that the
change is internal with no user-facing surface, and move on. Do not
manufacture ceremony where there is no user-visible change.

### Step 5 -- Interview the user in depth (implementation)

With the end-user story from Step 4 agreed, dig into *how* to build it.
Ask non-obvious questions across these dimensions, one or two at a time
(do not blast a numbered list of 12 questions in one message):

- **Technical implementation** -- approach, data model changes, service
  boundaries, async vs sync, transactional boundaries.
- **UI / UX** -- form layout, empty states, error states, loading states,
  permission visibility differences.
- **Edge cases & failure modes** -- what happens on partial failure,
  retries, race conditions, concurrent edits.
- **Authorization** -- which roles can do what; double-check Pundit
  policies for the affected resources.
- **Backwards compatibility / migration** -- existing rows, in-flight
  jobs, deployed sessions, partial rollouts.
- **Tradeoffs** -- what alternatives did you consider, why this one.
- **Out of scope** -- what is NOT being done here, to prevent scope
  drift later.

**Strongly prefer the design that is best to live with for years -- then
get creative about reaching it cheaply.** When the work has more than one
viable shape -- a new model vs. extending an existing one, a stored field
vs. a derived one, unifying two concepts vs. keeping them separate -- lean
hard toward the option that is cleanest to maintain over the long run,
even when it is the bigger diff. Heuristics for "cleaner to maintain": a
preserved, locally-true invariant beats an overloaded one; a value derived
from a single source of truth beats a duplicated field that can drift;
modeling distinct concepts distinctly beats conflating them behind a sign
or a flag.

But naming the long-term winner is only half the job. Also tell the user,
plainly, the implementation **risk, cost, and blast radius** of that
option. The user will almost always still choose the best end-state -- but
knowing its cost is what lets them make a creative call, so don't hide it
to make the recommendation look cleaner. The highest-value move is usually
to brainstorm a *lower-risk path to the same long-term destination*: an
incremental migration, a transitional coexistence that cleanly collapses
once a backfill runs, a clean seam a later effort can converge onto, or
phasing the work across PRs. High cost or risk is a reason to get creative
about the route, not a reason to settle for a worse end-state.

Resist speculative generalization in the other direction, too -- unify or
abstract only when a real, present need demands it, not for a future that
may never arrive. And when the user pushes on "which is cleaner to
maintain?", answer honestly even if it argues against the option you first
proposed.

Skip questions whose answers are obvious from the issue or the code.
Continue until the picture is clear; do not stop after a single round.

When the interview is done, append the resulting specification to the
Linear (or Shortcut) issue description, so the source of truth for what
we agreed on lives there too.

### Step 6 -- Propose the plan

Draft a plan with:

1. **Why + user story** -- a single opening paragraph that states the
   user-visible motivation, paired with the end-user story and
   acceptance criteria agreed in Step 4 (verbatim or lightly edited).
   This is the most easily-overlooked section when heads-down on
   details, so lead with it: the plan should open with the user-facing
   definition of done, and it must make sense to someone who has not
   read the Linear issue.
2. **Approach** -- the strategy in plain language, not a file list.
3. **Optional up-front refactor** -- if the existing code is shaped
   awkwardly for the change, propose a refactoring to do first (either
   in the same PR, or as its own PR before this one). Frame it as
   *optional* and let the user decide.
4. **TDD-first steps** for any production code change: write the failing
   spec before the production change. (Skip the failing spec only for
   config-only changes that aren't covered by regression tests.)
5. **Ripple work**:
   - For new features: explicitly list the parts of the app that need
     to be updated to account for the new feature (other controllers,
     reports, exports, mailers, JS, fixtures, seeds).
   - For bug fixes: include a step to search for sibling bugs of the
     same shape elsewhere in the codebase, beyond just the reported one.
6. **Out of scope** -- a short list of things not being done, mirroring
   the interview.
7. **To-dos** as numbered `- [ ]` checkboxes, in execution order, each
   carrying an explicit stable number the user can see and refer to,
   e.g. `- [ ] **1.** Identify the example payment`. The numbers are
   permanent handles: never renumber when an item completes (it just
   becomes `- [x] **1.**`), and append newly-discovered work as the next
   unused number rather than reflowing the list. This is what lets the
   user say "do task 13" and lets you cite "Task 13" against something
   they can actually find in the file. The standard tail of the list --
   the "ship the work" steps -- has a fixed ordering that exists for a
   wall-clock reason:

   1. Run the project's full lint+test suite once, capturing complete
      output to a log file you can grep (use the project's suite-runner
      skill if it provides one). This is the slow step
   2. Run the gauntlet skill (bundled in this plugin) via the Skill
      tool. The gauntlet is a multi-front quality pass that *requires*
      clean-and-green as its starting state -- it dispatches parallel
      sub-agents to audit cruft, idioms, RSpec quality, validation
      bypass, and security, then triages findings into a punch list.
      Run it after step 1 because it expects specs and lint to already
      pass; run it before step 3 because any findings the user accepts
      should be in the PR before it leaves draft for human review. Skip
      only if the user explicitly opts out for this issue.
   3. Open the draft PR. This kicks off GitHub CI checks and any
      automated reviewer (e.g. claude-code-action) that runs on
      ready-for-review or synchronize events.
   4. Move the issue to PR Review; wait for human review and merge.
   5. **Stakeholder change-highlights (conditional).** When the change
      alters something a client stakeholder visibly relies on -- a
      report, receipt, statement, mailer, or screen -- and the project
      provides a change-highlights-style skill for stakeholder-facing
      before/after summaries, add a step to build one and communicate it
      to the stakeholder so they can review each change visually with
      a clear, explained example. Skip only for purely internal changes
      with no stakeholder-visible surface (refactors, infra, dev tooling).

Present the plan inline for the user to discuss and refine. Do not
write it to disk yet -- that happens in the **record** phase.

---

## Phase: challenge

The goal of this phase is an honest second opinion on the current plan,
not a rationalization of it.

**Strongly prefer dispatching this to a fresh subagent** so the critique
is not anchored to the same conversation that produced the plan. Use
`Agent` with `subagent_type: "general-purpose"` (or `Plan`), and pass
the plan text plus the issue description in the prompt. Tell the agent
to read it cold and report back.

The critique must consider:

- Is the plan creating unnecessary complexity? Is there a simpler,
  more elegant path?
- Where does it deviate from team or community conventions for this
  stack (Rails idioms, Pundit policies, RSpec / shoulda-matchers /
  FactoryBot patterns, project conventions in CLAUDE.md)?
- Does it sufficiently emphasize a TDD spec that will *prove the fix
  or feature continues to work into the future*? A spec that only
  passes incidentally is not enough.
- For bug fixes: does it search for sibling bugs of the same shape?
- For features: does it cover the ripple effects across affected
  parts of the app?
- Are there assumptions baked in that we should validate before
  building?

Value code quality and ease of maintenance over saving development
time. Only **propose** improvements -- do not assume the plan will
change. The user is asking to stress-test the plan, not to redo it.

---

## Phase: record

### Step 1 -- Locate the plans directory

The plans directory convention is `<project>/.claude/plans/`. In any
established project it already exists, so do NOT probe for it with
`ls`/`test`/`mkdir` -- that check is pure waste on every plan after the
first. Just write the plan file directly in Step 3. Only if that Write
fails because the directory is genuinely missing (a brand-new repo that
has never had a plan) do you `mkdir -p .claude/plans` once and retry the
Write. This pushes the one-time setup cost onto the first-ever plan in a
fresh repo and keeps the common path zero-overhead.

### Step 2 -- Pick the filename

By default the plan filename **matches the canonical Linear/Shortcut
title slug** -- the same slug used for the git branch. If Linear's
"Copy git branch name" produces `abc-525-fix-pdf-uploads`, the plan
file is `abc-525-fix-pdf-uploads.md`.

The only time the plan filename should diverge is when this plan is
one of multiple spawned by a single story (a follow-up cluster, an
up-front refactor split out from the main work). In that case use a
descriptive slug that still references the parent issue ID, e.g.
`abc-502-followup-report-cleanup.md`. The git branch should share the
plan's slug, not the parent story's title.

Do not restate the entire issue title in the filename. Aim for ~40
characters or fewer.

### Step 3 -- Write the plan verbatim

Write the agreed plan -- including the **Why** paragraph, approach,
to-dos, and any agreed refinements from the challenge phase -- to that
file. Use `- [ ]` for incomplete to-dos.

### Step 4 -- Load the to-dos into the Task tracker

Immediately after writing the plan file, mirror its to-do list into the
Claude Code Task tracker via `TaskCreate`. This gives the user a live,
toggleable view of progress (Ctrl-T) alongside the markdown plan file.

- Create one task per `- [ ]` checkbox in the plan, in the same execution
  order. Keep task titles short and faithful to the plan's wording -- do
  not paraphrase, summarize, or merge items.
- **One task = one verifiable deliverable. Never merge distinct steps into
  one task, even when they always run together.** Smell test: if a task
  title needs "and", "+", "then", or a comma to join separate deliverables,
  split it. "Full test suite and gauntlet and draft PR" is three tasks, not
  one -- each is independently substantial and independently checkable.
- The trailing ship-the-work steps are each their **own** task, not a single
  bundled one: full suite, the gauntlet skill, open draft PR, and move to
  PR Review are separate tasks so the toggle view shows the whole arc and
  each completes on its own. When the change is stakeholder-visible (a report,
  receipt, statement, mailer, or screen a client stakeholder relies on) and
  the project provides a change-highlights-style skill, add a further own
  task for the before/after summary and its communication to the stakeholder.
- The markdown plan file remains the source of truth for the *why* and
  the approach. The Task tracker is a fast-access view of the *what's
  next*. Keep them in sync: when a to-do is checked off in the markdown,
  mark the corresponding task complete via `TaskUpdate`; when new work
  is discovered, append it to both.
- **Always show the task number next to each task** whenever you surface
  the task list to the user (e.g. `1. ...`, `2. ...`). The user refers to
  tasks by number, so a bare bulleted list is not enough -- every rendered
  task list must carry its numbers so they map back to the tracker.
- **When you reference a single task in prose, cite both its number and
  its short name** -- "Task 13 (Move ABC-616 to PR Review)", never a bare
  "Task 13". The bare number forces the user to go count; the number plus
  name is unambiguous whether they are looking at the tracker, the plan
  file, or just your message. Keep the numbers identical across the plan
  markdown, the Task tracker, and your prose.

### Step 5 -- Move the issue to In Progress (assigned)

Before starting the work, transition the Linear issue out of Todo and
into the active state -- and assign it in the same call. A started state
(In Progress) without an owner is the error this step exists to prevent.

```bash
linear update ABC-NNN --state "In Progress" --assignee me
```

`--assignee me` resolves to the token's own user; pass an explicit email
(e.g. `--assignee teammate@example.com`) if the work belongs to someone
else. The CLI **rejects** a move into a started state with no assignee, so
never strip the `--assignee` flag to get past that error -- supply the
owner instead. Skip this step only for planning-only exercises with no
tracker issue.

### Step 6 -- Show the to-do list and start

Surface the plan's to-do list and start working through it. After each
phase or to-do (your judgment on grouping):

1. Run rubocop (or standardrb) and fix all failures.
2. If production code changed: run the project's full lint+test suite
   once, capturing complete output to a log file you can grep (use the
   project's suite-runner skill if it provides one). If only tests
   changed: just the affected specs are fine. You may bundle multiple
   to-dos into a single full-suite run when the time saved is worth
   the lower granularity.
3. Commit and push that work. Use a Title-Case noun-phrase commit
   title per CLAUDE.md guidance.
4. Update the plan markdown: change `- [ ]` to `- [x]` for completed
   items, add any newly-discovered work. Mirror the change in the
   Task tracker via `TaskUpdate` so the Ctrl-T view stays accurate.
5. Show the user the updated to-do list, with each task's number shown
   next to it (the user refers to tasks by number), unless there's a
   clear reason not to, e.g. a single-line trailing checkoff.
6. Tell the user the current PR size in lines changed and how far it
   is over (or under) the 400-line easy-review threshold.

If at any point the PR size or scope is drifting, surface it and offer
to split.

---

## Phase: finish

The work isn't done when the PR merges -- it's done when production is
running the merged code AND the user has confirmed nothing is
outstanding. This phase's role is to gate the handoff to the
housekeeping skill: confirm preconditions, then delegate. The
finished-issue-housekeeping skill (bundled in this plugin) owns the
actual cleanup work (plan-file finalization, branch deletion, memory
updates, sibling-audit verification, task list housekeeping).

Do NOT auto-advance into this phase from `record`. The gap between
"PR merged to main" and "shipped to production" is real, and so is
the gap between "shipped" and "we're sure nothing else is needed".
Wait for the user to ask.

### Step 1 -- Confirm preconditions

Walk through these checks (the housekeeping skill will re-verify, but
catching a "no" here lets you exit early before invoking it):

1. **PR is merged to main.** Verify with `gh pr view <PR#> --json state,mergedAt,mergeCommit` (or whichever forge the project uses).
2. **The merged code is live in production.** Project-specific check:
   - Heroku-deployed apps: `heroku releases -a <prod-app>` and confirm a release after the merge commit.
   - Other deploy targets: ask the user, or look at the deploy log / dashboard.
   - When in doubt, ask the user to confirm rather than guess.
3. **The user explicitly confirms** the plan is wrapped up.

If any of these is "no", **stop**. The branch may still be needed --
for a hotfix on top of the same code, for cherry-picking, for a
follow-up PR that branches from it. Don't proceed with cleanup on
assumption.

### Step 2 -- Invoke the finished-issue-housekeeping skill

Invoke the finished-issue-housekeeping skill (bundled in this plugin)
via the Skill tool. It will:

- Re-verify preconditions (idempotent with Step 1).
- Classify each unchecked plan-file item and STOP if any genuinely
  unfinished work surfaces.
- Add the Shipment section to the plan file.
- Delete the local working branch with `-d` safety.
- Add a Done entry to `MEMORY.md` and remove the issue from Active
  Work if it was there.
- Ask whether anything is worth saving as a tech-note memory or
  a new skill, and create it if so.
- Verify sibling-audit follow-ups got filed.
- Clear completed tasks from the conversation task list.

Relay the housekeeping skill's summary to the user when it finishes.

---

## Project-specific overrides

Projects may place a `.claude/skills/plan-issue/SKILL.md` in their own
repo to override this global default (for example, to specify a
different plans directory, a different test command, or a different
branch-naming convention). When such a file exists, it wins entirely
-- do not try to merge.
