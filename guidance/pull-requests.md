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
