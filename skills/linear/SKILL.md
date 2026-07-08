---
name: linear
description: Read or write Linear issues using the bundled `linear` CLI instead of raw curl + GraphQL. Use whenever the user asks to fetch a Linear issue, look up comments, search Linear, create a Linear issue, update a Linear state, post a comment on a Linear issue, or similar phrasings ("get ABC-NNN", "what's on ABC-592", "comment on the Linear story", "move it to PR Review", "open a Linear issue for ..."). The CLI reads LINEAR_API_TOKEN from the environment and pretty-prints by default.
---

# linear CLI

A semantic wrapper around Linear's GraphQL API. Prefer this over `curl https://api.linear.app/graphql ...` -- it collapses the permission prompt to a single readable line and pretty-prints the response.

Stdlib-only Ruby, bundled with this plugin and available on PATH as `linear` when the plugin is installed (plugins add their `bin/` to PATH). Requirements: Ruby 3.x and a `LINEAR_API_TOKEN` env var. Optionally set
`LINEAR_TEAM_KEY` to your team's key (e.g. `ABC`) so `list` and
`project-list` don't need an explicit `--team` flag.

## Read

```
linear get ABC-NNN [--full] [--json]
linear comments ABC-NNN [--json]
linear search "phrase" [--team KEY] [--limit N] [--json]
```

- `get` shows title, state, description, team, project, parent, children, URL.
- `--full` adds the comment thread.
- `--json` emits the raw GraphQL response for piping.
- `search` is case-insensitive substring match over title and description, sorted by most-recently-updated.

## Write

```
linear create --team KEY --title TITLE --priority LEVEL \
              (--project NAME | --no-project) \
              [--description TEXT | --description-file PATH] [--json]

linear update ABC-NNN [--state NAME] [--title TITLE] [--priority LEVEL] \
              [--description TEXT | --description-file PATH] [--json]

linear comment ABC-NNN "message body"
```

- `create` requires `--team`, `--title`, and `--priority`. `--project` is required by default (new issues should always be attached to a project); pass `--no-project` to override deliberately. Project name match is exact-then-substring.
  - **Ask the user which project before creating; do not guess.** The same work can be contracted maintenance or billable requested-additional-work depending on context only the user knows, and the choice has billing consequences. Offer the candidate projects and let the user pick rather than defaulting from a "bug -> maintenance" heuristic.
- `update` accepts any combination of `--state`, `--title`, `--priority`, and `--description`. State name must match a workflow state on the issue's team.
- `comment` appends a comment. Pass the body as the second positional arg (quote it).

## Priority (required on every create)

The CLI refuses `create` without an explicit `--priority`. Before creating an
issue, **propose a priority with a one-line rationale and let the user confirm
or override** -- same flow as the project question above, and they can be asked
together. Guidelines:

- `urgent` -- production is actively wrong in a way that moves or misstates
  money, corrupts data, or blocks users; drop current work. (Wrong money
  amounts, prod outage, wrong charges visible to customers.)
- `high` -- users can hit it today, or it gates other scheduled work or a
  stakeholder commitment; pick up this cycle. (Live incorrect data/display
  with no workaround, a repair whose delay compounds, prereq of an in-flight
  epic.)
- `medium` -- the default for scheduled improvement work: structural refactors
  and epic phases, bugs with a workaround, perf users feel but tolerate.
- `low` -- cleanups that don't compound: renames, dead code, tooling,
  dev-experience items.
- `none` -- deliberate parking only (spike awaiting an external/policy
  decision, placeholder pending triage). Must be passed explicitly; never an
  accidental default.

## When to use

- The user mentions a Linear identifier (ABC-NNN, etc.) and wants info on it: `linear get`.
- The user wants to scan recent activity on an issue: `linear get --full` or `linear comments`.
- The user wants to find tickets by phrase: `linear search`.
- The user asks to open a new ticket, move an issue's state, or post a comment.

## Don't

- Don't fall back to raw `curl` against `api.linear.app/graphql`. If the CLI is missing a subcommand you need, propose adding it via a PR to the plugin repo (github.com/bendyworks/claude-skills) rather than working around it.
- Don't reach for the Linear MCP -- prefer this CLI over the Linear MCP or raw GraphQL curl.
- Don't pass long descriptions inline on the command line. Write them to a file and use `--description-file`.
