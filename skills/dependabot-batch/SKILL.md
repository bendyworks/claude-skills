---
name: dependabot-batch
description: Triage, verify, merge, and deploy a batch of open Dependabot PRs for the current project. Reads tuneable autonomy dials to decide which PRs to auto-merge vs escalate. Use when the user asks to process Dependabot PRs, do a Dependabot sweep, clear the Dependabot queue, or similar.
---

# Dependabot batch playbook

This skill runs the repeatable workflow for clearing a batch of Dependabot PRs:
inventory -> triage -> per-PR rebase/verify/merge -> deploy. It gates autonomy
against three config files and one policy section below.

## Config files to read at start

For each config file, prefer the project-local copy (in `<project>/.claude/`)
and fall back to the global copy (in `~/.claude/`) if the project does not
provide one:

1. `dependabot-autonomy.yml` -- tuneable dials (auto/ask, compatibility floor,
   verify command, deploy command, ecosystem hints)
2. `dependabot-never-auto.yml` -- package-specific manual-only list
3. `known-flakes.md` -- fingerprints for distinguishing flakes from real CI
   failures

Read all three before Phase 1. Reference them in later phases. When both a
project and global file exist, the project file wins entirely (do not merge).

**First run / missing config.** If a file exists in neither location, treat
every dial it would supply as "ask the user" (the most conservative setting)
for this run, then offer to scaffold the missing file(s) in
`<project>/.claude/` from the user's answers. Expected keys:

```yaml
# dependabot-autonomy.yml
merge_dev_only_with_green_ci: ask  # auto | ask
merge_runtime_bumps: ask           # auto | ask
compatibility_score_floor: 90      # percent; below this -> ask
separate_flake_fix_pr: true
verify_command: ~                  # default: project's lint+test entry point
deploy_after_batch: ask            # auto | ask
deploy_command: ~
# dependabot-never-auto.yml: a YAML list of package names.
# known-flakes.md: free-form fingerprint entries (see Flake-registry upkeep).
```

**The merge dials are an opt-in, and they are the reason this skill may
merge at all.** Merging to the default branch is otherwise a human action
(the pull-requests guidance, where a team imports it, carries that rule and
the project-wide Session-Merge Mode declaration that lifts it; a team
without that guidance needs its own equivalent). The two merge dials are a
narrower opt-in of the same shape, scoped to bot pull requests, and they
carry the same floor: **read `merge_dev_only_with_green_ci` and
`merge_runtime_bumps` only from the project-local
`<project>/.claude/dependabot-autonomy.yml`.** A global `~/.claude/` copy is
one person's setting rather than a team agreement, so it may supply the
other dials but never these two. Treat anything short of an explicit `auto`
in the project-local file as `ask`: an absent file, an absent or misspelled
key, or any other value.

Two consequences worth naming. A file this skill scaffolds during a run
takes effect on the *next* run, never the one that created it -- a session
does not author its own authorization. And on a project where merging is
the deploy, `merge_runtime_bumps: auto` ships a runtime dependency straight
to production with no human in the loop, and Phase 5's verification runs
only after that has happened; a team wanting the bumps merged but not
shipped unattended should leave `deploy_after_batch` at `ask` and know that
the merge dial alone already deploys. Whether one dial should stand between
a green batch and production is open in
[#83](https://github.com/bendyworks/claude-skills/issues/83).

## Hard veto (policy, not a dial)

These categories **always** downgrade to "ask" regardless of dials or
compatibility score. Do not auto-merge under any circumstance:

- Any **major** version bump (x.0.0 in semver)
- Any bump to a **language runtime** (e.g. `ruby` directive / `.ruby-version`,
  `node` engine / `.nvmrc`, `python_requires`)
- Any bump to a **core framework** the project is built on (e.g. rails for a
  Rails app, next/react for a Next.js app, django for a Django app). Detect
  this from the project's manifest at start.
- Any package listed in `dependabot-never-auto.yml`
- Any **grouped** Dependabot branch (e.g. `dependabot/<ecosystem>/multi-*` or
  similarly-named group branches) -- refuse to process and point the user at
  their `.github/dependabot.yml` config. This skill prefers individual
  bumps so a single bad upgrade can be reverted in isolation.

## Phase 1: Inventory

**Repo of record.** Every `gh` command in this skill acts on gh's resolved
default repo, so pin it down before inventorying anything. Run
`gh repo view --json nameWithOwner,defaultBranchRef` once: it names the
repo gh has resolved and the default branch the later phases use. In a
single-remote clone the repo answer is settled. In a multi-remote clone,
absent a recorded `gh repo set-default` answer, gh prefers `upstream` over
`origin`, which is wrong for a fork that runs its own Dependabot -- the
PRs live on the fork while gh would inventory the parent's. If the
resolved repo is not the one whose Dependabot PRs should be processed,
have the user run `gh repo set-default` (or confirm with them which repo
is intended), then repeat the `gh repo view` call. Every later phase
inherits both answers.

Run `gh pr list --state open --author app/dependabot --json number,title,headRefName,body`.

For each PR, extract and display in a compact table:

| PR | Package | From -> To | Bump type | Group | CI | Compat % |

- **Bump type:** patch / minor / major (from the "From -> To" semver delta)
- **Group:** dev-only (package lives only in dev/test scope -- e.g. Ruby
  `:development` / `:development, :test` groups, npm `devDependencies`,
  Python dev-extras) vs runtime (anything else). Check against the project's
  manifest (`Gemfile`, `package.json`, `pyproject.toml`, etc.).
- **CI:** from `gh pr checks <n>` -- pass / fail / pending
- **Compat %:** parse the Dependabot body -- look for a "Compatibility Score"
  badge or text. Report `N/A` if absent.

## Phase 2: Pre-flight & triage

**Main-health precheck.** Before touching any PR branch, confirm the default
branch's latest CI run is green
(`gh run list --branch <default-branch> --limit 1`). If red, bail with a
message and stop -- do not rebase onto a broken base. Use the default
branch the Phase 1 repo-of-record call reported rather than assuming
`main`.

**Merge-method detection.** Query the repo to find which merge strategies are
allowed and pick the method this batch will use:

```
gh api "repos/{owner}/{repo}" --jq '{squash:.allow_squash_merge,merge:.allow_merge_commit,rebase:.allow_rebase_merge}'
```

Pick the first allowed method in this priority order: **squash -> merge ->
rebase**. Squash is preferred for clean dependency-bump history; the others
are fallbacks when the repo disallows squash. Store the chosen flag
(`--squash` / `--merge` / `--rebase`) and reuse it for every merge in this
batch. If none are allowed, stop and surface the repo settings to the user.

Do **not** change the repo's merge-method settings to enable squash -- repo
policy is not scoped to this skill, so flipping it would change the default
across all merges (UI, other tools, contributors). Adapt to the repo instead.

**Grouped-branch refusal.** If any PR branch matches the grouped-branch
pattern (`dependabot/<ecosystem>/multi-*` or similar group prefix), refuse to
process it and point the user at `.github/dependabot.yml`.

**CI failure triage.** For each PR with `CI: fail`:

- Fetch the failure trace (`gh run view <run-id> --log-failed`)
- Match against `known-flakes.md` fingerprints
- If **all** failing PRs match known flake patterns -> per the
  `separate_flake_fix_pr` dial, propose a standalone flake-fix PR first,
  stop, and wait for the user to approve/merge it. After they do, re-run the
  skill.
- If **any** failure is not a known flake -> stop, surface the trace, and ask
  the user. Do not proceed on that PR.

## Phase 3: Merge order

Propose an order, lowest blast radius first:

1. Dev-only patch bumps
2. Dev-only minor bumps
3. Runtime patch bumps
4. Runtime minor bumps
5. Anything requiring "ask" (majors, never-auto list, sub-floor compat,
   runtime/core-framework bumps)

Surface the order to the user and proceed.

## Phase 4: Per-PR loop

For each PR in order:

1. `gh pr checkout <n>` -- besides checking out the branch, this resolves
   the git remote for the whole loop: checkout records the remote whose
   URL matches the repo that owns the PR in `branch.<branch>.remote`.
   Read it once (`git config branch.<branch>.remote`) and use it as
   `<remote>` in every git command below and in Phase 5. Never write
   `origin` literally here: in a fork clone `origin` is the fork, and a
   push there succeeds silently while the real PR never moves. Two
   recorded shapes need repair before proceeding. An EMPTY read: gh
   writes tracking only when it creates the branch, so a pre-existing
   same-named local branch keeps none -- check out the default branch,
   delete that stale local branch, and re-run `gh pr checkout <n>`, or
   pick the remote whose URL matches the repo of record. A URL in
   place of a remote name: gh's fallback when no configured remote
   points at the PR's repo -- add a real remote for the repo of
   record, then check out the default branch, delete the branch the
   fallback checkout created, and re-run `gh pr checkout <n>`; a plain
   re-checkout would keep the URL, since gh writes the value only at
   branch creation. Since
   Dependabot PRs always live on the repo they target, the one recorded
   remote serves both the trunk fetch and the push, and it is the same
   for every PR in the batch.
2. `git fetch <remote> <default-branch> && git rebase <remote>/<default-branch>`
   (the default branch Phase 1 already resolved -- do not re-derive it
   or assume `main`). Skip the fetch half when step 8 refreshed
   `<remote>/<default-branch>` moments ago for the previous PR's merge;
   the rebase always runs.
   - If rebase conflicts, stop and surface to the user
3. Install dependencies with the ecosystem's standard command (`bundle install`,
   `npm ci`, `pip install -r ...`, etc.)
4. Run the verify command, capturing complete output to a uniquely-named log under /tmp to grep for follow-ups -- never re-run just to re-read output
   (wrap the command in `2>&1 | tee /tmp/<name>-$(date +%s).log`; a verify command
   that already captures this way satisfies the clean-and-green
   guidance's capture rule, where a team imports it). The dial
   `verify_command` in `dependabot-autonomy.yml` overrides the default
   command; if unset, use the project's standard "lint + test" entry
   point (e.g. `bundle exec rake` for Ruby/Rails projects with a
   default rake task, `npm test && npm run lint` for Node projects, or
   whatever the project's CLAUDE.md says). Output must be clean.
   - If linting surfaces new offenses (e.g. from a new cop / rule introduced
     by a linter-plugin bump), fix at source in one attempt. Never silence
     with disable-comments. If not cleanly fixable in one pass, stop and ask.
5. `git push --force-with-lease <remote> HEAD` -- the remote named
   explicitly: a bare `git push` follows `remote.pushDefault` /
   `branch.<branch>.pushRemote` in triangular-push setups and can land
   elsewhere.
6. Monitor CI with the Monitor tool polling `gh pr checks <n>`
7. **Gating decision** once CI is `SUCCESS`:

   | Condition | Action |
   |-----------|--------|
   | Hard veto (major / runtime language / core framework / never-auto list / grouped) | Announce green, wait for user merge |
   | Compat % below `compatibility_score_floor` (or N/A) | Announce green, wait for user merge |
   | Dev-only + patch/minor + `merge_dev_only_with_green_ci: auto` | `gh pr merge <n> <merge-flag> --delete-branch` |
   | Runtime + patch/minor + `merge_runtime_bumps: auto` | `gh pr merge <n> <merge-flag> --delete-branch` |
   | Either dial set to `ask` | Announce green, wait for user merge |

8. After each auto-merge or user-reported merge,
   `git checkout <default-branch> && git pull --ff-only <remote> <default-branch>`
   so the next PR's step 2 rebase runs against the just-updated base
   rather than a stale one. (Named remote: the local default branch may
   track a fork.)

## Phase 5: Post-batch verification

After the last PR merges:

1. `git checkout <default-branch> && git pull --ff-only <remote> <default-branch>`
   (the same `<remote>` Phase 4 resolved). If you did not retain the
   value from Phase 4 -- the branch config that held it is gone once
   `gh pr merge --delete-branch` removes the local branch -- re-resolve
   `<remote>` as the remote whose URL matches the repo of record.
2. Re-install dependencies with the ecosystem's standard command
3. Run the verify command (same as Phase 4 step 4) -- must be clean and green

If verification fails here, stop. Do not deploy.

## Phase 6: Deploy

If `deploy_after_batch: auto` and Phase 5 passed: run the project's deploy
command. The dial `deploy_command` in `dependabot-autonomy.yml` defines what
to run (e.g. `bin/deploy`, `npm run deploy`, `make deploy`); if unset and the
user has not configured one, stop and ask rather than guessing. Do not ask
when the dial is set.

The deploy command is responsible for its own failure detection (health
check, crashed-process detection, rollback hint). Surface its output. If it
exits non-zero, surface the failure and do not treat the batch as complete.

## Post-run summary

Close the session with a table:

| PR | Package | Bump | Outcome |
|----|---------|------|---------|
| #31 | foo-gem | 11.3.0 -> 11.3.1 | auto-merged |
| #29 | bar-pkg | 2.1.0 -> 2.2.3 | awaiting user merge (compat N/A) |
| ... | ... | ... | ... |

Plus:
- Flake-fix PR (if any): number, status
- Deploy: release identifier, health check result

## Escalation rules (short reference)

- Default-branch CI red at start -> stop
- Rebase conflict -> stop, surface diff
- Grouped-branch PR present -> refuse, point at config
- CI failure with unknown fingerprint -> stop, surface trace, ask
- Lint offense not cleanly fixable in one pass -> stop, ask
- Deploy command non-zero exit -> stop, surface logs

## Flake-registry upkeep

When a new flake is diagnosed and fixed in the course of running this skill,
append a new entry to the project's `.claude/known-flakes.md` (newest at
bottom) before finishing the session. If the project does not yet have its
own file, create it (copying a global one if you keep one) and append
there -- flake fingerprints are usually project-specific and should not be
added to a global template. Include: error signature,
typical trigger, fix pattern, first-observed date and file.
