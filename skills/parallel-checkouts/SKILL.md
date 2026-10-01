---
name: parallel-checkouts
description: Set up a project so several full, independent working copies of it (`<project>2`, `<project>3`, ...) can each run a dev server and full lint+test suite at once on one machine, sharing no ports, databases, Redis databases, or containers. Works for projects whose Postgres and Redis run natively and for Docker Compose projects (each checkout gets its own Compose project and ports). Four modes -- prepare a project (a one-time pull request giving its ports, database names, or Compose project a per-checkout identity), add checkout N (clone, identity, databases or stack, shared Claude Code state), remove checkout N, and move all of a project's checkouts on disk with their Claude Code state. Rails-first. Use when the user says "set up parallel checkouts", "make a <project>2", "add another checkout of this project", "second working copy", "second copy of a devcontainer project", "run two suites in parallel", "remove <project>3", "rename this project's checkouts", or invokes the parallel-checkouts skill.
---

# Parallel checkouts

A **checkout** here is a full, permanent clone of a project's repository
in its own directory (`~/dev/app`, `~/dev/app2`, ...), not a git
worktree. Each checkout carries an **identity** -- a suffix and a port
offset -- and everything that would otherwise collide between two
copies of the project follows that identity: database names, Redis
database numbers, the ports the app opens. With that in place, a full
suite run in one checkout cannot see or disturb a run in another.

Why clones rather than worktrees: git refuses to check out one branch
in two worktrees, and two checkouts sitting on the default branch at
once is a supported use (verifying mainline behavior in one while the
other works on a feature). More to the point, the isolation a full
suite needs lives in the services, not in git: two worktrees of one
checkout share its test database and ports. Worktrees stay useful
*inside* a checkout for editing and for specs run one at a time, and
they run under that checkout's identity; they do not make two full
runs safe.

The **primary** checkout is the original one. It keeps an empty suffix
and a zero offset, which is also what a checkout that sets nothing
gets, so preparing a project never changes how the primary behaves.

## Pick the mode

- **prepare** -- the project has never been set up for this. Produces
  tracked changes, shipped as a pull request in that project. Run once
  per project, from its primary checkout.
- **add** -- the project is prepared (or needs no preparation; see
  below) and the user wants checkout N. Machine-local: nothing is
  committed.
- **remove** -- tear down checkout N. Machine-local and destructive.
- **move** -- rename or relocate a project's checkouts on disk, the
  primary and its parallel checkouts together, carrying Claude Code's
  memory, session history, and links along. Machine-local.

If the user asks for a new checkout of an unprepared project, run
**prepare** first, then **add** from the preparation branch; the add
mode does not wait for the preparation to merge (see Step 1 of add).

**Tell which kind of project this is before anything else:**

- **No local services.** Nothing in the project talks to a database,
  Redis, or a server port during its suite (a gem, a CLI, a repository
  of prose and scripts). There is nothing to isolate: skip prepare,
  and in add skip every step marked *services*, *native*, or
  *containerized*.
- **Native services.** The app's Postgres and Redis run directly on
  the host (Homebrew, a system package), shared by every project on
  the machine. A SQLite database already lives inside each checkout's
  directory and needs no edit.
- **Containerized services.** A Docker Compose file (often under
  `.devcontainer/`) starts the database, Redis, or the app itself.
  Each checkout gets its own Compose project, so its containers,
  networks, and volumes are its own, and its published host ports move
  by offset. The native recipe sets neither the project name nor the
  published ports, so it is wrong here: prepare has a containerized
  section, and add and remove have steps marked *(containerized)*.

Signals: `config/database.yml` with no `host:` or a `localhost` host
and no compose file means native. A `docker-compose*.yml`,
`compose*.yml`, or `.devcontainer/docker-compose*.yml` that defines a
database or Redis service means containerized, even when the app
itself runs on the host.

## The identity

Every identity variable carries a **project prefix** chosen once, in
prepare: the project's name upper-cased with non-letters dropped
(`app-server` becomes `APPSERVER`), shortened to something readable.
A shell that wanders from one project's checkout into another's then
carries variables this project's guard or stack scripts recognize as
foreign. Below,
`PRJ` stands for the chosen prefix.

For checkout N (N = 2, 3, ...; the primary is checkout 1):

| Variable | Primary | Checkout N |
| --- | --- | --- |
| `PRJ_CHECKOUT_SUFFIX` | (empty) | `N` |
| `PRJ_CHECKOUT_INDEX` | `0` | `N - 1` |
| `PRJ_PORT_OFFSET` | `0` | `200 * (N - 1)` |
| `PRJ_CHECKOUT_ROOT` | (unset; set in a containerized primary) | the checkout's absolute path |
| `COMPOSE_PROJECT_NAME` *(containerized)* | today's project name | today's name plus `N` |

A containerized primary sets the whole block for itself (suffix empty,
index 0, offset 0, its root, every port at its default), so the stack
scripts can check its shell; see containerized prepare Step 5.

plus one derived variable per port and per Redis role, below. They are
exported from the checkout's `.envrc` ([direnv](https://direnv.net/)).
Every tracked file that reads one falls back to today's literal value,
so an unset variable means primary behavior. Checkout N's ports and
Redis numbers follow from N alone, so there is no list of checkouts to
maintain; the directory names say which exist.

**Commands aimed at another checkout go through `direnv exec`.** A
session's shell commands are not interactive, so direnv's prompt hook
does not run on `cd`, and `cd <checkout> && bin/rails ...` runs with
whatever identity the session started with. `direnv exec <checkout>
<command>` loads that checkout's `.envrc` and runs the command without
changing directory, so pair it with `cd` or absolute paths:
`cd <checkout> && direnv exec . bin/rails ...`.

## Mode: prepare (native services)

Work on a branch in the primary checkout, following the project's own
branch, commit, and pull request conventions. The deliverable is one
pull request whose every change is inert when the identity is unset.

### Step 1 -- Check whether it is already prepared

Search `config/` for `_CHECKOUT_SUFFIX` (whatever the prefix) and look
for a `docs/parallel-checkouts.md`. If both are present the project is
prepared: say so, make no edits, and offer the add mode. If only one
is, report what is missing and treat the rest of this mode as a
completion pass.

### Step 2 -- Inventory what two copies would share

Read, don't guess. For each item record the file, the current literal,
and whether it is read in development, test, or production:

- **Database names** -- `config/database.yml` (and any second database
  file). Test and development names collide; production names are
  never touched. Check for `DATABASE_URL` in the primary's `.env`,
  `.envrc`, and `config/`: Rails lets it override `database.yml` for
  the current environment, so a checkout that inherits it uses the
  primary's database whatever the file says. Where development or test
  reads it, it gets the same per-checkout treatment as a Redis URL.
- **Redis** -- every place a Redis connection is made in `config/`,
  `app/`, and `lib/`: explicit reads (`ENV.fetch("REDIS_URL")`, a
  literal `redis://` URL) and implicit ones, which read `REDIS_URL`
  with nothing in the code saying so -- Sidekiq with no `config.redis`,
  `Redis.new` with no `url:`, `redis_cache_store` with no `url:`,
  Resque, an Action Cable `redis` adapter with no `url`. Note each
  **role** (jobs, Action Cable, cache, rate limiting, ...) and its
  default database number. Two roles that read the same variable with
  different default database numbers are two roles, not one. A role
  only production uses (an Action Cable adapter that is `async` in
  development and `test` in test) is left alone.
- **Ports the app opens** -- the dev server (`PORT` in
  `config/puma.rb`, `Procfile.dev`, `bin/dev`), a pinned
  `Capybara.server_port`, webpack or Vite dev servers, anything else
  bound to a fixed port. A port chosen at random (Capybara's default,
  a WebDriver started by Selenium Manager) needs nothing. Every pinned
  port moves by the same 200-per-checkout offset, so no two pinned
  ports may differ by a multiple of 200, or checkout N's app port lands
  on checkout M's other port (3000 and 4000 collide at checkout 6).
  When two do, say so and ask which to move.
- **Other shared servers** -- Elasticsearch or OpenSearch indexes,
  S3-compatible buckets in a local MinIO, a shared mail catcher. Each
  gets the same treatment as Redis: a per-checkout name or number
  inside the one server, defaulting to today's.
- **Specs that stub the variables you are about to wrap.** A spec
  that stubs `ENV['REDIS_URL']` to test production behavior passes in
  the primary and fails in checkout N, whose `.envrc` sets the new
  per-role variable that now takes precedence. Search `spec/` (or
  `test/`) for each variable Step 4 wraps, and have those specs stub
  the per-checkout variable as absent too. The simultaneous run in
  add mode is what catches any this search misses.

Only what a test or dev run actually touches matters. Redis that the
suite stubs out entirely still needs isolating for the dev server, but
say which of the two it affects.

### Step 3 -- Choose the prefix and confirm the plan

Show the user the inventory, the proposed prefix, and the list of
edits, then continue. This is the only point in prepare that asks.

### Step 4 -- Make the edits

Each edit keeps today's literal as the fallback:

- **Database names:** append the suffix to development and test only.

  ```yaml
  development:
    database: app_development<%= ENV.fetch("PRJ_CHECKOUT_SUFFIX", "") %>
  test:
    database: app_test<%= ENV.fetch("PRJ_CHECKOUT_SUFFIX", "") %>
  ```

  If the test name already carries `ENV['TEST_ENV_NUMBER']` (the
  parallel_tests gem sets it to `""`, `"2"`, `"3"`, ... per worker),
  separate both numbers, or the primary's worker 2 and checkout 2's
  worker 1 both get `app_test2` (and checkout 2's worker 3 meets
  checkout 23's worker 1):
  `app_test<%= "_checkout#{ENV['PRJ_CHECKOUT_SUFFIX']}_" unless ENV.fetch("PRJ_CHECKOUT_SUFFIX", "").empty? %><%= ENV['TEST_ENV_NUMBER'] %>`.
  Rails' own `parallelize` appends `-<worker>` and needs nothing.

- **Redis roles:** give each role its own variable, falling back to
  the variable it reads today, then to today's literal. Production
  sets only the old variable, so it resolves exactly as before. An
  implicit reader gets the URL written out, so it can have a fallback.

  ```ruby
  url: ENV.fetch("PRJ_JOBS_REDIS_URL") { ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }
  ```

  Never collapse two roles onto one per-checkout variable: a single
  `REDIS_URL` set per checkout would put jobs and Action Cable in one
  database. YAML files that read ERB (`config/cable.yml`) take the
  same nested fetch. Checkout N's number for a role is its default
  plus N - 1 times the **stride**, one more than the highest default
  number among the roles development and test use: with defaults 0
  and 2 the stride is 3, so checkout 2 uses 3 and 5, clear of the
  primary's 0 and 2.

- **Ports:** where a port is a literal, read a prefixed variable
  instead: `Capybara.server_port = Integer(ENV.fetch("PRJ_CAPYBARA_PORT", 3001))`.
  If the literal already comes from an unprefixed variable, keep that
  variable name and let the `.envrc` set it. `PORT` is the exception
  to reaching for an existing variable: foreman and its kin assign
  `PORT` to every process they start (from 5000, or from an inherited
  `PORT`, stepping by 100 per process type), so a `Procfile.dev` line
  `rails server -p 3000` must become
  `rails server -p ${PRJ_APP_PORT:-3000}`, never `-p ${PORT:-3000}`,
  or the primary's dev server moves to foreman's port. Puma's own
  `ENV.fetch('PORT')` stays as it is; the `.envrc` sets both.

- **The guard:** copy `templates/parallel_checkout_guard.rb` (in this
  skill's directory) to
  `config/initializers/00_parallel_checkout_guard.rb`, so it loads
  before any initializer that might touch a database or Redis at boot.
  Replace `PRJ` with the prefix, then run the project's linter
  autocorrect on it. Its header says what it refuses; the project's
  doc repeats that for people who never read the skill.

- **The doc:** write `docs/parallel-checkouts.md` from
  `templates/parallel-checkouts.md`, filling in the prefix, the
  variables and their defaults, the Redis roles and the stride, and
  the `.envrc` block. Link it from the README's development section.

### Step 5 -- Verify, then ship

1. With the identity unset, run the project's full suite: it must
   pass exactly as on the default branch (defaults unchanged).
2. With a checkout-2 identity exported by hand in one shell, run
   `bin/rails runner -e test 'puts ActiveRecord::Base.connection_db_config.database'`:
   it must print the suffixed name. This is a spot check; the real
   proof is running two suites at once after the add mode.
3. Open the pull request per the project's conventions. Its
   description says the change is inert until a checkout sets an
   identity, lists every default kept, and names the production
   configuration it does not touch.

## Mode: prepare (containerized)

The deliverable is again one pull request in the project, plus the
primary's own identity on this machine. Every tracked change falls back
to today's value, and the stack scripts run a checkout with no identity
at all under the compose file's own default name, so a teammate who
sets nothing sees no difference. The primary gets an identity anyway,
so the scripts can tell it from checkout N and check its shell.

### Step 1 -- Check whether it is already prepared

Look for the six stack scripts in `bin/`, a compose file whose `name:`
reads `COMPOSE_PROJECT_NAME`, and `docs/parallel-checkouts.md`. All
three means prepared: offer the add mode instead. Some but not all
means a completion pass: report what is missing and finish it.

### Step 2 -- Inventory what two copies would share

- **The compose files and today's project name.** Every compose file
  the project's scripts, README, or `devcontainer.json` use. Read
  today's name from the existing volumes
  (`docker volume ls --filter label=com.docker.compose.project`), not
  from the files: the primary must keep the name its volumes carry or
  it comes up with empty databases. A top-level `name:` usually agrees;
  Compose's default is the compose file's directory name, and for
  `.devcontainer/` that is `devcontainer`, which every project laid out
  that way shares. When today's name is a directory default, give the
  checkouts a project-specific name (`<prefix lowercased><N>`) and keep
  the primary's as it is.
- **Published host ports** -- every `ports:` entry, in any form
  (`"3000:3000"`, `"127.0.0.1:3000:3000"`, or the long form with
  `published:`), and `devcontainer.json`'s `forwardPorts` and `appPort`.
  The host side moves by offset; the container side never does. Read
  services behind a `profiles:` key too: `compose config` omits them
  unless a profile is active.
- **An app that runs on the host** against Compose's database or
  Redis. Its connections go to the published ports, so checkout N's app
  would reach the primary's database. Every host-side connection gets
  the native path's port treatment (`port: <%= ENV.fetch("PRJ_DB_PORT", 5432) %>`,
  the Redis URL's port likewise), database names need no suffix since
  each checkout has its own server, and the native guard initializer
  goes in too. The app's own pinned ports (its dev server, a pinned
  test server) are `PRJ_*_PORT` names as well, so they belong in the
  `.envrc` block's `identity_names`: the stack scripts compare every
  one.
- **Host networking.** A service with `network_mode: host` publishes
  nothing: every port it listens on or connects to is a host port. A
  database or Redis service there moves its own listen port
  (`command: -p ${PRJ_DB_PORT:-5432}`, `--port` for Redis), and an app
  service there reads the moved ports through
  `environment: PRJ_DB_PORT: ${PRJ_DB_PORT:-5432}`, one line per
  variable, rather than through the whole env file.
- **Things that escape the project name.** Each is shared by every
  checkout, and `docker-down --volumes` in checkout N can delete the
  primary's copy:
  - a `container_name:` key (remove it);
  - a volume or network with an explicit `name:` (interpolate it:
    `name: ${COMPOSE_PROJECT_NAME:-<today's name>}_pgdata`, which keeps
    the primary's existing volume);
  - `external: true` networks and volumes (say so and ask whether the
    sharing is intended; Compose never removes them);
  - an `image:` tag on a service that also has `build:` (every
    checkout builds and tags the same image; interpolate the tag or
    drop `image:`);
  - bind mounts to host paths outside the checkout
    (`~/.cache/bundle`, `../shared`).
- **Hardcoded Docker names** -- search the README, docs, scripts,
  `bin/`, and data migrations for `docker exec`, `docker run`,
  `docker cp`, `docker logs`, `docker volume`, `docker network`,
  `<project>-<service>-1`, `<project>_<service>_1`, and
  `<project>_default`. Each `docker exec` becomes `bin/dexec` (or
  `DEXEC_SERVICE=<service> bin/dexec`); say what the others should
  become.
- **Writers of `.devcontainer/.env`** -- an `initialize.sh` or a README
  step. The `.envrc` block shares the file with them; one that
  overwrites the file (`> .devcontainer/.env`) wipes the identity, so
  it must append or rewrite only its own lines.
- **Specs that stub the variables you are about to wrap**, as in the
  native path.

### Step 3 -- Choose the prefix and confirm the plan

As in the native path: show the inventory, the prefix, and the edits,
then continue.

### Step 4 -- Make the edits

- **The project name:** `name: ${COMPOSE_PROJECT_NAME:-<today's name>}`
  at the top of each compose file.
- **Host ports:** `"${PRJ_APP_PORT:-3000}:3000"` (or
  `"127.0.0.1:${PRJ_DB_PORT:-5432}:5432"`, or
  `published: "${PRJ_WEB_PORT:-8080}"`) for each published port, one
  variable per port, named for what listens there. The same 200-port
  offset applies, so no two published ports may differ by a multiple
  of 200, as in the native path.
- **The escapes and host-side connections** from Step 2.
- **The stack scripts:** copy `compose-project`, `dexec`, `docker-up`,
  `docker-down`, `docker-rebuild`, and `check-parallel-dev` from this
  skill's `templates/` into the project's `bin/`, replacing `PRJ` with
  the prefix and keeping them executable. If the compose file is not
  `.devcontainer/docker-compose.yml`, adapt `compose_project_dir`, the
  compose file name beside it, and the override file name
  (`docker-compose.override.yaml`, or `compose.override.yaml` beside a
  `compose.yaml`) in `bin/compose-project`; the other scripts follow
  it. If the app service is not named `app`, say so in the doc:
  `DEXEC_SERVICE` picks the service.
- **Hardcoded Docker names:** replace each `docker exec` with
  `bin/dexec`.
- **Ignore files:** `.devcontainer/.env`, `.devcontainer/.env.direnv-tmp`,
  and the override file are per-machine; make sure `.gitignore` covers
  them.
- **The doc:** write `docs/parallel-checkouts.md` from
  `templates/parallel-checkouts-containerized.md`: the variables, the
  `.envrc` block, and how to add a checkout. Link it from the README's
  development section.

### Step 5 -- Give the primary its identity, verify, then ship

1. Add the primary's identity to its `.envrc`: the containerized block
   from add mode Step 3 with `COMPOSE_PROJECT_NAME` set to today's
   name, suffix empty, index 0, offset 0, the root, and every port at
   its default. Then `direnv allow`. Confirm the env file kept its
   other lines by comparing the key names before and after,
   `sed -E 's/[[:space:]]*[=:].*//' .devcontainer/.env`, which prints
   names only.
2. `cd <primary> && direnv exec . bin/check-parallel-dev` must pass.
3. With the stack up (`bin/docker-up`), run the project's full suite
   through `bin/dexec`: it must pass as on the default branch.
4. Open the pull request, as in the native path.

## Mode: add checkout N

Run from the primary checkout. Pick N as the lowest number from 2 up
whose `<primary-basename>N` directory does not exist on disk. Never
change the primary's checked-out branch or working tree in this mode.

**Never print secrets into the session.** `.envrc`, `.env`, and key
files hold tokens, and whatever a command prints lands in the
transcript. Do not Read, `cat`, or diff them: copy with `cp -p`, find
the lines to change with a `grep -n` narrow enough to print only those
lines, edit with `sed`, and when reporting, name files and variables,
never values.

### Step 1 -- Clone

Clone from the primary's `origin` URL into a sibling directory named
`<primary-basename>N`:

```bash
git clone "$(git -C <primary> remote get-url origin)" <primary>N
```

In a fork, also add `upstream`:
`git -C <primary>N remote add upstream "$(git -C <primary> remote get-url upstream)"`.
Leave deploy remotes (Heroku and the like) out: a second checkout is
for development. When the preparation has not merged yet, check out
its branch in the new clone; it is pushed, since its pull request is
open.

### Step 2 -- Carry over what git does not

- **Excludes:** append each line of the primary's `.git/info/exclude`
  that the new clone's file lacks. Without this, files the primary
  hides (scratch directories, local tool-version files) show up as
  untracked in the new checkout, one `git add -A` from a commit.
- *(containerized)* **`.devcontainer/.env`:** copy it without its
  identity lines, so the stack scripts refuse the new checkout until
  its own `.envrc` loads, instead of driving the primary's project:
  `(umask 077; grep -Ev '^[[:space:]]*(export[[:space:]]+)?(COMPOSE_PROJECT_NAME|PRJ_CHECKOUT_SUFFIX|PRJ_CHECKOUT_INDEX|PRJ_CHECKOUT_ROOT|PRJ_PORT_OFFSET|PRJ_[A-Za-z0-9_]*_PORT)[[:space:]]*([=:]|$)' <primary>/.devcontainer/.env > <new>/.devcontainer/.env)`.
  Ask before copying a personal override file.
- **Ignored configuration the app needs to boot:** list the primary's
  ignored files outside bulky directories --
  `git -C <primary> ls-files --others --ignored --exclude-standard --directory`,
  skipping `tmp/`, `log/`, `node_modules/`, `coverage/`,
  `vendor/bundle/`, `public/assets/`, `public/packs*/`, `storage/`,
  editor and OS state (`.DS_Store`, `.ruby-lsp/`, `.idea/`), and
  `.claude/` and `.envrc`, which the next steps handle.
  Copy the ones the app reads (`config/master.key`,
  `config/credentials/*.key`, `.env`, a local tool-versions file)
  into the new checkout and nowhere else, and tell the user which
  files were copied.

### Step 3 -- Write the `.envrc` and the identity

The new `.envrc` starts as a copy of the primary's (`cp -p`): it often
carries tokens and settings every checkout needs, services or not.
Change any line that labels the checkout for a human (a terminal
background color, a prompt tag) so the two terminals look different.

First check whether `.envrc` is tracked
(`git -C <primary> ls-files --error-unmatch .envrc`). If it is, the
identity block goes in an untracked `.envrc.local` instead, excluded
in the new checkout's `.git/info/exclude`, and the tracked `.envrc`
needs a `source_env_if_exists .envrc.local` line, which is a change
for prepare's pull request.

Then append the identity block, replacing an existing one rather than
adding a second. The native and containerized blocks are alternatives:
use the one for this project's kind, with the port and Redis lines
taken from the project's doc, which lists exactly the variables that
project reads.

*(services, native)* For a project prefixed `PRJ`:

```bash
# Parallel-checkout identity. See docs/parallel-checkouts.md.
export PRJ_CHECKOUT_SUFFIX=2
export PRJ_CHECKOUT_INDEX=1
export PRJ_PORT_OFFSET=$((200 * PRJ_CHECKOUT_INDEX))
export PRJ_CHECKOUT_ROOT="$PWD"
export PRJ_APP_PORT=$((3000 + PRJ_PORT_OFFSET))
export PORT=$PRJ_APP_PORT
export PRJ_CAPYBARA_PORT=$((3001 + PRJ_PORT_OFFSET))
export PRJ_JOBS_REDIS_URL="redis://localhost:6379/$((0 + 2 * PRJ_CHECKOUT_INDEX))"
export PRJ_CABLE_REDIS_URL="redis://localhost:6379/$((1 + 2 * PRJ_CHECKOUT_INDEX))"
```

(Here the roles default to 0 and 1, so the stride is 2.)

*(containerized)* Instead, the block names the Compose project and the
published ports, then copies the identity into `.devcontainer/.env`,
where Compose and the stack scripts read it, keeping the file's other
lines (its secrets, and whatever an initializer wrote):

```bash
# Parallel-checkout identity. See docs/parallel-checkouts.md.
export COMPOSE_PROJECT_NAME=app2
export PRJ_CHECKOUT_SUFFIX=2
export PRJ_CHECKOUT_INDEX=1
export PRJ_PORT_OFFSET=$((200 * PRJ_CHECKOUT_INDEX))
export PRJ_CHECKOUT_ROOT="$PWD"
export PRJ_APP_PORT=$((3000 + PRJ_PORT_OFFSET))
export PRJ_DB_PORT=$((5432 + PRJ_PORT_OFFSET))

# Copy the identity into .devcontainer/.env on every load, keeping every other line.
identity_names="COMPOSE_PROJECT_NAME PRJ_CHECKOUT_SUFFIX PRJ_CHECKOUT_INDEX PRJ_CHECKOUT_ROOT PRJ_PORT_OFFSET PRJ_APP_PORT PRJ_DB_PORT"
set -- $identity_names
identity_lines="^[[:space:]]*(export[[:space:]]+)?($(IFS='|'; echo "$*"))[[:space:]]*([=:]|\$)"
rm -f .devcontainer/.env.direnv-tmp
(
  umask 077
  {
    if [ -e .devcontainer/.env ]; then
      grep -Ev "$identity_lines" .devcontainer/.env
      [ $? -le 1 ] || exit 1 # 1 means no other lines; 2 is an error, so keep the file untouched
    fi
    for name in $identity_names; do printf '%s=%s\n' "$name" "${!name}"; done
  } > .devcontainer/.env.direnv-tmp
) && mv .devcontainer/.env.direnv-tmp .devcontainer/.env
```

`identity_names` lists exactly the variables the block sets, one port
name per port, so a variable some parent shell happens to export is
never copied, and the file's own lines under other names are never
touched. Keep it in step with `bin/compose-project`'s identity
(`COMPOSE_PROJECT_NAME`, the `PRJ_CHECKOUT_*` trio, `PRJ_PORT_OFFSET`,
and the `PRJ_*_PORT` names): a name the block exports but leaves out
of the list is one the scripts see in the shell and not in the file,
and they refuse every command. The strip pattern also removes the
`KEY: value` and bare `KEY` forms the scripts refuse, and the file
stays readable only by its owner.

*(services)* Then record the suffix in the new clone's git directory,
where `git clean` cannot reach it and every worktree of the clone
finds it:
`printf '2\n' > "$(git -C <new> rev-parse --path-format=absolute --git-common-dir)/parallel-checkout"`.
It marks this as a numbered checkout: the native guard and the stack
scripts refuse to run it without its identity, instead of reaching the
original checkout's databases or stack.

Then tell the user which variables the `.envrc` sets and which lines
changed (names only), and `direnv allow <new>`. Ask the user to run it
themselves if the harness refuses: allowing an `.envrc` is a trust
decision.

### Step 4 -- Check the block is free *(services)*

- Every port in the block is free:
  `lsof -nP -iTCP:<port> -sTCP:LISTEN` prints nothing.
- *(native)* Every Redis database number in the block is below the server's count
  and empty: `redis-cli -p <port> CONFIG GET databases` (16 by
  default) and `redis-cli -p <port> -n <db> DBSIZE` (0) for each.
  Without `redis-cli`, the primary can ask the same, since its gems
  are installed:
  `cd <primary> && direnv exec . bin/rails runner 'r = Redis.new(url: "redis://localhost:<port>/<db>"); p r.config(:get, "databases"), r.dbsize'`. A non-empty database belongs to something else --
  another project on the same server -- so stop and say which. If the
  block passes the count, stop and say so too: raising `databases` in
  the Redis config is the user's call, since every project shares it.
  With no Redis server running at all, say so and move on.

### Step 5 (native) -- Databases and dependencies

Nothing here runs until the new checkout proves it resolves its own
database names. A clone on a branch without the preparation has no
suffix and no guard, and `db:schema:load` there would wipe the
primary's databases. So first:

```bash
cd <new> && direnv exec . bundle install
cd <new> && direnv exec . bin/rails runner 'puts ActiveRecord::Base.connection_db_config.database'
cd <new> && direnv exec . bin/rails runner -e test 'puts ActiveRecord::Base.connection_db_config.database'
```

Both names must end in the checkout's suffix, and
`config/initializers/00_parallel_checkout_guard.rb` must exist.
Anything else stops here.

That check holds only for the branch checked out now. The suffix and
the guard are tracked files, so a branch older than the preparation
(an in-flight feature branch, a `git bisect` step, the default branch
before the preparation merges) has neither, and a test run there
purges the primary's test database. Install a `post-checkout` hook in
the clone that warns when a checkout leaves the guard missing, unless
the clone already has a `post-checkout` hook, in which case tell the
user instead of replacing it:

```bash
hook="$(git -C <new> rev-parse --path-format=absolute --git-common-dir)/hooks/post-checkout"
cat > "$hook" <<'HOOK'
#!/bin/sh
[ -f config/initializers/00_parallel_checkout_guard.rb ] && exit 0
echo "WARNING: this branch predates the parallel-checkout preparation." >&2
echo "Rails here uses the ORIGINAL checkout's databases. Merge the default" >&2
echo "branch into it before running anything." >&2
HOOK
chmod +x "$hook"
```

Then create the databases. In development, `db:create` and
`db:schema:load` also cover the test database:

```bash
cd <new> && direnv exec . bin/rails db:create db:schema:load
```

To start from the primary's development data instead of an empty
schema, copy it in place of that command, then set up only test:

```bash
createdb -T <app>_development <app>_development<N>
cd <new> && direnv exec . bin/rails db:create db:schema:load RAILS_ENV=test
```

`createdb -T` fails while the source has open connections; stop the
primary's dev server first.

### Step 5 (containerized) -- Its own stack

Nothing starts until the new checkout proves it resolves its own
project: `cd <new> && direnv exec . bin/check-parallel-dev` must name
exactly `<today's name>N` (or the project-specific name prepare chose)
and pass every check it can run with the stack down.

That check holds only for the branch checked out now. A branch older
than the preparation has no stack scripts, and the old compose file's
fixed host ports, `container_name:` keys, and scripts that
`docker exec` a fixed container name reach the primary's stack or
collide with it. Install a `post-checkout` hook in the clone, unless
it already has one, in which case tell the user instead:

```bash
hook="$(git -C <new> rev-parse --path-format=absolute --git-common-dir)/hooks/post-checkout"
cat > "$hook" <<'HOOK'
#!/bin/sh
[ -f bin/compose-project ] && exit 0
echo "WARNING: this branch predates the parallel-checkout preparation." >&2
echo "Its compose file and scripts reach the ORIGINAL checkout's stack." >&2
echo "Merge the default branch into it before running anything." >&2
HOOK
chmod +x "$hook"
```

Then build and start the stack, waiting until its services report
healthy, and bootstrap inside its containers the way the project's
README (or `devcontainer.json`'s `postCreateCommand`) does, every
command through `bin/dexec`. When the app service's own command needs
the gems to boot, follow the README's order rather than this one.

```bash
cd <new> && direnv exec . bin/docker-rebuild --wait
cd <new> && direnv exec . bin/dexec bundle install
```

Before anything creates or loads a database, confirm where the app
connects: `cd <new> && direnv exec . bin/dexec bin/rails runner 'p ActiveRecord::Base.connection_db_config.configuration_hash.values_at(:host, :port)'`
must name a Compose service host, or `localhost` with this checkout's
own database port. A host-run app checks the same through
`direnv exec . bin/rails runner`, and its guard initializer must exist.
Anything else reaches the primary's database: stop.

Then create the databases:

```bash
cd <new> && direnv exec . bin/dexec bin/rails db:create db:schema:load
```

To start from the primary's development data instead, run
`bin/rails db:create` in place of that command, confirm the new
development database has no tables, then pipe a dump between the two
database containers (the primary's must be running; `-U` is the
image's `POSTGRES_USER`), and set up test on its own:

```bash
set -o pipefail
(cd <primary> && direnv exec . env DEXEC_SERVICE=db bin/dexec pg_dump -U postgres <database>) |
  (cd <new> && direnv exec . env DEXEC_SERVICE=db bin/dexec psql -q -v ON_ERROR_STOP=1 --single-transaction -U postgres <database>)
cd <new> && direnv exec . bin/dexec env RAILS_ENV=test bin/rails db:create db:schema:load
```

`bin/dexec` forwards piped input and turns off the terminal on both
ends, `pipefail` surfaces a failed `pg_dump`, and `ON_ERROR_STOP` with
one transaction leaves an empty database rather than a half-loaded one.

### Step 6 -- Share Claude Code state with the primary

Two checkouts of one project should share what Claude Code has learned
about it, and nothing that belongs to one session:

- **Auto-memory.** Claude Code keeps per-project memory under
  `~/.claude/projects/<dir>/memory`, where `<dir>` is the checkout's
  absolute path with every character other than a letter, digit, or
  hyphen replaced by `-` (a path ending in `dev/my_app2` ends in
  `-dev-my-app2`). Find the primary's `<dir>` in that listing to
  confirm the rule before relying on it. Create the new checkout's
  `<dir>` if needed and make its `memory` a relative symlink to the
  primary's. If `memory` already exists there as a real directory (a
  session already ran in the new checkout), stop and ask: merging two
  memories is the user's call.
- **The project's `.claude/` directory.** Link each **untracked**
  entry of the primary's `.claude/` into the new checkout, one by one,
  as relative symlinks. Tracked entries come from the clone; replacing
  one with a symlink shows as a type change in git, and an edit on a
  branch in the new checkout would land in the primary's working tree.
  Walk `.claude/` itself entry by entry, even when nothing in it is
  tracked, so the runtime state below stays out. Below the top level,
  an untracked directory that holds no tracked files is linked whole;
  a directory mixing both is walked, linking its untracked entries.
  List candidates with
  `git -C <primary> ls-files --others --directory -- .claude`.
  Then add each linked path to the new checkout's
  `.git/info/exclude`, with no trailing slash: a symlink is not a
  directory, so the primary's `.claude/plans/`-style ignore patterns do
  not match it, and the links would otherwise show as untracked.
- **Never link** Claude Code's per-session runtime state:
  `.claude/worktrees/`, `scheduled_tasks.*`, `checkpoints/`,
  `mailbox/`, `agent-registry.json`, `first-run`,
  `assistant-daemon-state.json`, `routines/.state/`,
  `agent-memory-local`. The new checkout's own worktrees must live in
  the new checkout.

Tell the user what the links share, because two sessions can now
write to the same files: one memory directory (a finish-up pass in
either checkout edits the same index), one plans directory (do not
work the same plan from both at once), and one `settings.local.json`
(permission approvals in either apply to both).

### Step 7 -- Verify

1. Prove the isolation *(services)*: start the full suite in the
   primary and in the new checkout at the same moment, each through
   `direnv exec` on its own checkout. Both must pass, with identical
   example counts. A failure that appears only when the two overlap
   is a collision the inventory missed: find the shared resource, add
   it to the doc and the tracked config, and rerun.
   *(containerized)* Run each suite through `bin/dexec`, and first
   confirm `bin/check-parallel-dev` passes every check, including
   reaching the app container, in both checkouts.
2. Prove the guard *(services, native)*, matching the guard's own words rather
   than any failure, since an app can fail to boot for unrelated
   reasons:
   - `cd <new> && direnv exec . bin/rails runner -e test 'puts 1'`
     prints `1`;
   - `cd <new> && env -i HOME="$HOME" PATH="$PATH" bin/rails runner -e test 'puts 1'`
     fails with "is not loaded in this shell";
   - when the primary's checked-out branch has the guard,
     `cd <primary> && direnv exec <new> bin/rails runner -e test 'puts 1'`
     fails with "carries the parallel-checkout identity of". When it
     does not, skip this one and say so: add mode never changes the
     primary's branch.

## Mode: remove checkout N

Destructive at every step. Confirm the whole list with the user before
starting, and check each target mechanically rather than by reading
it: N is 2 or more; the directory's name is exactly
`<primary-basename>N`; the checkout's `origin` URL matches the
primary's; *(services)* its marker (`<git-common-dir>/parallel-checkout`)
says N; and `realpath <checkout>` is neither the primary's realpath nor
inside it.
Use that realpath for every step below, so a symlinked checkout path
removes the checkout rather than only the link.

1. **Look before deleting.** In the checkout:
   - `git status` is clean;
   - every local branch exists on `origin` at the same commit
     (`git log --branches --not --remotes` prints nothing);
   - `git stash list` prints nothing;
   - `git worktree list` shows only the checkout itself, or each
     worktree it lists is clean by the same three checks;
   - its ignored files (`git ls-files --others --ignored --exclude-standard --directory`)
     are shown to the user by name, since deleting the directory
     deletes them too.

   Anything unexpected stops the removal and goes back to the user.
2. **Stop its processes:** a dev server, a Sidekiq worker, anything
   bound to its ports.
3. *(containerized)* Resolve the primary's project name and this
   checkout's the same way, through their own stack scripts
   (`cd <dir> && direnv exec . bash -c '. bin/compose-project && echo "$COMPOSE_PROJECT_NAME"'`),
   and require this checkout's to be exactly the primary's name
   followed by N (or the project-specific name prepare chose). Then
   list what its volumes resolve to
   (`cd <checkout> && direnv exec . bash -c '. bin/compose-project && compose config --format json'`,
   the `name` of each entry under `volumes`, skipping those marked
   `external`, which `down --volumes` never removes) and require every
   one to start with that project name and an underscore: a volume with
   a fixed `name:` is shared, and removing it deletes the primary's
   data. Only then
   `cd <checkout> && direnv exec . bin/docker-down --volumes --rmi local --remove-orphans`,
   which removes that project's containers, networks, volumes, and
   locally built images. Never a bare `docker compose down` there. If
   the checkout sits on a branch older than the preparation, with no
   stack scripts, check out its default branch first (step 1 already
   showed nothing unpushed).
   *(services, native)* Resolve its database names the way add Step 5 (native) does
   and require both to end in its suffix, then drop exactly those:
   `dropdb <name>` for each. Parallel test workers leave more
   (`<name>-0`, `<name>-1` from Rails' `parallelize`; `<name>1`,
   `<name>2` from parallel_tests): list them with
   `psql -lqt | cut -d '|' -f 1` filtered to names that start with
   the checkout's own test name plus a separator, show the list, and
   drop those after confirmation. Read its Redis URLs from the checkout
   itself (`direnv exec <checkout> printenv PRJ_JOBS_REDIS_URL`, one
   per role), refuse any database number below the stride (those are
   the primary's), and flush each with `redis-cli -u "<url>" FLUSHDB`.
4. Remove its `~/.claude/projects/<dir>` directory, after checking
   that `<dir>` names this checkout and that its `memory` is a symlink
   (`test -L <dir>/memory`), so the primary's memory is untouched.
5. Delete the checkout: `rm -rf -- "<realpath>"`, then any symlink
   that pointed at it.

## Mode: move checkouts

Rename or relocate a project's checkouts on disk -- after a repository
rename, say -- without losing what Claude Code keeps about them.
Claude Code keys each project's memory, session history, trust answer,
and prompt history on the checkout's absolute path, so a bare `mv`
leaves the moved checkout with an empty memory, and every link the add
mode made into the old path breaks.

Move the primary and all its parallel checkouts together, keeping each
parallel checkout named `<new-primary-basename>N`: add and remove both
find checkouts by that name, so moving one parallel checkout alone
would hide it from both; offer to move them all instead. Keep the
moved checkouts siblings in one directory too: add mode's links
between them are relative (`../../<primary>/...`). A project with no
parallel checkouts is a move of one, and skips the steps about
siblings. Machine-local: nothing is committed.

A checkout reached through a symlink (`~/dev/app` linking to another
volume) is moved as the directory its `realpath` names, as remove mode
does; the user-facing link is one of the links Step 1 lists, and is
repointed in Step 6.

**Run it from a session outside every checkout being moved** (their
parent directory works). A session inside one loses its working
directory partway through.

Never print secrets: the add mode's rule applies to `.envrc` and its
kin here too.

### Step 1 -- Write down the move

For each checkout, record its old path, its new path, and the old and
new Claude Code project keys (the add mode's Step 6 gives the key
rule), in a scratch file outside the checkouts. That list is how an
interrupted move is resumed or reversed.

Then, while the old paths still exist, find the symlinks that point
into a checkout and would break when it moves, and add them to the
list. Both searches below use each checkout's `realpath` as its old
path.

**From outside.** Search the Claude Code config directory, the
user's bin directories, and the checkouts' parent directory, each
given by its `realpath` too, so a directory reached through a link
does not defeat the skip below. `OLDS` holds the old paths, one per
line:

```bash
OLDS='<old-path>
<old-path2>' find <dirs> -maxdepth 3 -type l -exec sh -c '
nl="
"
for l; do
  [ -e "$l" ] || continue
  t=$(realpath "$l"); inside=; hit=
  set -f; IFS=$nl
  for old in $OLDS; do
    case "$l" in "$old"/*) inside=1 ;; esac
    case "$t" in "$old"|"$old"/*) hit=1 ;; esac
  done
  unset IFS; set +f
  [ -n "$hit" ] && [ -z "$inside" ] && echo "$l -> $(readlink "$l")"
done' _ {} +
```

A link inside any moving checkout is skipped (Step 5 handles the add
mode's links between checkouts), a link already broken is left alone,
and matching an old path whole, or followed by `/`, keeps a sibling
such as `app-admin` out of the list for `app`. Resolving with
`realpath` catches relative targets (`../app/bin/x`) and links that
reach a checkout through another link.

**Inside.** A link within a checkout whose target is written as an
absolute path into that checkout breaks too. For each checkout,
`find <old-path> -path <old-path>/node_modules -prune -o -type l -lname '<old-path>/*' -print`
lists them, pruning any dependency directory too large to walk.

### Step 2 -- Check it is safe to move

Check these in order:

1. *(containerized)* Find the project name the stack scripts resolve
   (as remove Step 3 does). If it comes from the directory name rather
   than the identity, a move would strand the containers and volumes
   under the old name: stop and ask. Otherwise stop the stack with
   `cd <checkout> && direnv exec . bin/docker-down`, without
   `--volumes`: its bind mounts name the old path, and the file
   sharing behind them can hold files open, which the next check would
   report.
2. Nothing runs inside any checkout: no Claude Code session, dev
   server, suite, or shell with a job in it, and no editor or file
   watcher with it open, since those keep writing to the old path from
   elsewhere. For each checkout, with `<realpath>` its `realpath`
   (what `lsof` reports), these list processes working inside it and
   processes holding a file in it open; both must print nothing on
   standard output (`lsof +D` can warn on standard error about mounts
   it skips):

   ```bash
   lsof -d cwd -Fn | awk -v p="<realpath>" '$0 == "n" p || index($0, "n" p "/") == 1'
   lsof +D "<realpath>"
   ```

   The `awk` match takes the path whole or followed by `/`, so a
   session in a sibling such as `app-admin` or `app2` does not count.
3. No new path exists yet. No new project key exists as a directory
   under `~/.claude/projects/` or as a `projects` key in
   `~/.claude.json`: either one means a session ran there before (a
   trust answer can exist with no folder), so stop and ask, since
   merging two projects' state is the user's call.

A clean working tree is not required: a move deletes nothing, and
uncommitted work moves with the directory.

### Step 3 -- Move the directories

`mv` each checkout's `realpath` to its new path, all of them before any repair
below. Then repair each moved checkout's worktrees, which record
absolute paths in both directions. From the moved checkout, run
`git worktree repair`, passing the new path of every worktree that
lives inside the checkout (such as `.claude/worktrees/<name>`), or no
arguments when none does: a worktree that moved with the checkout
cannot be found without its path, and the same command also fixes the
`.git` file of every worktree outside the checkout, which still names
the old path. Then confirm each worktree `git worktree list` shows
answers `git -C <worktree> status`; a broken one is not always marked
prunable. Check `git config --get core.worktree` too, and repoint it
if set.

When the move follows a repository rename, set every checkout's
`origin` (and `upstream`, in a fork) to the new URL together, with
`git remote set-url`: remove mode refuses a checkout whose `origin`
differs from the primary's, and add mode clones from the primary's.

### Step 4 -- Move the Claude Code project folders

For each checkout, rename `~/.claude/projects/<old-key>` to
`<new-key>`. That carries its memory and its session history: Claude
Code finds a project's transcripts by its folder, so they resume from
the new path even though each still records the old working
directory.

Folders for paths inside the checkout (its worktrees, a subdirectory
a session started in) are keyed `<old-key>-...`; rename each to
`<new-key>-...` with the same tail. Two traps in matching them:

- Never match `<old-key>` followed by a digit: that is a sibling
  checkout's folder (`-app` is a prefix of `-app2`).
- A key is lossy, so `<old-key>-admin` may belong to a different
  project (a sibling directory named `app-admin`). Confirm each
  candidate by reading the `cwd` of one of its transcripts
  (`grep -m1 -ho '"cwd":"[^"]*"' <folder>/*.jsonl`) and requiring it
  to start with the old checkout path followed by `/`. A folder with
  no transcript is shown to the user, not guessed at.

Rename a confirmed folder even when it looks abandoned: its directory
is often still on disk, and deleting session history is not part of a
move.

### Step 5 -- Repoint the links the add mode made

- **Memory.** Each parallel checkout's project folder holds `memory`
  as a relative link into the primary's folder by its old key.
  Replace each with a link to the new key, from inside
  `~/.claude/projects/` so the relative target resolves:
  `cd ~/.claude/projects && ln -sfn ../<new-primary-key>/memory <new-key>/memory`,
  where `<new-key>` is that parallel checkout's. Check first that it
  is a link (`test -L`), never a real directory.
- **The project's `.claude/` entries.** Each parallel checkout links
  untracked entries of the primary's `.claude/` by relative paths
  naming the primary's old directory. Recreate each link with the new
  name. A link's path in `.git/info/exclude` is relative to the
  checkout, so the excludes stay as they are.

### Step 6 -- Repoint other links and caches

Show the user the links Step 1 listed, then repoint each to the new
path, keeping a relative link relative. A link from the inside search
moved with its checkout, so repoint it at its new location.

Then search for text that names an old path, listing file names only
(`grep -rlF <old-path> ...`) so no secret is printed:

- the Claude Code config directory: a skill's per-project cache, a
  settings file, a memory file under the moved project folders that
  gives a command with the path in it;
- each checkout's untracked configuration: `.claude/settings.local.json`
  (a permission rule such as `Bash(<old-path>/bin/rails:*)`), `.envrc`
  and `.envrc.local`, and *(containerized)* `.devcontainer/.env`;
- the values, not only the keys, of the `~/.claude.json` entries
  Step 8 moves: a per-project MCP server's arguments can name the path.

Update the references that drive behavior, editing a secrets file
with `sed` on the matching lines only. Replace an old path only where
it stands whole, followed by `/`, a quote, or the end of the value,
so a sibling path such as `<old-path>-admin` is left alone. Leave
historical records (logs, past timings, transcripts, finished plans)
as they were. A
value inside a `~/.claude.json` entry is rewritten in Step 8, as part
of that file's single rewrite.

### Step 7 -- Reload each checkout's environment

Run `direnv allow` in each moved checkout that has an `.envrc`, and
again after any edit to it, on the path the user's shell will use
(the symlink's, for a checkout reached through one; both when
unsure): direnv ties its approval to the file's path as spelled and
to its contents, and the `.envrc` of each parallel checkout (and of a
containerized primary) sets `PRJ_CHECKOUT_ROOT` from the directory it
loads in. A shell that loaded the identity before the move holds the
old root; open a new one. *(containerized)* `direnv allow` approves
the file without loading it, so start the stack with
`cd <checkout> && direnv exec . bin/docker-up`: the load rewrites the
identity lines of `.devcontainer/.env` with the new root before the
stack starts.

### Step 8 -- Move the path-keyed entries in Claude Code's own files

Two files key entries on a project path, and every running Claude Code
process rewrites them, including the session doing the move:
`~/.claude.json` (each project's trust answer and per-project
settings under `projects`, plus the `githubRepoPaths` list of local
clones per repository) and `~/.claude/history.jsonl` (the prompt
history the up arrow walks, one line per prompt, with a `project`
field).

Do this step last, with every other Claude Code session closed, in
any project: a session holds its own copy of `~/.claude.json` and can
write it back over the rewrite, and a prompt typed between the read
and the write would be lost from `history.jsonl`. For each file: copy
it to a backup, write the
rewritten version to a temporary file beside it, and `mv` that into
place. In `~/.claude.json`, rename every `projects` key equal to an
old path or starting with the old path and `/`, carrying the whole
entry, and replace the old paths in `githubRepoPaths` (renaming its
key too when the repository itself was renamed). In `history.jsonl`,
rewrite `project` fields the same way. Parse each line as JSON rather
than substituting text, so a prompt that happens to quote a path is
left alone. Rewrite any old path Step 6 found inside a moved entry's
values in the same pass. The moving session itself writes `~/.claude.json` when it
exits, so check it again from a new session in the moved primary: no
trust dialog means the entry survived. If the dialog appears, close
that session and rerun the `projects` and `githubRepoPaths` rewrite
from outside Claude Code (the same script works from a terminal),
then start it again.

### Step 9 -- Verify

- No old path exists, and every new one is a git checkout on the
  branch it was on, with the same `origin` URL as the primary.
- Every link Step 1 listed resolves (`test -e <link>`). (A broader
  `find -L <dirs> -type l`, which lists every broken link, also turns
  up stale links that have nothing to do with the move; judge only the
  ones Step 1 listed.)
- Each parallel checkout's `memory` resolves to the primary's, and its
  `.claude/` links resolve.
- *(services)* `direnv exec <checkout> printenv PRJ_CHECKOUT_ROOT`
  prints the new path in each parallel checkout; a native primary
  leaves it unset, so it prints nothing there, as before the move.
  *(containerized)* `cd <checkout> && direnv exec . bin/check-parallel-dev`
  passes in every checkout, the primary included.
- `claude --resume` from the moved primary lists its earlier sessions.

## Caveats to pass on

- **Memory and disk.** Each checkout has its own dependencies and
  databases on disk, and each running dev server or suite is its own
  set of processes.
- **One branch, one session.** Two checkouts on the same feature
  branch invite divergent commits to one ref. Both on the default
  branch for verification is fine.
- **Machine-level singletons stay single.** A browser-automation
  session in the user's own Chrome, a staging deploy, anything outside
  the checkout: one at a time.
- **A branch older than the preparation uses the primary's data.**
  Merge the default branch into a branch before checking it out in
  checkout N, and do not bisect across the preparation there. The
  `post-checkout` hook from add Step 5 (native or containerized) warns
  when this happens.
- **A containerized checkout's worktrees edit, the checkout runs.** Its
  containers bind-mount the checkout's own directory, so `bin/dexec`
  runs the checkout's code, not a worktree's, and the stack scripts
  refuse inside a worktree that has no identity of its own. Use
  worktrees there for editing and reviewing; run commands from the
  checkout.
- **Worktrees share their checkout's identity.** A worktree nested in
  a checkout picks up its `.envrc`; one created elsewhere needs
  `direnv exec <checkout>`. Two full suites from two worktrees of one
  checkout still collide, so run full suites one at a time per
  checkout.
