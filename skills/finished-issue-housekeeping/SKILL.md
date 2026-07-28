---
name: finished-issue-housekeeping
description: Post-ship cleanup for a story that has shipped -- merged AND live in production, or merged alone on a project in Deploy-on-Merge Mode. Finalizes the plan file, deletes the local working branch, prunes other stale local git branches repo-wide (not just the just-finished story's), updates auto-memory (Done entry + any new tech-note or skill worth saving) and prunes MEMORY.md back within its size budget, verifies sibling-audit follow-ups got filed, stops any dev server started for verification, clears completed tasks from the conversation task list, and ends with an approval-gated permission-prompt sweep (via the /fewer-permission-prompts built-in, when available). Use when the user says "finish up the plan", "we shipped X, clean it up", "post-ship cleanup", "we're done with X", "housekeeping for <issue>", or invokes the finished-issue-housekeeping skill. Also invoked at the end of `plan-issue`'s `finish` phase.
---

# Finished issue housekeeping

A shipped change is not yet a finished story. It is finished when the change has shipped, the user has confirmed nothing is outstanding, and the working-state debris (local branch, in-flight tasks, stale plan checkboxes, unrecorded learning) has been swept up. "Shipped" means production is running the merged code; on a project in Deploy-on-Merge Mode (defined in the plan-issue skill, bundled in this plugin) the merge itself is that event. The user's confirmation is a separate gate that no project setup removes.

This skill runs the cleanup steps below in order. It is invoked either:

- Automatically at the end of the `finish` phase of the plan-issue skill (bundled in this plugin), OR
- Directly by the user for ad-hoc work that did not go through the plan-issue skill (small bug fixes, one-off cleanups, work that pre-dated the plan system).

## Rules already covered elsewhere -- do NOT restate

- **CLAUDE.md (global and project)** -- development-time rules (clean-and-green, TDD, lint, commit conventions). Housekeeping does not touch production code, so those rules are out of scope here.
- **plan-issue skill (bundled in this plugin)** -- owns plan creation, challenge, recording, and execution. This skill is called only for the final cleanup.

---

## Step 1 -- Confirm preconditions

**First, establish whether the project is in Deploy-on-Merge Mode**, because check 2 below depends on the answer. The mode holds only when the project's checked-in CLAUDE.md or a rules file declares it -- an explicit statement that merging to the default branch is the production deploy, naming the mode or saying so unambiguously. Three rules make that judgment safe:

- **Never infer the mode from the project's shape.** No version file, auto-merge enabled, a deploy workflow present, a fast-looking pipeline: none of these is a declaration. A silent inference here skips a real deploy check and then deletes a branch and closes an issue, which is the failure this precondition exists to prevent.
- **A project that declares nothing is not in the mode.** That is the default, and it is the safe answer.
- **Ambiguous wording means undeclared, so ask.** Prose that merely describes how the project happens to work ("we deploy on every merge", "merged means shipped") is a shape observation, not a declaration. Treat it as undeclared and ask the user before relying on it.

The plan-issue skill (bundled in this plugin) defines the mode in full, including the declaration's wording and the premise it asserts. This skill runs standalone too, so the rules above stand on their own -- do not skip them because that file was not loaded.

Then verify:

1. **The PR is merged.** Run `gh pr view <PR#> --json state,mergedAt` and confirm state is `MERGED`. For stories that landed via several PRs, check the last one.
2. **The merged code is live in production.** Before taking any shortcut, confirm the premise: nothing after the merge can still fail or be skipped. A project whose merge *triggers* a deploy that can go red is **not** in Deploy-on-Merge Mode however its rules read -- verify the deploy and tell the user the declaration looks wrong. A post-merge job that only *verifies* the merged commit (a test or lint run that cannot withhold the change from users) is not such a step, and does not disqualify the mode.

   With that premise confirmed, in Deploy-on-Merge Mode check 1 satisfies this one: the merge is the deploy, so there is no later event to look for. Otherwise check the project's deploy log:
   - Heroku apps: `heroku releases -a <prod-app> --num 3` and confirm a release whose commit SHA descends from the merge commit.
   - Other deploy targets: ask the user, or look at the deploy log / dashboard.
3. **The user explicitly confirms** the work is wrapped up (they invoked this skill or said "we shipped X").

If any of these is "no" -- **stop**. Do not delete anything. The branch may still be needed for a hotfix; the plan may still have post-ship tasks.

## Step 2 -- Plan file finalization

If a plan file exists for this story (the plan-issue skill places them under `.claude/plans/<slug>.md`; ad-hoc plans may live elsewhere -- ask the user if unsure):

**Do not blindly flip `- [ ]` to `- [x]`.** Each unchecked item must be classified before you touch it. Read every `- [ ]` line, then sort each one into one of these buckets:

- **Actually done.** The conversation history, git log, PRs, or production state make it obvious the work landed. Flip to `- [x]`.
- **This plan's own finish-tail items.** Plans generated by the plan-issue skill carry up to two ship-tail items this very pass completes: a confirm-shipped gate (typically "Confirm shipped (PR merged, live in production)", satisfied by Step 1's precondition checks) and a run-housekeeping item (typically "Run finished-issue-housekeeping (finish phase, user-triggered)", satisfied by this pass running). A plan written under Deploy-on-Merge Mode carries only the second; a plan written before the project declared the mode still carries both, and its confirm-shipped item is satisfied by the merge exactly as Step 1 records. Identify them by role, not by exact wording, and do not expect both to be present -- older or ad-hoc plans may carry neither. **At most one item of each of those two roles qualifies, per plan file** (a story with a parent plan and a follow-up plan has its own pair in each). Every other unchecked item goes through the other buckets however similar it sounds -- an item like "Verify the migration ran on prod" is real outstanding work, not a second confirm-shipped gate, and auto-ticking it is exactly what the STOP rule exists to prevent. Classify every other unchecked item first; only once none has triggered the STOP below, flip the finish-tail items to `- [x]` and continue the step (Shipment section, then reconcile). Later steps of this pass are still pending at that moment, so the checked boxes are not proof the pass completed: a later session detects a half-run pass by its missing artifacts (local branch still present, no Done entry in `MEMORY.md`, tracker issue not in its terminal state) and resumes the remaining steps -- re-running the reconcile then is safe (it is idempotent) but only needed if it had not yet run or the plan changed since. Two of those artifact signals die early in common setups (auto-close repos close the issue at merge; projects without auto-memory never get a Done entry), and the branch signal dies at Step 3 -- so when the record is ambiguous, re-run the remaining steps rather than assuming the pass finished; each is idempotent or safely re-checkable. Steps 8-9 (task-list cleanup, the permission-prompt sweep) leave no reliable half-run signal -- the sweep's only durable trace is a settings diff that appears solely when the user approved additions and looks the same whether or not the sweep completed -- so a pass that dies among them can look finished; both are harmless to re-run, so re-run them when the record is ambiguous rather than trusting the checked boxes. No other item is ever "completed by this pass", and this bucket never bypasses the STOP rule below.
- **Deferred to a follow-up issue.** The work was intentionally split off; a separate issue tracks it. Tick the box and append the destination to the item text, keeping the item's number -- `- [x] **N.** <original text> (deferred to <ISSUE-ID>)` -- so the deferral and its destination are both visible in the historical record.
- **Genuinely not done, and unsure whether it should be.** Surface it to the user and ask: "I see `<item>` is still unchecked. Was it done, deferred, or still outstanding?" Wait for the answer.

If the user identifies any item that **is still outstanding and should be finished**, **STOP the entire housekeeping pass.** The story is not actually done; finishing the housekeeping would lock that fact behind a `[x]` and lose it. Surface the outstanding work clearly, and let the user decide whether to extend the PR / open a follow-up / accept the deferral. Resume housekeeping only after the situation is resolved.

Check the tracker issue's state before you hand the decision back, because a STOP can leave the board lying. A repo that auto-closes on merge -- the common setup in Deploy-on-Merge Mode -- has already put the issue in its terminal state, so an issue whose plan still has outstanding work reads as Done to everyone else. Say so plainly and offer to reopen it. Step 5, which is where issue state is normally read, is never reached on this path.

Once every unchecked item has been classified and updated, add a "Shipment" section at the bottom of the plan:

```
## Shipment

Shipped YYYY-MM-DD via <the release or merge commit that shipped it>.

<one paragraph naming each PR that landed, any gauntlet must-fix items
surfaced, and any follow-up issues that got filed>
```

Use the conversation's actual dates, PR numbers, and SHAs. Do not fabricate. If you don't know, look them up via `gh pr view`, `git log`, or the project's deploy log. Name whichever identifier the project actually has: a release version where releases exist, the merge commit where merging is the deploy.

If multiple plan files match the issue (e.g. a parent plan + a follow-up plan), apply the same classification process to each.

On a GitHub-tracked repo, once the plan file's checkboxes are finalized, reconcile the issue-body checklist so it exactly mirrors the finalized plan, using the `gh-issue-sync` CLI bundled in this plugin: `gh-issue-sync reconcile NNN --plan .claude/plans/<slug>.md` (passing the same `--heading <slug>` the mid-flight syncs used, when they used one). It regenerates the checklist section from the plan and refuses to run while the plan still has a bare unchecked `- [ ]` in its to-dos -- every item must end `- [x]`, or `- [x] ... (deferred to #NNN)` -- so an abort naming unchecked to-dos means the classification above was skipped, never a reason to work around the tool. An abort saying the section "holds arbitrary content" is different: a content section (user story or spec) was written under the plan's own slug, so resolve that slug collision (re-create the content under a different slug via `gh-issue-sync section`, then remove the colliding section with `gh-issue-sync section NNN --slug <plan-slug> --delete`) and re-run. The checklist is allowed to drift mid-flight but must not *end* stale; this is where that guarantee is enforced.

If no plan file (skill invoked ad-hoc), skip this step.

## Step 3 -- Local branch deletion

Resolve the default branch once and reuse it everywhere below -- this step and Step 3b both depend on it, and `main` is not always the answer:

```bash
DEFAULT=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
DEFAULT=${DEFAULT:-$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name')}
```

If neither command yields a name, stop and ask rather than assuming `main`.

Refresh remote-tracking state **before** deleting anything, so the checks below read current state rather than a remote ref that was deleted on the forge weeks ago:

```bash
git fetch --prune
git checkout "$DEFAULT"
git pull --ff-only
```

Then delete the branch, gating on evidence rather than on a command's refusal:

```bash
git merge-base --is-ancestor <branch-name> "origin/$DEFAULT" && git branch -d <branch-name>
```

**`-d` is not a safety net, and must not be used as one.** It refuses only when a branch is unmerged into HEAD *or its own upstream* -- so a fully-pushed branch whose work never reached the default branch deletes with exit 0 and nothing but a warning. Establish that nothing on the branch is absent from the default branch, using the ancestor check above or either proof in Step 3b, and use `-d` for the deletion itself.

If the branch is not an ancestor:

- Most common cause: the PR was squash-merged or rebase-merged, so the branch's commits do not appear by SHA in the default branch's history. Clear it with either proof in Step 3b before forcing with `-D`; a merged pull request on its own does not establish it, because the branch can carry commits made after its last push.
- Less common: there is genuine unmerged work on the local branch that did not make it into the PR. **Stop and investigate before forcing.**

Do NOT delete the *remote* branch. GitHub's auto-delete-on-merge usually handles it, and external tooling (trackers, deploy logs, PR cross-references) may still link to the remote ref. If the user wants the remote gone, they will ask.

If multiple local branches relate to the issue (parent + follow-up branches), each one gets its own evidence check -- a follow-up branch is exactly the case where the work may not have landed.

## Step 3b -- Prune other stale local branches (repo-wide)

Shipping a story is a natural moment to sweep the whole local branch list, not just this story's branch. Stale local branches from long-finished work pile up and make `git branch` noise. Prune the branches whose work has demonstrably landed; keep everything else.

The bar for deleting a branch is evidence that **nothing on it is absent from the default branch**. A deleted remote ref is not that evidence: it is equally consistent with a merge, an abandoned pull request, a branch cleaned up by hand, or a rename. Two proofs below meet the bar, and either one alone is enough.

Step 3 already resolved `$DEFAULT` and ran `git fetch --prune`; reuse both. Every command below names `$DEFAULT` rather than a literal `main` -- a repo defaulting to `master`, `develop`, or `trunk` is common, and a repo where `main` still exists but is *not* the default (gitflow, a half-finished rename) makes a hardcoded `origin/main` measure against the wrong branch and clear work that never landed.

### Protected set -- never a candidate, whatever the passes below say

- The current branch, and the default branch (`$DEFAULT`).
- **Any branch checked out in another worktree** (`git worktree list --porcelain`). Both `-d` and `-D` refuse these outright, so leaving them in the candidate list only produces a mid-sweep error.
- Intentional backup branches (names ending in `-backup`, or otherwise clearly a manual safety net). Mention them, but leave them unless the user names them explicitly.
- Any branch the user has flagged as in-progress this session.

Enumerate candidates with `git for-each-ref`, and carry full refnames through:

```bash
git for-each-ref --format='%(refname)' refs/heads/
```

A tag sharing a branch's name makes `%(refname:short)` yield `heads/<name>` and makes a bare `git rev-parse <name>` resolve to the *tag*, not the branch -- so carry the full `refs/heads/<name>` ref, and derive the short name from it where a command needs one:

```bash
short="${ref#refs/heads/}"
```

Use the full ref for anything that resolves an object (`git rev-parse "$ref"`, `git merge-tree ... "$ref"`) and the short name for `git branch -d`/`-D` and `gh pr list --head`. **`git branch -d refs/heads/<name>` does not work** -- it reports `branch 'refs/heads/<name>' not found` and exits 1, so a sweep written the other way silently deletes nothing at all.

Do **not** enumerate with `git branch -vv | grep ': gone]'`. That matches a branch whose upstream is a deleted *local* branch, and a branch whose *commit subject* merely contains the text -- both typically never-pushed work -- and it stays silent until someone runs `git fetch --prune`.

### Pass 1 -- already an ancestor of the default branch

```bash
git branch --merged "origin/$DEFAULT" --format='%(refname)'
```

Delete each with `git branch -d "$short"`, minus the protected set.

`-d` can still refuse one of these, and the refusal does not mean the work is at risk: `-d` measures against HEAD or the branch's own upstream, never against `origin/$DEFAULT`. A local default branch sitting behind the freshly-fetched remote is the usual cause, which is why Step 3 runs `git pull --ff-only` first. If a Pass 1 branch is refused anyway, it is already proven an ancestor by the enumeration above, so delete it with `git branch -D "$short"` -- the proof, not the tool's opinion, is what authorizes it.

### Pass 2 -- candidates Pass 1 did not list

A squash or rebase merge leaves the branch tip a non-ancestor of the default branch, so `-d` refuses even though the work landed. Use `git branch -D` only where **either** proof below holds; otherwise keep the branch and report why.

**Proof (a) -- the content is already in the default branch.** Local, offline, and immune to squash and rebase merges:

```bash
tree=$(git merge-tree --write-tree "origin/$DEFAULT" "$ref") || tree=CONFLICT
[ "$tree" = "$(git rev-parse "origin/$DEFAULT^{tree}")" ] && echo "nothing at risk"
```

If merging the branch into the default branch would produce the default branch's own tree, the branch adds nothing. This mode arrived in git 2.38; below that, skip proof (a) and rely on proof (b).

**Quote `"origin/$DEFAULT^{tree}"`.** Unquoted, zsh with `extendedglob` set (common, and the default in some shell frameworks) treats it as a glob, fails with `no matches found`, and yields an empty substitution -- the comparison is then false for every branch, so proof (a) silently clears nothing and there is no error a session would notice.

`git merge-tree` **exits non-zero on conflict**, so the exit status gates the comparison -- git's own documentation wraps it in `$(...) || { ... }` for exactly this reason. Without the guard the failure is silent rather than dangerous: on conflict the command prints the tree id *plus* the conflicted stages, so the captured value is multi-line and simply never matches. Keep the guard anyway, both to say what happened and because any variant that trims the output to its first line would turn that safe mismatch into a false "nothing at risk".

A conflict is not evidence of anything. It usually means the default branch later edited the same lines. It means only that proof (a) cannot clear this branch, so fall through to proof (b).

**Proof (b) -- the forge merged this exact tip into the default branch.** Query per branch, not once for the repo:

```bash
gh pr list --head "${ref#refs/heads/}" --state all --limit 100 \
  --json number,state,headRefOid,baseRefName,mergedAt,isCrossRepository
```

A branch clears proof (b) when its results carry a pull request where **all** of the following hold:

- `state` is `MERGED`;
- `baseRefName` is `$DEFAULT`, so a merge into some *other* feature branch never counts -- a stacked child branch merged into its parent has not reached the default branch;
- `isCrossRepository` is `false`;
- `headRefOid` is **string-equal** to `git rev-parse "$ref"`;

and where **no** pull request for that branch is `OPEN`.

Query per branch rather than fetching the repo's pull requests in one call. A single bulk call has to be bounded by `--limit`, and `gh` returns the most *recently created* pull requests -- so the ones that fall off the end are the oldest, which is precisely the population a stale-branch sweep is about. A truncated merged pull request reads as "no pull request at all", and the report would then state that as fact. Scoped to one branch the result cannot meaningfully truncate, and the OPEN check reads from the same result set.

Three traps in that query:

- `--head` matches on branch *name* only and cannot be scoped to an owner (the `<owner>:<branch>` form returns `[]` rather than an error), so pull requests from forks share the result set with yours. That is what `isCrossRepository` filters out.
- **Never resolve `headRefOid` as a git object.** On a squash-merge repo it is routinely absent from an ordinary clone. Compare the two strings and nothing more: `git rev-parse --verify <40-hex>` exits 0 on an object that does not exist, so it cannot screen for presence, and `git merge-base --is-ancestor` exits 128 on an absent commit, which an `if` reads as a plain "no".
- In a clone of a fork carrying an `upstream` remote, `gh` queries the *parent* repo. A team running its own pull requests inside a fork gets no matches; name the repo explicitly with `--repo` there.

**A failed query is not an answer.** `gh` missing, unauthenticated, offline, rate-limited, or pointed at a non-GitHub remote all exit non-zero, whereas a genuine no-match is `[]` with exit 0. Never let a non-zero exit collapse into the "no pull request" reading: that reading is what the report states as fact. On the first failure, treat proof (b) as unavailable for the whole sweep rather than retrying per branch -- these causes are all repo-wide, not branch-specific -- say so plainly, keep everything proof (a) could not clear, and never substitute a weaker signal.

### Report

Report the sweep as a small table -- branch, outcome, and the reason -- because the keepers need different follow-up from each other:

| branch | outcome | reason |
|---|---|---|
| `old-feature` | deleted | content already in `main` |
| `squashed-thing` | deleted | pull request #41 merged this tip |
| `half-done` | kept | commits not in `main`, no pull request |
| `awaiting-review` | kept | pull request #52 still open |
| `abandoned-spike` | kept | pull request #48 closed unmerged |
| `local-tweaks` | kept | tip differs from the tip the forge recorded |

Word that last reason as what is actually known. A tip that differs from `headRefOid` may be ahead of it, behind it, or diverged, and only the first is unpushed work -- claiming "commits made after the last push" is wrong for a branch that is merely behind.

The user makes the final call on every keeper and on the protected set; do not delete those without an explicit instruction.

## Step 4 -- Update auto-memory

Only run if you maintain an auto-memory for this project. Indicator: a `MEMORY.md` file under the project's memory directory (the system prompt's "auto memory" section names the directory). If the project has no auto-memory set up, skip the whole step.

### 4a -- Done entry in `MEMORY.md`

Add the finished issue under a "Done" cluster. Match the existing project convention -- copy the cluster-header format from the most recent Done cluster already in the file, rather than inventing a new one.

Brief entry per issue:

- Identifier + title.
- PR numbers and the release or merge commit that shipped it.
- One-paragraph summary of what landed -- including any gauntlet must-fix items, key sibling-audit results, follow-up issues filed.
- Link to the plan file.

If the issue was in the "Active Work" section of `MEMORY.md`, remove it from there at the same time so the active section stays focused on what is actually still in flight.

### 4b -- New tech-note or skill opportunity

Ask the user **literally**: "Did anything surprising or non-obvious come up during this story that's worth saving as a tech-note memory or creating a skill for the next time we work in this area?"

Examples of what qualifies as a **tech-note**:
- Hidden invariants or timing/ordering quirks discovered.
- Library or framework gotchas whose reasoning would not be obvious from reading the code.
- Non-obvious workarounds that future-you will not be able to derive from current-you's commit message alone.

Examples of what qualifies as a **skill**:
- A repeated multi-step workflow that you executed ad-hoc this time and would benefit from running deterministically next time.
- A check-and-cleanup pattern that came together late and worth promoting from "we did it once" to "we do it every time."
- Something the user *asked* you to do that you had to figure out from scratch -- and might have to re-figure-out from scratch next time without the skill.

If yes:
- Tech-note: write the memory file in the project memory directory using the standard auto-memory frontmatter, and add a one-line pointer under `MEMORY.md`'s "Technical Notes" section.
- Skill: propose a skill name and rough scope to the user, then write `~/.claude/skills/<name>/SKILL.md` (global) or `<project>/.claude/skills/<name>/SKILL.md` (project-scoped) following the same shape as the surrounding skills.

**If no -- skip.** Do NOT fabricate to fill the slot. Empty is the right answer most of the time, and bloating memory or the skills list with low-signal entries makes the high-signal ones harder to find later.

### 4c -- Promotion check: rules must not decay in memory

Auto-memory decays -- files get pruned, and recalls carry staleness warnings. For each memory written or touched during this story (including a tech-note just added in 4b), classify it:

- **State** (active work, incident records, references, notes tied to code that may change) -- stays in memory. Most memories are state.
- **A durable rule** ("how to behave", a standing policy, a permanent fact about the codebase or environment) -- promote it to a permanent home instead: the user's global CLAUDE.md (cross-project behavior), the project's checked-in CLAUDE.md (repo-permanent facts -- client-visible, so domain invariants yes, opinions about people or billing never), or a skill (procedures).
- **Already covered** by a permanent home -- delete the redundant memory.

After promoting a rule, keep its memory only if the incident narrative adds value the rule can't carry, and note the promotion inside it. If a rule-shaped memory can't be promoted right now, mark its frontmatter `promote: candidate` so a later sweep finds it cheaply.

### 4d -- Keep `MEMORY.md` within its size budget

Adding a Done entry (4a) grows `MEMORY.md` -- and that file is the index loaded into context *every* session, so it must stay lean. After the Done entry is in, prune the file back under budget. This runs every time an issue concludes, so the file can never silently drift over the limit.

- **Budget signal.** The auto-memory system surfaces a system-reminder when `MEMORY.md` exceeds its size limit (it reports current-vs-limit KB). Being at or over the limit is a hard prompt to prune *now*; even when under, opportunistically tighten while you are already here.
- **What to prune, in priority order:**
  1. **Old "Done" entries** -- the fastest-accreting section. A shipped issue's detail lives permanently in its plan file, git history, the PR, and any topic-memory it spawned, so its `MEMORY.md` entry only needs to be a findable pointer. Compress every Done entry except the most recent few to a single line: `**ID** Title -- shipped YYYY-MM-DD (<release or merge commit>); plan <path>`. Drop entirely any entry whose context is fully superseded (e.g. a fix later reverted or replaced by later work).
  2. **Multi-paragraph entries that are no longer in-flight.** Any entry that has grown to several sentences but is not *currently active* work should be reduced to a one-line pointer, with detail pushed into a topic-memory file per the auto-memory convention.
  3. **Stale "Active Work."** Anything already shipped should have moved to Done in 4a -- double-check none lingers.
- **Never prune:** Critical Workflow Rules, References, Project Conventions, topic-file pointers, or genuinely-current Active Work. Those are the high-signal, still-true index.
- **Confirm** the file is back under budget before finishing. If getting under budget would require removing something whose continued relevance you are unsure about, surface it to the user rather than deleting it.

## Step 5 -- Move the issue to its terminal Done state in the tracker

Recording the Done entry in `MEMORY.md` (Step 4a) closes the loop for *us*; it does NOT move the issue on the project's board. Close that loop too: transition the tracker issue (Linear, Shortcut, Jira, etc.) to its terminal **Done** state.

- **Mind intermediate post-merge states.** Many boards have a staging state between "in review" and "Done" -- e.g. **Deploy Queue**, "Awaiting Deploy", "On Staging", "Ready to Release". A shipped issue often sits in one of these, and "merged" or "deployed" does NOT mean the board already says Done. Check the current state and advance it the rest of the way.
- For Linear, use the bundled `linear` CLI (this plugin ships it on PATH; requires Ruby and `LINEAR_API_TOKEN`): `linear update <ID> --state "Done"` (the canonical terminal-state name for the team lives in the project's tracker-reference doc, if it keeps one).
- For GitHub Issues, done means closed. Check `gh issue view NNN --json state`; if the issue is still open (no linked PR closed it, or the repo disables auto-close), close it now with `gh issue close NNN`. Mind the timing: auto-close fires at merge to the default branch, and it is triggered by any linked pull request -- a `Closes #NNN` keyword or a branch from `gh issue develop` -- unless the repo disabled "Auto-close issues with merged linked pull requests". In Deploy-on-Merge Mode that timing is exactly right, so the issue is often closed already and this step is usually a verification. Outside the mode the merge precedes the deploy, so the issue should still be open at this point and this step is where the manual close happens.
- If the terminal state has a different name on this board ("Closed", "Shipped", "Released"), use that. If you are unsure which state is terminal, **ask the user** rather than guessing -- moving an issue to the wrong column is worse than asking.
- Skip only for ad-hoc work with no tracker issue.

## Step 6 -- Sibling-audit verification

If the plan called for a sibling-bug audit (spawning separate follow-up issues for variants of the same bug shape elsewhere in the codebase), verify those follow-ups were actually filed in the project's issue tracker.

To verify: list the issues created in the tracker since the story's branch-cut date, and cross-reference against the plan file's "filed as ISSUE-ID" mentions, branch commit messages, and the conversation history. The API pattern for the project's tracker is usually documented in CLAUDE.md (for Linear, the bundled `linear` CLI covers this; for GitHub Issues, `gh issue list --state all --search "created:>YYYY-MM-DD"` -- `--state all` matters, since the default omits follow-ups already closed -- cross-referenced against the plan file's "filed as #NNN" mentions); if you do not see it there, ask the user.

If anything was dropped, file it now via the project's API or surface it as a clear TODO for the user.

## Step 7 -- Stop any dev server started for this work

If a development server was started during this story -- most often to drive a manual browser walkthrough or otherwise verify the change in the running app -- stop it now so it does not linger across sessions holding a port.

- **Identify it:** a backgrounded `rails s` / `npm run dev` / `vite` / equivalent, or an app server process started inside the project's container.
- **Stop it:** kill the background job you launched, or terminate the process in the container. For a Dockerized Rails app, that is usually `docker exec <container> pkill -f 'rails s'`. Then **confirm it is actually gone** -- e.g. `curl` the port returns nothing, or `ps` / `docker exec <container> ps aux` shows no match.
- If no dev server was started this session, skip.

Do NOT stop the container itself or other long-running services (db, redis, sidekiq) -- only the app server you spun up for verification.

## Step 8 -- Task list housekeeping

Use `TaskList` to inventory tasks. First mark the plan's finish-tail tasks completed via `TaskUpdate` (mirroring the plan-file flips Step 2 made), then delete the ones tied to the finished issue via `TaskUpdate` with `status: "deleted"`.

Keep tasks for **other ongoing work** (different issue, different plan) untouched.

## Step 9 -- Permission-prompt sweep

A just-shipped story is the natural moment to trim future permission
prompts: the transcripts still hold the prompts answered while doing
the work, so allowlist proposals are fresh and every later story in
this repo prompts less. Run the sweep with the /fewer-permission-prompts
skill (a Claude Code built-in, not part of this plugin).

- **Availability.** If `fewer-permission-prompts` is not in the
  session's available-skills listing, or invoking it fails, skip with
  a one-line note ("Permission-prompt sweep skipped --
  /fewer-permission-prompts not available here") and move on -- this
  step never aborts the housekeeping pass.
- **Invoke it via the Skill tool** (skill name `fewer-permission-prompts`,
  no leading slash) **with args that scope the scan and gate the
  write.** The args must carry both: (a) scan only the current
  project's transcripts, and (b) present the prioritized proposals and
  stop for the user's explicit approval before editing any settings
  file, merging only the entries the user approves. Pass these args
  whether or not the built-in already scopes or pauses on its own --
  they are harmless duplicates when it does, and the enforcement when
  it does not (as of this writing the built-in scans across projects
  and writes immediately after presenting its list, so the args --
  not this skill's prose -- are what enforce project-scope and
  approval-first). Illustrative wording, which any paraphrase must
  keep both halves of: "Scan only this project's transcripts. Present
  the proposed allowlist and stop for my explicit approval before
  editing any settings file; merge only the entries I approve." If the
  user approves nothing, report that the sweep ran with no additions
  and move on.
- **Hold the gate yourself, then report what actually changed from
  `git status`.** You are the agent executing the built-in, so the
  approval gate is yours to hold -- it is not delegated to the
  built-in's own flow. If the settings file was written before the
  user approved, or carries entries they did not approve, treat that
  as a bug rather than a normal outcome: surface it and offer to
  revert the unapproved write (`git checkout -- <file>` when the file
  is tracked). Then check `git status` and name the settings file(s)
  actually edited (as of this writing the built-in targets the
  project's `.claude/settings.json`; if that file is gitignored,
  `git status` will not show it -- fall back to the built-in's own
  report of what it wrote). `git status` will also show the plan-file
  and any `MEMORY.md` edits from earlier steps, so name the settings
  diff specifically. This step can end the pass with an uncommitted
  settings diff, so say so plainly in the Step 10 summary. Committing
  stays with the user, through the project's normal flow -- possibly
  a PR, since in many projects that file is checked in and
  team-visible. Never commit or push it as part of this pass, and note
  that the diff sits on the branch checked out in Step 3 (usually
  `main`) and will otherwise ride into the next story's first commit,
  so flag it rather than leave it to be discovered.
- **Re-declines are expected.** The built-in dedupes only against what
  is already in the settings file, not against past declines, so a
  proposal the user declined on an earlier pass can resurface here.
  That is normal, not a bug to chase.

## Step 10 -- Summary

Report concisely what was done, one line per item:

- Plan file: finalized at `<path>` (or "skipped -- ad-hoc work").
- Branch: `<name>` deleted (or "no local branch").
- Tracker: `<ID>` moved to Done (or "no tracker issue").
- Memory: Done entry added; N new tech-notes saved; N new skills created; N rules promoted to permanent homes; MEMORY.md pruned (now <size> KB, under budget).
- Sibling-audit: N follow-ups verified; M dropped (filed now / TODO).
- Dev server: stopped (or "none was running").
- Task list: N completed tasks cleared.
- Permission-prompt sweep: N additions in `<settings file>`, left uncommitted (or "nothing approved" / "skipped -- built-in unavailable").

End with "Housekeeping complete."
