# Engineering Guidance

Team-neutral engineering guidance for [Claude Code](https://code.claude.com),
extracted from how we work at [Bendyworks](https://bendyworks.com). Each
file is plain markdown you can wire into your own Claude sessions so the
practices apply to your work automatically.

| File | What it covers | Applies to |
| --- | --- | --- |
| [`tdd.md`](tdd.md) | Test-first by default: spec first, watch it fail, then production code, then watch it pass -- and how to verify retroactively when that order slipped. | everything |
| [`spec-writing.md`](spec-writing.md) | RSpec defaults: syntax idioms, doubles vs real factory records, setup hygiene, minimal base factories with traits, which specs not to write, and titles that name behavior. | `spec/**/*` (path-scoped via frontmatter) |
| [`commit-messages.md`](commit-messages.md) | Conventional Commits shape (`type(scope):` prefix, trailer footers, a revert convention) with Title Case outcome descriptions that answer WHY, bodies that carry the what, the how, and the motivating cost, and what belongs in the PR description instead. | everything |
| [`code-comments.md`](code-comments.md) | Comments that state permanent intent -- invariants and constraints, not debugging narration -- plus plain language: no unexplained acronyms, no insider jargon, no session-coined names, and analogy words that fit the construct's real category. | everything |
| [`pull-requests.md`](pull-requests.md) | Small incremental PRs (300-line target, 400-line easy-review threshold), draft mode first, why-first cost-naming descriptions that link outside resources, a PR owns the bugs it introduces, per-thread review replies, and stacked-chain merge mechanics (deletion-driven retargeting, stale approvals at each retarget). | everything |
| [`clean-and-green.md`](clean-and-green.md) | Zero lint offenses and zero test failures as the status quo, no suppression comments, and escalating to a human instead of ever calling a red suite acceptable; defines Full Verification Mode (the default) and opt-in Targeted Spec Verification Mode for where the full suite runs, and captures every gating run's output to a uniquely-named /tmp log that gets grepped instead of the run being repeated. | everything |
| [`verification-habits.md`](verification-habits.md) | Empiricism before assertion: verify library claims against installed source, never write unverified facts about people, check schemas and method signatures before use. | everything |
| [`tracker-comments.md`](tracker-comments.md) | Tracker comments that survive plans falling through: intentions with owners and absolute dates, instructions the reader verifies, no relative time. | everything |
| [`rails-conventions.md`](rails-conventions.md) | Rails built-ins before custom code, standard foreign-key associations, symbol-based enum usage, and avoiding ActiveRecord callbacks in new code. | Rails projects |
| [`environments.md`](environments.md) | Staging and production are separate datasets: frame smoke tests, bug repros, and QA hand-offs in scenario shape, never by production record IDs. | everything |

Every file opens with the same precedence rule: **if it conflicts with
your project's own CLAUDE.md, rules files, or a team agreement, your
project wins.** These are defaults, not mandates.

## Ways to adopt

Pick whichever fits your team; all three are supported.

### 1. Use verbatim (clone + import)

Clone the repo and symlink it to the canonical location, so import
lines are identical across machines and copy-pasteable from docs:

```bash
git clone https://github.com/bendyworks/claude-skills.git
ln -s "$PWD/claude-skills" ~/.claude/bendyworks-guidance
```

Then import from your personal `~/.claude/CLAUDE.md` (user-level
imports are not gated by any approval prompt):

```
@~/.claude/bendyworks-guidance/guidance/tdd.md
@~/.claude/bendyworks-guidance/guidance/commit-messages.md
```

`spec-writing.md` is shaped as a path-scoped rules file, so link it
into your rules directory instead and it will only apply when you're
working under `spec/`:

```bash
mkdir -p ~/.claude/rules
ln -s ~/.claude/bendyworks-guidance/guidance/spec-writing.md ~/.claude/rules/
```

Updates arrive with `git pull` in the clone. Remember that a pull can
change how your sessions behave; skim the diff.

### 2. Copy the files into your project

Copy the files into your repo as `.claude/rules/*.md` via a normal PR
your team reviews. Updates arrive the same way: a PR someone reads,
amends, or rejects. Nothing changes behavior without a reviewed merge,
and once merged the files are yours to edit.

Copying also sidesteps every external-import mechanic below: no
approval prompt, no symlink, no path variance across machines.

### 3. Fork

It's [MIT](../LICENSE). Copy, reshape, and keep whatever serves your
team. If a change is generally useful, we'd love a PR back -- but
that's optional.

## Overriding and customizing

You don't need to fork to disagree. The precedence preamble in every
file means a deviation written in your own project CLAUDE.md or rules
wins over anything here. State the deviation where your team's rules
live ("we use build_stubbed, not create, for model specs") and Claude
follows yours.

## Keep it lean

Claude adheres best when a session's total guidance stays around 200
lines; imported files count against that budget. Import only the files
you'll actually use, and feel free to trim in-repo copies -- deleting
sections your team doesn't need is customizing, not vandalism.

## Troubleshooting imports

**Imported guidance isn't taking effect.** Imports fail silently: a
wrong path produces no error -- the `@path` line just sits in context
as plain text and the file never loads. To check what actually loaded,
run `/memory` in an interactive session; every loaded file is listed
there. Common causes:

- Typo in the path, or the clone/symlink doesn't exist yet. Verify
  with `ls ~/.claude/bendyworks-guidance/guidance/`.
- The `@path` is wrapped in backticks or a code block. Those are
  intentionally not parsed as imports -- that's how this README shows
  import syntax without triggering it. Write the line bare in your
  own CLAUDE.md.
- The import chain is more than 4 hops deep (Claude Code's recursion
  limit).

**I declined the "external file" approval prompt and now imports never
load.** When a project-level CLAUDE.md imports a file outside the
project root, Claude Code asks for approval once per project.
Declining disables those imports permanently for that project, with no
re-prompt and no error. To recover, quit Claude Code sessions in that
project, then in `~/.claude.json` under
`projects."<absolute project path>"` either set
`"hasClaudeMdExternalIncludesApproved": true`, or set
`"hasClaudeMdExternalIncludesWarningShown": false` to be asked again
next session.

Note: that prompt only applies to imports written in a checked-in
project CLAUDE.md. Imports in your personal `~/.claude/CLAUDE.md` (the
clone + import setup above) are not gated by it, and in-repo copies
never leave the project root at all.
