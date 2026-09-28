<!-- parallel-checkouts template v1 (bendyworks/claude-skills). Replace every
<angle-bracket> placeholder and PRJ prefix, delete rows that do not apply,
and remove this comment. -->

# Parallel Checkouts

This repository can be cloned more than once on the same machine, with each
clone (a *checkout*) running its own Docker Compose stack at the same time as
the others: its own containers, networks, and volumes, so its own databases.
Each checkout is a full, permanent clone, not a git worktree: git refuses to
check out one branch in two worktrees, and the containers bind-mount the
checkout's own directory.

## How it works

Compose namespaces everything by project name. A checkout's identity is its
`COMPOSE_PROJECT_NAME` plus a block of published host ports, exported by its
untracked `.envrc` ([direnv](https://direnv.net/)) and copied into
`.devcontainer/.env`, where Compose and the stack scripts read it:

| What | Where | Variable | Default |
| --- | --- | --- | --- |
| Project name | `.devcontainer/docker-compose.yml` `name:` | `COMPOSE_PROJECT_NAME` | `<today's name>` |
| <Service> host port | `.devcontainer/docker-compose.yml` `ports:` | `PRJ_<SERVICE>_PORT` | `<port>` |

Checkout N's ports are the defaults plus `200 * (N - 1)`.

**Go through the stack scripts; never type a bare `docker compose` or
`docker exec`.** Compose prefers an exported variable to the env file, so a
shell still carrying another checkout's identity silently reaches that
checkout's containers. `bin/compose-project`, which every script sources,
compares the shell with `.devcontainer/.env` and refuses on any
disagreement.

- `bin/dexec <command>` runs a command in the app container
  (`DEXEC_SERVICE=<service>` for another one); piped input works.
- `bin/docker-up`, `bin/docker-down`, `bin/docker-rebuild` manage this
  checkout's stack from any directory. `bin/docker-down --volumes` deletes
  this checkout's databases.
- `bin/check-parallel-dev` proves the scripts reach this checkout and refuse
  a shell claiming another. Run it after adding a checkout, and whenever a
  command looks like it reached the wrong stack.

From a shell outside a checkout, use `cd <checkout> && direnv exec . <command>`.

## The `.envrc` identity block

For checkout N (the original checkout uses suffix empty, index 0, and
today's project name):

```bash
# Parallel-checkout identity. See docs/parallel-checkouts.md.
export COMPOSE_PROJECT_NAME=<today's name><N>
export PRJ_CHECKOUT_SUFFIX=<N>
export PRJ_CHECKOUT_INDEX=<N - 1>
export PRJ_PORT_OFFSET=$((200 * PRJ_CHECKOUT_INDEX))
export PRJ_CHECKOUT_ROOT="$PWD"
<one line per port row of the table above>

# Copy the identity into .devcontainer/.env on every load; other lines are kept.
identity='^(export[[:space:]]+)?(COMPOSE_PROJECT_NAME|PRJ_CHECKOUT_[A-Z0-9_]*|PRJ_PORT_OFFSET|PRJ_[A-Z0-9_]*_PORT)='
{
  grep -Ev "$identity" .devcontainer/.env 2>/dev/null || true
  env | grep -E "$identity" | sort
} > .devcontainer/.env.direnv-tmp && mv .devcontainer/.env.direnv-tmp .devcontainer/.env
```

## Adding a checkout

1. Clone into a sibling directory named `<directory>N` from `origin`, and
   copy the original checkout's `.git/info/exclude` lines and the ignored
   files the app needs.
2. Copy the original `.envrc`, give it the identity block above for N, and
   `direnv allow`.
3. `cd <new> && direnv exec . bin/check-parallel-dev` must name the new
   project and pass before anything starts.
4. `direnv exec . bin/docker-rebuild`, then bootstrap through `bin/dexec` as
   in the README.
5. Run the full suite through `bin/dexec` here and in another checkout at the
   same moment; both must pass with identical example counts.

## Caveats

- **Memory and disk.** Every checkout runs its own containers and keeps its
  own volumes.
- **A branch older than this setup** has no stack scripts, and a bare
  `docker compose` there resolves the original checkout's project. Merge the
  default branch into a branch before checking it out in a second checkout.
- **Worktrees must live inside the checkout** (for example under
  `.claude/worktrees/`) to be visible in its containers, and they share its
  stack.
