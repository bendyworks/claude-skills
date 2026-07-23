# Enforcing the Commit Prefix in CI

> **Precedence:** this file is a shared default. If anything here
> conflicts with the project's own CLAUDE.md, rules files, or a team
> agreement, the project wins.

A team that mandates the `type(scope):` prefix from the
[commit-messages guidance](commit-messages.md) can enforce it without
a toolchain: one workflow step over git and grep. This file is a
setup reference for the humans configuring CI -- unlike the other
guidance files, it has nothing to teach a Claude session, so skip it
when wiring up imports.

The check lints only the pull request's own commits against the live
base branch -- an out-of-date branch update never flags mainline
commits -- and fails closed: a range that cannot be resolved errors
the step instead of passing green. Its check logic is battery-tested
against scratch git ranges, and the workflow itself has been
smoke-tested in a live repository:

```yaml
on: pull_request

jobs:
  commit-prefix:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - env:
          BASE_REF: ${{ github.base_ref }}
        run: |
          set -euo pipefail
          export LC_ALL=C
          pattern='^[0-9a-f]+ (feat|fix|build|chore|ci|docs|style|refactor|perf|test|revert)(\([a-z0-9-]+\))?!?: .+'
          subjects=$(git log --no-merges --format='%h %s' "origin/${BASE_REF}..HEAD")
          violations=$(printf '%s\n' "$subjects" \
            | grep -Ev '^[0-9a-f]+ (Revert|Reapply) "' \
            | grep -Ev "$pattern" || true)
          if [ -n "$violations" ]; then
            printf 'Commit subjects not in type(scope): shape:\n%s\n' "$violations"
            exit 1
          fi
```

- Mark the check required in branch protection or a
  [ruleset](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets);
  unrequired, the mandate is advisory. The job name is the contract:
  renaming it strands the requirement as a check stuck "Expected".
  A merge-queue repo also adds `merge_group` to the trigger, or the
  required check never reports on queue branches and the queue
  stalls.
- The regex enforces shape alone: the eleven types, a
  lowercase-hyphenated scope, and a non-empty description. Everything
  else stays advisory -- length remains the commit-messages
  guidance's soft "roughly 72", and outcome verbs and WHY-quality are
  beyond any tool. `fixup!`/`squash!` subjects fail on purpose -- the
  red check forces the autosquash before merge. (The `LC_ALL=C` line
  keeps grep's output literal when a subject carries stray non-UTF-8
  bytes.)
- Merge commits (`--no-merges`) and pushed generated revert messages
  (the `Revert "..."`/`Reapply "..."` skip; see the commit-messages
  guidance's Reverts section) are the gate's slice of that guidance's
  generated-message exemption. A hand-typed revert keeping git's
  default subject slips through with them -- a boundary of
  shape-checking, not an endorsement -- and other generated subjects
  are not exempt. GitHub's "Apply suggestions from code review" batch
  commit is human-authored: reword it on the PR. Bot-authored commits
  (a github-actions[bot] auto-commit) keep their generators' formats
  per that guidance, so give them a deliberate skip instead -- match
  on authors (e.g. `--format='%an%x09%h %s'`), since the check as
  written sees hashes and subjects only.
- Dependabot conforms instead of needing an exemption: set
  [`commit-message`](https://docs.github.com/en/code-security/dependabot/working-with-dependabot/dependabot-options-reference#commit-message)
  `{ prefix: "build", include: "scope" }` in `dependabot.yml` to get
  `build(deps): bump ...` subjects.
- A squash-merge repo should lint the pull request title instead,
  since the title becomes the commit subject once the "Default to
  pull request title" setting is on: same regex, title passed via
  `env:` (a title interpolated into `run:` is script injection),
  with `edited` added to the trigger's activity types so a rename
  re-lints. The merger can still edit the final message at merge
  time, so the title gate is necessary, not airtight.
- Teams that later adopt changelog or release automation will meet
  commitlint in that ecosystem; disable its `subject-case` rule,
  whose stock preset rejects Title Case descriptions.
