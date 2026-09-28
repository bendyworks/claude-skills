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

For checkout N; the original checkout sets the same block with suffix
empty, index 0, today's project name, and every port at its default.
A checkout with no identity at all still works: the stack scripts fall
back to the compose file's own name.

```bash
# Parallel-checkout identity. See docs/parallel-checkouts.md.
export COMPOSE_PROJECT_NAME=<today's name><N>
export PRJ_CHECKOUT_SUFFIX=<N>
export PRJ_CHECKOUT_INDEX=<N - 1>
export PRJ_PORT_OFFSET=$((200 * PRJ_CHECKOUT_INDEX))
export PRJ_CHECKOUT_ROOT="$PWD"
<one line per port row of the table above>

# Copy the identity into .devcontainer/.env on every load, keeping every other line.
identity_names="COMPOSE_PROJECT_NAME PRJ_CHECKOUT_SUFFIX PRJ_CHECKOUT_INDEX PRJ_CHECKOUT_ROOT PRJ_PORT_OFFSET <the port variables above>"
identity_lines="^[[:space:]]*(export[[:space:]]+)?(${identity_names// /|})[[:space:]]*([=:]|\$)"
rm -f .devcontainer/.env.direnv-tmp
(
  umask 077
  {
    grep -Ev "$identity_lines" .devcontainer/.env 2>/dev/null || true
    for name in $identity_names; do printf '%s=%s\n' "$name" "${!name}"; done
  } > .devcontainer/.env.direnv-tmp
) && mv .devcontainer/.env.direnv-tmp .devcontainer/.env
```

`identity_names` must list every variable the block exports, and only
those: the stack scripts compare exactly that set.

## Adding a checkout

1. Clone into a sibling directory named `<directory>N` from `origin`, and
   copy the original checkout's `.git/info/exclude` lines, the ignored
   files the app needs, and `.devcontainer/.env` without its identity
   lines.
2. Copy the original `.envrc`, give it the identity block above for N,
   record the suffix
   (`printf 'N\n' > "$(git rev-parse --path-format=absolute --git-common-dir)/parallel-checkout"`),
   and `direnv allow`.
3. Check no port in the block is taken
   (`lsof -nP -iTCP:<port> -sTCP:LISTEN` prints nothing).
4. `cd <new> && direnv exec . bin/check-parallel-dev` must name the new
   project and pass before anything starts.
5. `direnv exec . bin/docker-rebuild --wait`, then bootstrap through
   `bin/dexec` as in the README.
6. Run the full suite through `bin/dexec` here and in another checkout at
   the same moment; both must pass with identical example counts.

## Caveats

- **Memory and disk.** Every checkout runs its own containers and keeps its
  own volumes and images.
- **One branch, one session.** Give each checkout's session its own branch;
  both on the default branch for verification is fine.
- **A branch older than this setup** has no stack scripts, and its compose
  file's fixed ports, container names, and scripts that `docker exec` a
  fixed container reach or collide with the original checkout's stack.
  Merge the default branch into a branch before checking it out in a second
  checkout.
- **Worktrees edit; the checkout runs.** The containers bind-mount the
  checkout's own directory, so run stack commands from the checkout, not
  from a worktree.
- **Machine-level singletons stay single:** a browser-automation session in
  your own browser, a staging deploy.
