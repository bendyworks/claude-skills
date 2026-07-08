---
name: bug-cluster-ledger
description: Mine a time window of tracker issues (Linear, Shortcut, GitHub) and cluster them UPWARD to root causes per subsystem, producing a cluster table with counts and ownership, prevention analysis for each big cluster, and a "biggest unowned work-generator" verdict. Use when the user asks to "cluster this year's bugs", "root-cause our issues", "what's our bug tax", "what keeps generating bugs", "which subsystem is costing us", "find the next <recurring problem>", or as Phase 1 of an architecture-survey. Read-only against the tracker.
---

# Bug-Cluster Ledger

Turn a season of tracker history into a root-cause map. The point is NOT a
per-issue tally ("we fixed 40 bugs") but the inversion: which few structural
causes generated most of the work, and which of those causes nobody owns.
On its proving run this pass found that two "twins" of one unowned root
cause had generated more issues than the problem everyone assumed was the
biggest -- that verdict re-aimed the whole refactoring backlog.

## Inputs

- **Window**: default = year-to-date; any "since" date works.
- **Tracker access**: a CLI/API that lists all of a team's issues created
  since a date, INCLUDING completed ones (shipped bugs are the signal). If
  the project's tracker CLI lacks a list-since subcommand, extend the CLI --
  do not fall back to raw API calls or hand-paging.
- **Cheaper first source**: if the project keeps an agent-memory "Done"
  ledger or changelog that narrates shipped work with root causes, start
  there; use the tracker to fill gaps. It routinely covers most of the
  clusters at a fraction of the reads.
- **Untracked-fix mining (when tracker hygiene is imperfect)**: firefighting
  often ships with no issue at all. Mine merged PRs / commits in the window
  for fix-shaped titles (fix/broken/bug/regression/wrong) that carry NO issue
  reference, and count them into the clusters. Report the share of merged PRs
  with no issue -- a high share is itself a finding, and counting only filed
  issues under-weights the subsystems that get quietly hot-patched.
- **Subsystem taxonomy**: if an architecture survey fixed one, use its tags
  verbatim; otherwise define 5-8 subsystem tags before clustering and stick
  to them.
- **Known hypotheses** (optional): standing suspicions to confirm or refute
  with counts, stated as hypotheses, not conclusions.
- **Excluded/owned territory** (optional): epics that already own a root
  cause -- their clusters still get counted, but separately, so the verdict
  can distinguish "covered" from "unowned".

## Method

1. Pull the full issue list for the window (`--all` states). Read titles
   first; fetch full issue bodies selectively -- only where the title does
   not reveal the root cause (expect ~10-15% of issues to need a full read).
2. Assign each issue to a root-cause cluster, not a topic. "Fee display
   bugs" is a topic; "stored money columns drift from the application
   ledger" is a root cause. Force the upward move: for every bug ask "what
   structural fact made this bug possible?" and cluster on that.
3. Issues that are features, chores, process, or tooling are set aside
   explicitly (counted, not clustered). A few genuinely unclassifiable
   issues are fine -- name them rather than forcing a fit.
4. For each cluster record: name, subsystem tag, one-line root cause, issue
   count, the issue IDs, and OWNERSHIP -- is the root cause already owned by
   a filed epic/issue, partially owned (symptoms filed piecemeal, no
   structural owner), or unowned?
5. Watch for **twin clusters**: the same root cause manifesting as two
   different symptom families (e.g. a correctness twin and a performance
   twin). Summing twins is often what changes the verdict. A specific blind
   spot: twins whose symptoms land on **different teams** (a sync bug that
   hits sales vs one that hits the marketplace) -- nobody sums them because
   nobody sees both, so the biggest unowned generator hides in plain sight.
   Cluster on the shared root cause, not on which team filed it.

## Deliverable

1. **Cluster table**: cluster / tag / root cause / count / IDs / ownership.
2. **Prevention paragraph for every cluster of 3+ issues**: what single
   structural change would have made the cluster unrepresentable. Past
   tense, concrete, testable ("a draw-down ledger from day one", not
   "better testing").
3. **The verdict**: setting aside owned and excluded clusters, name the
   biggest unowned work-generator and the runner-up -- with the runner-up
   judged on severity-per-issue, not just count (six phantom-money bugs can
   outrank twenty cosmetic ones).
4. **Coverage accounting**: total issues reviewed, how many clustered, how
   many set aside by category, how many unclassifiable (list them). The
   ledger's credibility rests on this line.
5. **Process-evidence appendix (when a process hypothesis is in play, e.g.
   run inside a survey)**: the git/tracker history you already pulled cheaply
   yields hard numbers for the organizational costs everyone feels but nobody
   measures -- approved-to-merged latency (median/p90/max), count of open PRs
   whose approval has rotted past 60 days (with the oldest), started-but-not-
   finished issue count and age distribution, and the share of merged PRs with
   no issue reference. Keep this SEPARATE from the clusters: it is process, not
   a code root cause, and it goes to whoever owns process, not into the
   refactoring backlog.

## Cadence and follow-through

- Useful standalone on a quarterly or yearly cadence, and as the
  before/after check on a shipped epic: did its cluster actually stop
  growing?
- Cluster counts feed directly into refactoring-backlog ranking (they are
  axis 1 of the architecture-survey rubric).
- If the verdict names an unowned root cause, the natural next step is
  filing a structural owner for it (epic or spike) -- offer it, with the
  cluster's issue list attached as evidence.
