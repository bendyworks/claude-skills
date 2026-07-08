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
| `gauntlet` | Multi-front quality pass on a feature branch whose specs and lint already pass: code review, then parallel audits (cruft, idioms, test quality, validation bypass, security), consolidated into a triaged punch list. Rails-oriented. |
| `plan-issue` | Plan a story end-to-end: interview, research, propose a plan, challenge it from a fresh perspective, record it, work the to-dos, and finish after ship. |
| `finished-issue-housekeeping` | Post-ship cleanup once a story is merged and live: finalize the plan file, prune branches, tidy memory and task lists. |
| `linear` | Read and write Linear issues via a bundled CLI (create, comment, search, transition) instead of raw GraphQL. Requires Ruby and a `LINEAR_API_TOKEN` env var. |
| `dependabot-batch` | Triage, verify, merge, and deploy a batch of open Dependabot PRs with tuneable autonomy. |
| `app-wind-down` | Wind down a hosted app safely and reversibly: caretaker mode first, then hibernation to ~$0 with full restore assets. |
| `bug-cluster-ledger` | Mine a time window of tracker issues and cluster them upward to root causes per subsystem, with prevention analysis. |
| `architecture-survey` | Domain-first architectural-simplification survey of a mature codebase, producing a ranked, tracker-ready refactoring backlog. |
| `markdown-to-pdf` | Convert Markdown files to clean, print-styled PDFs. |

## Requirements

- Claude Code with plugin support.
- The `linear` skill's bundled CLI requires Ruby 3.x on your PATH (macOS
  and Linux; on Windows use WSL) and a `LINEAR_API_TOKEN` environment
  variable.
- `gauntlet` is tuned for Ruby on Rails projects (RSpec, RuboCop, Pundit).
  It runs elsewhere, but its audit prompts are Rails-flavored.
- `gauntlet`, `dependabot-batch`, and `finished-issue-housekeeping` lean on
  the GitHub CLI (`gh`) being installed and authenticated.
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

## License

[MIT](LICENSE)
