# Bendyworks Claude Skills

A collection of [Claude Code](https://code.claude.com) skills we use every
day at [Bendyworks](https://bendyworks.com), packaged as a plugin
marketplace so you can install them with one command and pick up
improvements as we ship them.

These skills are evolving. They work for us, but expect rough edges --
issues and pull requests are welcome (see [CONTRIBUTING](CONTRIBUTING.md)).

## Install

From inside Claude Code:

```
/plugin marketplace add bendyworks/claude-skills
/plugin install bendyworks@bendyworks
```

Installed skills are namespaced: invoke them as `/bendyworks:<skill>`, e.g.
`/bendyworks:gauntlet`. Claude also triggers them automatically when a task
matches a skill's description.

To pick up updates later:

```
/plugin marketplace update bendyworks
```

## Skills

| Skill | What it does |
| --- | --- |
| `gauntlet` | Harden the quality of a branch that already accomplishes your goal and you now want to improve. This is a Rails-oriented multi-front quality pass on a feature branch whose specs and lint already pass. True superset of Anthropic's built-in /code-review skill. Includes: code review, then parallel audits (cruft, idioms, test quality, validation bypass, security), consolidated into a triaged punch list that you guide implementing. |
| `plan-issue` | Plan a story end-to-end: interview, research, propose a plan with steps for a full life cycle, challenge it from a fresh perspective, record it, work the to-dos, and finish after ship. |
| `finished-issue-housekeeping` | Post-ship cleanup once a story is merged and live: finalize the plan file, prune branches, tidy memory and task lists. |
| `architecture-survey` | Identify the biggest improvement opportunities in your application - prioritizing the largest and most daunting pain points you've been paying a large maintenance tax on already. Domain-first architectural-simplification survey of a mature codebase, producing a ranked, tracker-ready refactoring backlog. Can create an epic of fixes in your story tracker of choice. |
| `markdown-to-pdf` | Convert Markdown files to clean, print-styled PDFs. |
| `linear` | Read and write Linear issues via a bundled CLI (create, comment, search, transition) instead of raw GraphQL. Requires Ruby and a `LINEAR_API_TOKEN` env var. |
| `dependabot-batch` | Triage, verify, merge, and deploy a batch of open Dependabot PRs with tuneable autonomy. |
| `bug-cluster-ledger` | Mine a time window of tracker issues and cluster them upward to root causes per subsystem, with prevention analysis. Used by architecture-survey. |
| `app-wind-down` | Wind down a hosted app safely and reversibly: caretaker mode first, then hibernation to ~$0 with full restore assets. |
| `targeted-specs` | Run just the specs a feature branch plausibly affects instead of the full local suite, leaning on CI for the full run. Recomputes scope from the branch diff every run, escalates to "this branch needs a full run" when blast-radius files are touched, announces the subset for your veto, and always lints the whole project. Rails/RSpec-first. |

## Engineering guidance

Beyond skills, [`guidance/`](guidance/README.md) holds team-neutral
engineering guidance files -- test-driven development discipline,
commit-message style, pull-request practices, and more -- that you can
import into your own CLAUDE.md, copy into a project's
`.claude/rules/`, or fork outright. Every file defers to your project's own rules on
conflict. See [guidance/README.md](guidance/README.md) for setup,
overriding, and troubleshooting.

## Requirements

- Claude Code with plugin support.
- The bundled CLIs (`linear`, and `gh-issue-sync` used by `plan-issue`
  and `finished-issue-housekeeping` on GitHub-tracked repos) require
  Ruby 3.x on your PATH (macOS and Linux; on Windows use WSL). The
  `linear` CLI also needs a `LINEAR_API_TOKEN` environment variable;
  `gh-issue-sync` delegates auth to the GitHub CLI (`gh`).
- `gauntlet` is tuned for Ruby on Rails projects (RSpec, RuboCop, Pundit).
  It runs elsewhere, but its audit prompts are Rails-flavored. It would be easy to re-focus a forked copy if you wish.
- `gauntlet`, `dependabot-batch`, `finished-issue-housekeeping`, and
  `plan-issue` lean on the GitHub CLI (`gh`) being installed and
  authenticated.
- `markdown-to-pdf` needs a Chromium-based browser or wkhtmltopdf, plus a
  markdown converter (kramdown gem, pandoc, or python-markdown).

## Upgrading Rails?

For Rails and Ruby upgrade work we use and recommend the excellent skills
from OmbuLabs / FastRuby.io (`rails-upgrade`, `dual-boot`,
`rails-load-defaults`):

```
/plugin marketplace add ombulabs/claude-skills
```

We deliberately don't republish those here -- install them from the source.
We have our own wrapping functionality that we need to separate out cleanly before publishing here.

## License

[MIT](LICENSE)
