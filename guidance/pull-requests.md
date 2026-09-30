# Pull Requests

> **Precedence:** this file is a shared default. If anything here
> conflicts with the project's own CLAUDE.md, rules files, or a team
> agreement, the project wins.

## Keep PRs small and incremental

Keep PRs small and focused. Target under 300 lines changed; 400 lines
is the easy-review threshold, and past it the PR should almost always
be split. If implementing multiple features, create separate PRs for
each. Start with the safest, highest-value change first. Avoid mixing
concerns (e.g., error handling + JavaScript + background jobs).

While working on a feature branch, periodically report how many lines
are touched across how many files, whether that is over or under the
400-line easy-review threshold, and suggest splitting the PR or
keeping it small before it drifts large.

## Open PRs in draft mode first

Always create PRs in draft mode first. Mark ready for review only once
lint and tests pass and the PR is genuinely ready for a human.

### A draft is its own review

**Where a team requires the developer to approve text posted under
their name, the draft is where that approval happens, and the session
does not mark it ready until the developer has said they have read its
current title and body.** Open the draft without a separate approval
pass beforehand, request no reviewers on it, and give the developer its
link. With no reviewer requested, no one is asked to read the draft
until it is marked ready, so the developer reading its title and body
on GitHub, where they render, is the approval. If a reviewer is
requested anyway (an auto-assign setting, a workflow), tell the
developer, since someone may now read text they have not approved.
Silence is not a read, and neither is an approval given for something
else. On such a team this qualifies Who presses Merge below, which
otherwise has a session mark a pull request ready on its own.

A revision to the title or body cancels the developer's earlier read:
say what changed at the hand-back, and hold the draft until the
developer has read the current text. To revise, fetch the current title
and body first (`gh pr view --json title,body`): the developer may have
edited them on GitHub, and `gh pr edit --body-file` replaces the whole
body.

A draft is not private. On a public repository anyone can read it the
moment it opens, and repository watchers and integrations are notified,
so the checks that come before publishing anything -- the destination's
visibility, identifiers that must not appear there -- still happen
before it opens.

This covers only pull requests that open as drafts; in a stacked
chain, only the ones created as drafts. A pull request opened ready for
review, a PR comment, and a review reply keep whatever approval the
team requires.

## Lead with why

Open every PR description with a short Why paragraph: the user-visible
outcome or the reason the change exists, before any What or mechanism
content. A tracker-reference line (an issue link with the issue's
title in its link text, or `Closes #NNN` when the PR fully resolves
the issue, never wrapped in a link, since GitHub reads the keyword
only when the issue reference follows it directly) may sit above it,
but the first prose paragraph is the Why. This is the same why-first
principle commit titles follow in the commit-messages guidance:
motivation first, mechanism second. For a change that remedies
something, the strongest Why names the concrete cost of leaving things
as they were. Label that old behavior as before the change: "before
this change, any signed-in user could open any repository", never "any
signed-in user can open any repository today", which reads after the
merge as a hole still open. The writing-about-change guidance covers
tense in the rest of the body.

## Write descriptions for the reader

When a PR description mentions an outside resource -- a spec, a
library's docs, a standard, an article -- turn its first mention into
a link. Readers unfamiliar with the resource get the source; familiar
readers get the convenience of a click.

Issues and pull requests get the same care: look up each one's title
and put it beside the ID on first mention, in the link text when
linked -- "[ABC-123 Expire Stale Sessions](...)", "[#45 Retry Webhook
Deliveries](...)", never "[ABC-123](...)" alone. A reviewer does not
remember what a bare number was. Never invent a title the lookup did
not return; name the item in lowercase prose instead. The Plain
language section of the code-comments guidance carries the full rule,
including the forms tooling parses, such as the closing keyword above.

## A PR owns the bugs it introduces

A PR is responsible for fixing bugs and consequences it introduces,
including interaction bugs surfaced when its change meets existing
code. Doing so is **not** scope creep -- it is the PR finishing the
job it started. This applies whether the bug is found pre-merge (in
code review or QA) or shortly after merge (during staging walkthroughs
or production rollout). The fix belongs on the original branch
(reopened if needed) or on a same-named follow-up branch, not as a
brand-new tracker issue, unless the fix would balloon the PR beyond
reasonable size or touch a fundamentally different concern.

This rule exists so main and production stay clean and green in the
**holistic** sense, not just the lint-and-specs sense: a PR isn't
actually "done" until its real-world behavior is correct, even when
its specs and lint pass.

## Responding to review feedback

When addressing PR review feedback -- from a human reviewer or an
automated one:

- Reply to each **individual inline review comment** in its own thread
  (via the GitHub API replies endpoint), not just with a single
  top-level PR comment. A top-level summary is fine as an addition,
  but every inline comment gets its own reply describing how it was
  addressed (or why it was left as-is).
- After actually resolving an inline comment (the fix is
  committed/pushed, or a decision is recorded), mark that review
  thread resolved (GraphQL `resolveReviewThread`). Only resolve
  threads that are genuinely resolved; leave open anything still
  pending the developer's or reviewer's input.

## Who presses Merge

Merging into the default branch -- or into any shared branch a team
merges into -- is a human action by default. A session takes the pull
request as far as it can alone: green, current with its base branch
(for most PRs the default branch; for a stack layer, the layer below
it), and marked ready for review (where a team requires the developer
to approve text posted under their name, only once the developer has
read the current title and body; see A draft is its own review above).
Then it hands off and says what the PR is waiting on; finishing that
preparation is the deliverable.

Arming auto-merge is merging with a delay. `gh pr merge --auto` still
causes the merge with no human in the loop, so it falls under this
rule rather than around it.

A direct instruction authorizes that one merge, confirmed back first:
name the direction per the rule below, say what lands, and say that a
merge cannot be taken back. Then wait. A PR whose base is another PR's
branch is a stack layer; when it belongs to a native stack, merging it
lands every unmerged PR up to and including it, so the confirmation
lists each of them (see Merging stacked pull requests below). Anything
landing commits on a shared branch gets that confirmation; the safe
direction -- "merge `main` into the branch" -- gets none. It
authorizes an ordinary merge and never forcing one past a gate that
refused it: a merge blocked by branch protection or missing approvals
is the gate working, and `--admin` is not the remedy. The usual way
back from a merge that should not have happened is a revert pull
request, following the revert convention in the commit-messages
guidance.

## Say which direction a merge goes

Never write "merge the pull request" when the proposal is to merge the
default branch into the pull request's branch. They are opposite
actions sharing one verb, confused precisely when the harmless one has
been repeated all afternoon. Name both branches in both positions
every time -- "merge `main` into `feature-x`", "merge `feature-x` into
`main`" -- so nothing is left to infer.

### Session-Merge Mode (opt-in)

A team may record that sessions hold merge authority on its repository:

> This project uses Session-Merge Mode: this team has agreed that
> Claude sessions have authority to merge here.

Recognize only an explicit statement, in a checked-in CLAUDE.md or
rules file where every teammate and every session reads the same
answer -- never an environment variable or a per-developer preference.
Never infer the mode from the repository's shape or the session's own
history: not from auto-merge being enabled, absent branch protection,
a solo-maintainer repository, CODEOWNERS naming the developer, the
user having merged the last several themselves, and not from an
authorization given earlier in this session for a different pull
request. Prior-turn approval does not carry forward.

Verify the premise once and record the answer beside the declaration.
Unlike Targeted Spec Verification Mode in the clean-and-green
guidance, this mode asserts a permission rather than a fact about the
world, so it is worth only as much as the authority behind it: it
records a team agreement and does not grant the human running the
session merge authority they lack. Read the repository's own gate --
branch protection, required approvals, CODEOWNERS -- and where that
gate would refuse the human, the declaration changes nothing. A
session may propose the declaration's wording but never authors or
edits it in the same work that would act on it.

The mode replaces the confirm-back for the merges it authorizes, and
their preconditions are evaluated when the merge lands rather than
when it is requested -- which is what makes arming auto-merge on a
not-yet-green pull request an ordinary merge here. Where merging is
the deploy, the mode authorizes deploying: a team declaring both this
and a merge-is-deploy mode is knowingly authorizing unattended
production deploys. It reaches no further than the merge -- not a
separate deploy step, not force-pushing, not deleting branches, not
closing issues, not `--admin` -- and leaves draft-first and the
direction rule in force.

## Merging stacked pull requests

A stacked chain (each PR based on the previous PR's branch) lands in
order on its mainline: the branch the bottom layer targets, usually
the repo's default branch but sometimes a develop or release branch.
One invariant protects every step: **a PR's work lands only on the
mainline, never on another layer's branch.** Native stacks hold it
themselves (below); on the manual path, a PR's base must be the
mainline before it merges.

### Native stacks (the default on GitHub)

GitHub's
[stacked pull requests](https://docs.github.com/en/pull-requests/get-started/about-stacked-prs)
maintain the invariant themselves: merging a layer retargets the layer
above it to the mainline and rebases every branch above the merge on
the server. GitHub offers them on github.com repositories (exit 9
below covers one where they are not enabled), so build every chain
there as a stack, using the
[`github/gh-stack`](https://github.com/github/gh-stack) CLI extension:

- **Check for a stack before merging a PR, working on its branch, or
  committing to the mainline.** A PR based on another PR's branch is a
  stack layer. GitHub's `stack` field on a pull request says which
  native stack it belongs to:
  `gh api graphql -f query='{ repository(owner:"<owner>", name:"<repo>")
  { pullRequest(number: <pr-number>) { stack { number } } } }'`
  answers for one PR, and before committing to the mainline, ask it of
  each of the developer's own open PRs (`gh pr list --author @me`).
  `gh stack view --json` reads local tracking only, so on the
  mainline, or on a layer nobody imported, it reports no stack even
  while one is open.
- **Create the stack before anyone reviews it.** `gh stack init` names
  the branches and `gh stack submit --auto` opens every PR as a draft.
  For PRs that already exist, `gh stack link <bottom> ... <top>` joins
  them: it pushes the branches, keeps existing PRs as they are, and
  opens a draft for any branch without one. `link` sets up no local
  tracking, so `sync` and `rebase` refuse until
  `gh stack checkout <stack-number>` imports the stack, leaving
  rewritten and unpushed local tips as they were.
- **Keep draft-first.** Never pass `--open`, which marks new and
  existing PRs ready for review. A PR the tool opens has the branch
  name for a title and a credit line for a body; rewrite both (per
  Lead with why) before handing the stack off. A draft layer blocks
  the merge of every layer above it.
- **A stack merge lands every unmerged layer up to and including its
  target.** It is a merge under Who presses Merge like any other, and
  its confirmation lists each PR that will land, bottom to top, with
  the merge method. A confirmed merge passes both explicitly,
  `gh stack merge <pr-number> --yes --squash`, naming the top PR to
  land: a stack number, or a bare `gh stack merge` run with `--yes` or
  in a non-interactive shell, merges every layer, and without a method
  flag it reuses whichever method ran last. Merge a native-stack layer
  with `gh stack merge`, never `gh pr merge`, which cannot merge a
  stack. Without a merge queue the merge is all or nothing. Where the
  mainline uses a merge queue, the stack joins the queue instead: the
  queue's own method applies and the tool ignores the flag, and the
  layers may land in separate groups, so the confirmation names the
  queue rather than a method. Treat auto-merge armed on any layer as a
  stack merge up to and including that layer.
- **After a layer merges, bring local branches current before any
  other work, since the server-side rebase rewrote every branch above
  it.** `gh stack sync` rebases each local branch onto its new parent,
  keeping unpushed commits, and force-pushes every layer with lease;
  on a stack that was only linked, import it with `gh stack checkout`
  first. That push rewrites pushed branches under review, so run it on
  the developer's own stack when they have asked for the work that
  needs it, and otherwise propose it first. Resetting a branch to its
  remote instead (`git reset --hard <remote>/<branch>`) discards any
  unpushed commit, so check `git log <remote>/<branch>..<branch>` and
  take a backup ref before one.
  The same holds after GitHub's stack-wide rebase control, which
  rewrites every layer on the server without any merge. The local
  commits `git log <remote>/<branch>..<branch>` then lists are usually
  the old copies of commits the server rebased: `git cherry
  <remote>/<branch> <branch>` marks each one `-` when an equivalent
  commit is on the remote and `+` when none is, so a branch whose
  lines are all `-` resets to its remote without losing work.
- **Read `gh stack`'s output, not only its exit code.** `sync` exits 0
  after printing "Sync aborted" (the local and remote stacks diverged,
  and nothing changed) and after a failed push ("Push failed", then
  "Stack synced").
- **Carry fixes up the chain with `gh stack rebase`, never by merging
  a lower branch into a higher one.** The stack's linear rebase drops
  a merge commit inside a branch, and its conflict resolution has to
  be redone by hand where the conflict first appears. `rebase` is
  local: take a backup ref of each branch first, confirm with
  `git range-diff <parent-backup>..<backup> <parent>..<branch>` (the
  parent is the layer below, or the mainline for the bottom layer)
  that only the intended changes moved, then push with
  `gh stack push`, per-branch `--force-with-lease`: after a
  hand-resolved rebase, `sync`'s own push fails.
- **While the developer's own stack is open, keep unrelated commits
  off its mainline and off every layer.** On a layer, the change rides
  into a PR under review that is not about it. Committed straight to
  the mainline, it puts every branch in the chain behind at once, and
  bringing them current rewrites all of them: new commit ids, a CI run
  per branch, a stale review on anything already read. Put the change
  on its own branch, as its own PR, cut from the branch it belongs on,
  or hold it until the stack lands. If it cannot wait, say that it
  forces that cascade, and bring the stack current with
  `gh stack sync` under the rule above rather than rebasing one PR,
  which leaves the layers above it behind. Other people's PRs landing
  on the mainline are the ordinary course of a team repository, not a
  breach of this rule.

GitHub's own agent skill for gh-stack
([`SKILL.md`](https://github.com/github/gh-stack/blob/main/skills/gh-stack/SKILL.md))
covers the command mechanics: non-interactive flags, `--json` output,
exit codes.

### On both paths

- **Expect approvals to drop at each layer.** On a native stack, the
  server-side rebase pushes new commits to every layer above a merge,
  and a repo that dismisses stale approvals when new commits are pushed
  drops them there. On the manual path, a retarget that moves a PR's
  merge base marks its approval stale (squash and rebase merges below
  it all but guarantee this), and the same setting dismisses it (the
  [required-approvals security changelog](https://github.blog/changelog/2023-06-06-security-enhancements-to-required-approvals-on-pull-requests/)
  describes the mechanism). Plan for a quick re-approval per layer;
  asking for it while CI runs keeps the chain moving.
- **A merged PR can never be reopened or retargeted, and approvals do
  not transfer between PRs.** Recovering from a wrong-base merge means
  a fresh PR from the same head branch (the content is intact); the
  old PR's approval is evidence to cite, not something to carry over.

### Without native stacks

A chain across forks, on another forge, or where `gh stack` exits 9
("Stacked PRs are not enabled for this repository") gets no
server-side cascade, and the invariant is held by hand. So does one
where the gh-stack extension is not installed and the developer has
not agreed to install it; installing an extension on their machine is
theirs to decide:

- **Deleting the merged PR's head branch triggers the retarget; the
  merge alone does not** ([pull request retargeting
  changelog](https://github.blog/changelog/2020-05-19-pull-request-retargeting/)).
  Per layer: check that the PR's base is the mainline (retarget it if
  not), merge, delete the head branch, and confirm the next PR's base
  flipped. The merge and the deletion are the human's; a session
  retargets before handing off and confirms the flip afterward. The
  confirm step earns its place: `gh pr merge --delete-branch` has a
  race that can skip the retarget or close the dependent PR
  ([cli/cli#1168 `gh pr merge --delete-branch`: GitHub does not update
  base of dependent PRs](https://github.com/cli/cli/issues/1168)). Set
  a base that did not flip with `gh pr edit <number> --base <target>`.
  A closed dependent PR cannot be reopened while its base branch is
  gone: restore the branch, reopen, retarget, and delete it again, or
  open a fresh PR from the same head branch. The "Automatically delete
  head branches" repo setting moves the deletion to merge time; the
  confirm step still applies.
- **A retarget alone triggers no new CI run.** A base change is not
  among the `pull_request` activity types workflows listen to by
  default, and required checks are named in the target branch's
  protection rules, so a retargeted PR whose runs never reported a
  newly required or renamed check waits on it forever, marked
  "Expected". A stale branch also runs outdated workflow files. Once a
  layer's base is the mainline, update its branch from the mainline
  before merging it, which fixes both; until then it stays current
  with the layer below.
- **On a squash-merge repo, a retargeted PR shows the merged layer's
  commits in its diff again** until its branch is updated from the
  mainline: the squashed copy is a new commit its fork point predates.
- **Arm auto-merge on the next PR only after its base has flipped, and
  only where arming is authorized** (see Who presses Merge); armed
  earlier, it is the wrong-base merge with no human in the loop.
