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
message and stop -- do not rebase onto a broken base. Use whatever branch
`gh repo view --json defaultBranchRef` reports rather than assuming `main`.

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

1. `gh pr checkout <n>`
2. `git fetch origin <default-branch> && git rebase origin/<default-branch>`
   - If rebase conflicts, stop and surface to the user
3. Install dependencies with the ecosystem's standard command (`bundle install`,
   `npm ci`, `pip install -r ...`, etc.)
4. Run the verify command, capturing complete output to a
   uniquely-named log under /tmp to grep for follow-ups -- never re-run
   just to re-read output (wrap the command in `2>&1 | tee
   /tmp/<name>.log`; a verify command that already captures this way
   satisfies the clean-and-green guidance's capture rule, where a team
   imports it). The dial `verify_command` in `dependabot-autonomy.yml`
   overrides the default command; if unset, use the project's standard
   "lint + test" entry point (e.g. `bundle exec rake` for Ruby/Rails
   projects with a default rake task, `npm test && npm run lint` for
   Node projects, or whatever the project's CLAUDE.md says). Output
   must be clean.
   - If linting surfaces new offenses (e.g. from a new cop / rule introduced
     by a linter-plugin bump), fix at source in one attempt. Never silence
     with disable-comments. If not cleanly fixable in one pass, stop and ask.
5. `git push --force-with-lease origin <branch>`
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
   `git checkout <default-branch> && git pull --ff-only` and re-rebase the
   next PR on the updated base before processing it. This avoids CI running
   on a stale base.

## Phase 5: Post-batch verification

After the last PR merges:

1. `git checkout <default-branch> && git pull --ff-only`
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
