---
name: architecture-survey
description: Run a domain-first architectural-simplification survey of a mature codebase and turn it into a ranked, tiered, tracker-ready refactoring backlog -- explicitly including the large, scary candidates nobody has had the guts, authority, or time to take on. Use when the user asks to "find architectural improvement opportunities", "survey the codebase for simplification", "find what to refactor away", "tech-debt audit", "what should we simplify next", or wants a ranked refactoring backlog. Survey only -- no refactoring happens inside it.
---

# Architecture Survey

A repeatable method for answering "what needless complexity should this
project retire, one issue at a time?" The output is a ranked candidate list
with full reasoning on a tracker issue, an umbrella epic, a first batch of
prioritized child issues, and a parked next-batch issue. Proven start-to-
finish in one working day on a ~10-year Rails app.

## Calibration lessons (why the method is shaped this way)

These were learned the hard way; do not relearn them:

1. **Tool passes are evidence, not discovery.** flog/flay/debride/lint-todo
   output surfaces small, local debt and re-derives what churn already says.
   The large structural candidates come from the domain passes: top-down
   critique, bug-cluster history, and documented confusion. Weight effort
   accordingly -- the mechanical pass is a timeboxed appendix, never the
   centerpiece.
2. **Documented confusion is a pre-compiled complexity inventory.** Every
   standing CLAUDE.md warning, memory trap note, glossary apology ("X
   actually means Y"), and keep-in-sync-by-hand checklist exists because the
   code confused a competent person. Each is one candidate finding, already
   justified. This pass routinely outperforms every tool.
3. **A challenge review is mandatory before executing.** Dispatch a fresh
   subagent to cold-read the survey plan. The first draft of the proven run
   was bottom-up-heavy and would have produced a lint list; the cold read is
   what aimed it at the big game. Do not skip this because the plan "looks
   right".
4. **Size never disqualifies a candidate.** The whole point is surfacing
   refactorings nobody had the authority or nerve to propose. A big
   candidate earns an honest confidence tier and, when the route is unknown,
   a spike -- not a quiet omission.
5. **A legitimate pattern is not automatically debt.** "Two of everything"
   (two API versions, two of a component) reads as the dual-path smell, but
   parallel *public API* versions are normal, customer-respecting practice --
   serving v1 while customers migrate to v2 is correct. Separate the two
   questions: does the duality exist (often fine), and is it maintained badly
   (copy-paste instead of a shared core, security-relevant drift, a
   half-built-then-abandoned retirement flag)? Only the second is the finding,
   and its fix is usually "stop maintaining two copies + close the drift," not
   "kill the old one" -- let real production traffic, not the survey, decide a
   version's lifecycle. Do not let a tidy narrative flatten a real distinction;
   a reviewer in the room will call it out.
6. **Sibling-repo facts go stale silently.** A critic reading a sibling repo
   (the other service, a shared gem) reports whatever that local checkout
   happens to be pinned at -- which may be months or years behind its remote,
   producing confident-but-false cross-service claims ("their schema is frozen
   at 2024"). Re-verify every load-bearing sibling-repo fact against a fresh
   pull at synthesis time, and prefer stating cross-service claims in a form a
   teammate can immediately contradict (exact version/commit/date), so a stale
   read surfaces as a correction, not an enshrined error.

## Project inputs (parameterize; never hardcode one project's)

Collect these before starting:

- **Tracker access**: CLI or API that can list a team's issues since a date
  (and read/create/update issues). Extend the project's existing tooling if
  a needed subcommand is missing.
- **Telemetry source**: APM (New Relic, Skylight, Scout...) credentials if
  available; error tracker only if a token actually exists -- demote to
  "conditional" otherwise, do not let the pass stall.
- **Runtime**: container name / test runner / how to run one-off tools.
- **Documented-confusion sources**: project CLAUDE.md, agent memory
  directory, glossary/docs, any hand-maintained sync checklists or impact
  inventories, plans/gauntlet/review archives. **Also any team-wide PM
  artifact** -- recurring-meeting notes (retro/round-table topic lists with
  vote counts), a standing tech-debt backlog. Weight these ABOVE single-dev
  plan archives: a topic three people voted up is team-wide corroboration; a
  private plan file reflects one contributor's slice. When the survey's own
  archives are one part-time dev's, say so and down-weight them explicitly.
- **Cross-service sibling repos**: if the app is one of several services
  (a sibling redirect/worker service, a shared gem, a devops/schedulers repo),
  list them up front and make "cross-service-contracts" a first-class Phase-0
  subsystem. The load-bearing contracts that no repo's CI covers -- shared
  databases, job-class-name strings scheduled from outside the repo, command
  strings consumed by another service, a shared gem pinned at different
  versions per repo -- are a recurring top-severity blind spot, because a
  rename breaks production, never a test. Give this critic read access to the
  siblings; keep its findings scoped to THIS repo's side, naming the other
  side's internals as an explicit blind spot.
- **Excluded territory**: epics or upgrades that already own their ground.
  Record them up front for the boundary rule.
- **Scale ground-truth (when scale is a hypothesis)**: local/dev databases
  cannot answer "how big is the giant table" (dumps are downsized or broken).
  Add a setup task: the user runs a read-only production size query
  (`pg_total_relation_size` / row estimates) and pastes results. Until it
  lands, mark every scale claim "schema-shape inference, prod numbers pending"
  rather than stalling -- and ride the "which competing writer/scheduler runs
  last, how often" question along with it (cron cadence often lives in the
  out-of-repo schedulers).
- **Approval gate (optional, user-set)**: some orgs want leadership buy-in
  BEFORE any tracker writes. If so, the deliverable is a shareable proposal
  doc first (ranked list + intended epic/story shape + a clearly-separated
  process-observations appendix), and NO epic/stories are created until
  approved. Gate this explicitly; do not create tracker items on spec.

## Method

### Phase 0 -- top-down subsystem critique (run FIRST)

Enumerate the app's major subsystems (typically 5-10). Beyond the obvious
domain subsystems, two tags earn a default slot in most apps and are easy to
omit: **auth-tenancy** (authN/authZ, multi-tenant isolation -- security-
sensitive, and a missed tenant scope is the top severity rung) and
**cross-service-contracts** (the seams to sibling repos, per the input note).

Give every critic the SAME prompt spine:
- The rebuild question, VERBATIM: "if we rebuilt this today, what would we NOT
  rebuild, and what does keeping it cost?"
- An explicit **dual-path hunt**: a new way built without retiring the old
  (v2 vs legacy, two implementations of one concern) -- and lesson 5's caveat
  so critics don't flag legitimate parallelism as debt.
- An explicit **dead-code hunt** in its territory (dead routes, dead screens,
  never-wired workers, unreachable branches), with every "dead" claim
  call-site-grepped -- and a reminder that some invokers live OUTSIDE the repo
  (job-class strings in a schedulers repo, command strings in a sibling
  service), so "no in-repo caller" is not "dead" until the siblings are
  checked.
- A **cap of 3-5 honestly-sized candidates** per critic. This is the single
  most important anti-lint-list lever at the critic layer: uncapped, a critic
  fed a file list returns per-file nits that Phase 4's cap never touches.

This produces the hypothesis list every later pass confirms or refutes, and
the fixed subsystem tag taxonomy every finding carries.

"This subsystem is healthy -- leave it alone" is a valid and valuable
verdict; instruct critics to check churn and bug history before claiming
pain (and to spend that verdict generously -- the proven runs found the live
core healthy and the rot concentrated at the edges in almost every subsystem).

### Phase 1 -- bug-cluster ledger

Use the `bug-cluster-ledger` skill (bundled in this plugin; its own
SKILL.md governs the details). Key demand: cluster issues UPWARD to root causes per subsystem,
not per-issue tallies, and deliver a "biggest unowned work-generator"
verdict. Its per-cluster counts are rubric axis 1.

### Phase 2 -- institutional-memory mining

Mine every documented-confusion source (lesson 2). For each warning/trap/
apology: what confusion it records, what structural change would delete the
need for it, size guess. Also mine plan/review archives for hot zones (a
plan that spawned 3+ follow-ups marks one) and deferred punch-list items
worth resurrecting. Produce a per-subsystem "documentation debt score"
(count of standing warnings + traps + sync pairs) -- rubric axis 2.

### Phase 3 -- schema + telemetry

Schema crossed against models: misleading names, missing FKs/indexes,
validation-vs-schema drift, race-prone in-app counters, integer money
columns, write-only columns, and -- critically -- the complete inventory of
stored-but-derivable state (running totals, cached balances, satisfied
flags). Stored-derivable drift is a recurring root cause across projects.
Telemetry: top transactions by duration and throughput, crossed against
churn -- friction = slow AND high-churn. Look past already-filed per-endpoint
issues for structural patterns ("every report is slow for one shared
reason").

### Phase 4 -- mechanical-metrics appendix (timeboxed ~2h)

One agent: churn x complexity quadrant (git churn since the window start
crossed with flog per-file totals), flay top-10 with real-vs-idiomatic
verdicts, lint-todo structural skim, dependency/gem skim for stack-level
liabilities and upgrade-blocking pins, routes-vs-actions cross-check, and at
most a 15-minute dead-code-tool skim. Cap at 10 findings. A `lint-todo` file
(rubocop_todo / standard_todo) is worth more than its reputation: its waivers
cluster by subsystem and include correctness cops (removed-API idioms,
duplicate-method shadowing, request-reachable `open()`), so it doubles as a
map of the legacy layer -- skim it by cop family, not by file. Tool recipes:

- Install analysis gems as one-offs inside the container (`gem install flog
  flay debride --no-document`); binstubs are often off PATH -- invoke via
  `ruby -S flog ...`. Installs are container-ephemeral. NEVER add survey
  tooling to the project's Gemfile.
- Expected yields, from the proven runs: flog = good trend numbers and
  outlier detection (top-5 by flog maps onto the real friction set, and it
  catches when the most-complex file is actually dead); the **routes-vs-
  actions static cross-check punches far above its weight** (dead route blocks,
  routes pointing at deleted controllers) and is cheap enough to be a standing
  CI guard; flay = usually one real cluster among ten hits (worth a quarterly
  run, not per-PR); debride = ~95% false positives on Rails (controller
  actions, Pundit predicates, view-called helpers) -- the per-candidate manual
  grep is the real tool, and grepping class names off the flog list finds its
  few real hits faster. Closing step (below) turns these yields into a
  CI-integration decision: flog + routes-check are the usual keepers.

### Findings discipline (all passes)

All findings land under the project's private plans directory. For a small
run, ONE shared findings file; for a large fan-out (10 critics + 4 phases),
prefer one file PER pass in a findings/ subdirectory plus ONE synthesis file
that dedupes and ranks -- archive each pass's raw output as it lands so a long
run's context does not have to hold every pass at once. Every finding carries:
subsystem tag, suspected root cause (one line), honest size (small / medium /
large-scary), and evidence. Tool passes cap at top-10. Dedupe happens at
synthesis, where the same root cause surfacing from multiple independent
passes is the STRONGEST ranking signal -- note the corroboration explicitly on
the candidate.

### Synthesis -- scored, not vibes

Score each deduped candidate on four countable proxies:

1. Tracker issues attributable to it in the survey window (Phase 1 output).
   When tracker hygiene is imperfect, this MUST also count fix-shaped merged
   PRs/commits with no issue reference -- firefighting happens off-tracker,
   and counting only filed issues biases the ranking toward well-ticketed
   subsystems (Phase 1 handles the mining).
2. Standing warnings/traps/sync-pairs it necessitates (Phase 2 output).
3. Severity ladder, project-tuned. Put two rungs at or near the top that are
   easy to forget: a **cross-tenant / security leak** (in a multi-tenant app
   this outranks almost everything) and **irrecoverable data loss** (dropped
   raw events can never be rebuilt; a reporting bug over intact data can) --
   both above re-derivable correctness. Then the domain ladder (e.g.
   money-out-the-door > report > receipt > cosmetic).
4. Cost: estimated phased-PR count at the house PR-size norm, plus two hazard
   flags: **[BACKFILL]** (a data migration, historically the expensive part;
   a backfill on a giant table is its own severity class) and **[NO-NET]**
   (the candidate sits in low-coverage territory with no spec net, so it costs
   materially more PRs and carries more risk -- this is where a "low coverage
   feeds fear" hypothesis actually bites the ranking).

Recurring root-cause archetypes worth naming so critics hunt them by name and
synthesis dedupes them fast (seen across proven runs): **stored-derivable
drift** (a running total / cached balance / flag stored instead of derived,
kept in sync by hand -- often with NO framework counter_cache, sometimes with
two writers disagreeing); **dual-path-without-retiring** (lesson 5);
**eval-of-DB-strings** (logic stored as source text in a column and eval'd --
unversioned, untestable, un-greppable, un-renamable); **write-only pipeline
after UI removal** (a feature's UI was deleted "for now" but its whole compute
pipeline still runs, burning money on data nothing reads); **contract-outside-
CI** (a rename breaks another repo / a scheduled job / production, never a
test).

Assign confidence tiers:

- **Tier A -- ready issue**: scoped, route known, could start Monday.
- **Tier B -- epic with phases**: root cause certain, route follows a
  pattern the project has already proven.
- **Tier C -- spike issue**: candidate is real, route unknown; the
  deliverable is a timeboxed spike whose output is the epic. The biggest
  candidates mostly land here, deliberately -- a spike is more honest than a
  speculative five-phase epic sketched from a survey-level look.

**Boundary rule**: a candidate half-overlapping excluded territory is in
scope only if it survives with the excluded epic fully done; state the
residual explicitly. Purely incidental evidence about an excluded epic goes
to that epic as a comment.

### Deliverable shape

0. **If an approval gate is set** (see inputs): the FIRST deliverable is a
   shareable proposal doc, not tracker items. It carries the ranked list, the
   intended epic/story shape, and a clearly-LABELED **process-observations
   appendix** kept out of the code ranking (see below). Steps 1-4 happen only
   after approval. Also useful even without a gate: a strategy-briefing variant
   of the same material for a technical audience, framed around the decisions
   they can make (capacity allocation, sequencing, the process bottleneck) --
   different doc, different job, than the approval artifact.
1. The ranked list with FULL reasoning goes on the tracker issue itself --
   self-contained, never a pointer to private plan files. (Under an approval
   gate this happens post-approval; the private synthesis file is the interim
   canonical record.)
2. Create an umbrella epic (a parent issue; short title). The survey issue
   becomes a completed child of it -- a Done survey must not be the parent
   of unstarted implementation work.
3. Spin off the agreed first batch as children of the epic (Tier A issue /
   Tier B epic / Tier C spike), each with a proposed priority and the
   project/billing bucket confirmed by the user per candidate.
4. Create one parked child issue ("Spin Off Next Survey Batch", lowest /
   no priority as deliberate parking) that ENUMERATES every remaining
   ranked candidate in full -- nothing may depend on someone re-reading the
   survey to know what is left.
5. Closing step: judge each one-off metrics tool by this run's actual yield
   and decide whether any earns permanent CI/rake integration; file an
   issue if so.

**Process observations are NOT code candidates.** A survey routinely surfaces
organizational costs -- merge/deploy gatekeeping, interrupt-driven priority
churn, unfilled ownership roles. These are real and worth surfacing, but they
must never be laundered into refactoring stories or scored on the code rubric.
Quarantine them in a labeled appendix (of the proposal, or a comment on the
survey issue) addressed to the people who own process. When the bug-cluster
pass can attach hard numbers -- approved-to-merged latency, count of approvals
rotting >60 days, started-but-not-finished age distribution, share of merged
PRs with no issue -- put those in the appendix; they turn "it feels slow" into
a decision-ready fact. Note the one bridge: the *code-addressable* half of a
"fear of change" hypothesis (missing contract tests, dead code, no test net,
backfill hazards) DOES feed candidates; only the organizational residue goes
to the appendix.

## Execution notes

- Phases 1-4 fan out as parallel subagents once Phase 0 has fixed the
  taxonomy; Phase 0 itself parallelizes per subsystem.
- Verify any headline claim an agent makes before enshrining it (e.g. "zero
  production callers" gets a fresh grep).
- The survey changes no production code, so there is no test/lint/PR tail --
  but tooling improvements it needs (a tracker-CLI subcommand, say) are
  fair game and should be built properly, not worked around.
