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

## Lead with why

Open every PR description with a short Why paragraph: the
user-visible outcome or the reason the change exists, before any What
or mechanism content. A tracker-reference line (an issue link, or
`Closes #NNN` when the PR fully resolves the issue) may sit above it,
but the first prose paragraph is the Why. This is the same why-first
principle commit titles follow in the commit-messages guidance:
motivation first, mechanism second. For a change that remedies
something, the strongest Why names the concrete cost of leaving
things as they were.

## Write descriptions for the reader

When a PR description mentions an outside resource -- a spec, a
library's docs, a standard, an article -- turn its first mention into
a link. Readers unfamiliar with the resource get the source; familiar
readers get the convenience of a click.

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
request as far as it can alone: green, current with the default
branch, and marked ready for review. Then it hands off and says what
the PR is waiting on; finishing that preparation is the deliverable.

Arming auto-merge is merging with a delay. `gh pr merge --auto` still
causes the merge with no human in the loop, so it falls under this
rule rather than around it.

A direct instruction authorizes that one merge, confirmed back first:
name the direction per the rule below, say what lands, and say that a
merge cannot be taken back. Then wait. Anything landing commits on a
shared branch gets that confirmation; the safe direction -- "merge
`main` into the branch" -- gets none. It authorizes an ordinary merge
and never forcing one past a gate that refused it: a merge blocked by
branch protection or missing approvals is the gate working, and
`--admin` is not the remedy. The usual way back from a merge that
should not have happened is a revert pull request, following the
revert convention in the commit-messages guidance.

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

A stacked chain (each PR based on the previous PR's branch) merges in
order, and the cascade is driven by branch deletion, not by merging.
One invariant protects every step: **never merge a PR whose base is
not the branch its work should land on.** Once every slice below a PR
is merged, its base must be the mainline (the repo's default branch)
-- a base still naming an already-merged slice's branch means stop
and retarget before doing anything else:

- **Deleting the merged PR's head branch is what triggers the
  automatic retarget -- the merge itself never does.** When the head
  branch of a merged PR is deleted, GitHub retargets open PRs that
  targeted it to the merged PR's own base (the
  [pull request retargeting changelog](https://github.blog/changelog/2020-05-19-pull-request-retargeting/)
  describes the behavior). Merging without deleting leaves the next
  PR aimed at the stale branch -- and merging that PR then lands its
  work on a side branch instead of the real target, silently and
  successfully. The per-slice sequence that maintains the invariant:
  check that this PR's base is the mainline (retarget it if not),
  merge, delete the head branch, and confirm the next PR's base
  actually flipped. That sequence is the order the steps must happen
  in, not permission to perform them. Per Who presses Merge above,
  the merge is the human's, and so is deleting the head branch --
  the merge UI offers the two together. A session's part in each
  slice is to retarget before handing off, then, once the merge
  lands, to confirm the next PR's base actually flipped and report
  what it finds. The confirm steps earn their place: `gh pr merge
  --delete-branch` runs a client-side merge-then-delete sequence
  with a long-standing race that can skip the retarget or close the
  dependent PR outright
  ([cli/cli#1168](https://github.com/cli/cli/issues/1168)). A base
  that did not flip is set by hand with
  `gh pr edit <number> --base <target>` or the Edit button on the PR
  page. A PR the race closed cannot simply be reopened -- GitHub
  refuses while the PR's base branch no longer exists, and a closed
  PR's base cannot be edited -- so restore the deleted branch (the
  merged PR's "Restore branch" button), reopen, retarget, and delete
  the branch again, or open a fresh PR from the same head branch.
  The "Automatically delete head branches" repo setting moves the
  deletion to merge time; keep the confirm step there too.
- **Expect approvals to drop at each retarget.** GitHub marks an
  approval stale when a retarget moves the PR's merge base in a way
  that changes what the approval covered -- squash and rebase merges
  below it all but guarantee this; a clean merge-commit chain can
  escape it -- and a repo with stale-review dismissal enabled
  dismisses stale approvals outright (the
  [required-approvals security changelog](https://github.blog/changelog/2023-06-06-security-enhancements-to-required-approvals-on-pull-requests/)
  describes the mechanism). Plan for a quick re-approval per slice;
  asking for it while CI runs keeps the chain moving.
- **A retarget alone triggers no new CI run.** A base change is not
  among the `pull_request` activity types workflows listen to by
  default (only a workflow that opts into `edited` sees it), and
  required checks are named in the target branch's protection rules,
  not in the branch under test -- so a retargeted PR whose existing runs
  never reported a newly required or renamed check waits forever on
  a context marked "Expected". Workflow files do ride the branch
  under test, so a stale branch also runs outdated CI config. Both
  problems share one remedy: update each branch from the default
  branch before merging it, which refreshes the workflows and
  triggers a fresh run.
- **A merged PR can never be reopened or retargeted, and approvals do
  not transfer between PRs.** Recovering from a wrong-base merge means
  a fresh PR from the same head branch (the content is intact); the
  old PR's approval is evidence to cite, not something to carry over.

Two adjacent traps: on a squash-merge repo, a retargeted PR shows the
just-merged slice's commits in its diff again until the branch is
updated from the default branch (the squashed copy is a new commit
the fork point predates); and auto-merge armed on the next PR before
its base flips is the wrong-base merge with no human in the loop --
arm it only after confirming the retarget, and only where arming is
authorized at all, since arming is itself a merge.
