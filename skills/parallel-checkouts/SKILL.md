---
name: parallel-checkouts
description: Set up a project so several full, independent working copies of it (`<project>2`, `<project>3`, ...) can each run their own dev server and full lint+test suite at the same time on one machine, with no shared ports, databases, or Redis databases between them. Three modes -- prepare a project (a one-time pull request that makes its ports and database names follow a per-checkout identity), add checkout N (clone, identity, databases, shared Claude Code state), and remove checkout N. Rails-first. Use when the user says "set up parallel checkouts", "make a <project>2", "add another checkout of this project", "second working copy", "run two suites in parallel", "remove <project>3", or invokes the parallel-checkouts skill.
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
*inside* a checkout for editing and for specs run one at a time; they
do not make two full runs safe.

The **primary** checkout is the original one. It keeps an empty suffix
and a zero offset, which is also what a checkout that sets nothing
gets, so preparing a project never changes how the primary behaves.

## Pick the mode

- **prepare** -- the project has never been set up for this. Produces
  tracked changes, shipped as a pull request in that project. Run once
  per project, from its primary checkout.
- **add** -- the project is prepared (or needs no preparation; see
  below) and the user wants checkout N. Machine-local: nothing is
  committed except a registry row.
- **remove** -- tear down checkout N. Machine-local and destructive.

If the user asks for a new checkout of an unprepared project, run
**prepare** first, then **add** from the preparation branch; the add
mode does not wait for the preparation to merge (see Step 1 of add).

**Tell which kind of project this is before anything else:**

- **No local services.** Nothing in the project talks to a database,
  Redis, or a server port during its suite (a gem, a CLI, a repository
  of prose and scripts). There is nothing to isolate: skip prepare,
  and in add skip every step marked *services*.
- **Native services.** The app's database and Redis run directly on
  the host (Homebrew, a system package), shared by every project on
  the machine. This is the path this skill covers.
- **Containerized services.** A Docker Compose file (or a
  `.devcontainer/`) starts the database, Redis, or the app itself.
  **Stop here and say so plainly:** this skill does not yet cover
  containerized projects, and applying the native recipe to one is
  wrong -- per-container ports and Compose project names are the
  heart of that case, and the native steps set neither. Make no edits.

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
carries variables this project's guard recognizes as foreign. Below,
`PRJ` stands for the chosen prefix.

For checkout N (N = 2, 3, ...; the primary is checkout 1):

| Variable | Primary | Checkout N |
| --- | --- | --- |
| `PRJ_CHECKOUT_SUFFIX` | (empty) | `N` |
| `PRJ_CHECKOUT_INDEX` | `0` | `N - 1` |
| `PRJ_PORT_OFFSET` | `0` | `200 * (N - 1)` |
| `PRJ_CHECKOUT_ROOT` | the checkout's absolute path | the checkout's absolute path |

plus one derived variable per port and per Redis role, below. They are
exported from the checkout's `.envrc` ([direnv](https://direnv.net/)),
which is untracked. Every tracked file that reads one falls back to
today's literal value, so an unset variable means primary behavior.

## Mode: prepare (native services)

Work on a branch in the primary checkout, following the project's own
branch, commit, and pull request conventions. The deliverable is one
pull request whose every change is inert when the identity is unset.

### Step 1 -- Check whether it is already prepared

Search for `PRJ_CHECKOUT_SUFFIX` (any prefix: `_CHECKOUT_SUFFIX`) in
`config/` and for a `docs/parallel-checkouts.md`. If both are present
the project is prepared: say so, make no edits, and offer the add
mode. If only one is, report what is missing and treat the rest of
this mode as a completion pass.

### Step 2 -- Inventory what two copies would share

Read, don't guess. For each item record the file, the current literal,
and whether it is read in development, test, or production:

- **Database names** -- `config/database.yml` (and any second database
  file). Test and development names collide; production names are
  never touched.
- **Redis** -- every `ENV.fetch("REDIS_URL")`-style read and every
  literal `redis://` URL in `config/`, `app/`, and `lib/`. Note each
  **role** (jobs, Action Cable, cache, rate limiting, ...) and its
  default database number. Two roles that read the same variable with
  different default database numbers are two roles, not one.
- **Ports the app opens** -- the dev server (`PORT` in
  `config/puma.rb`, `Procfile.dev`, `bin/dev`), a pinned
  `Capybara.server_port`, webpack or Vite dev servers, anything else
  bound to a fixed port. A port chosen at random (Capybara's default,
  a WebDriver started by Selenium Manager) needs nothing.
- **Other shared servers** -- Elasticsearch or OpenSearch indexes,
  S3-compatible buckets in a local MinIO, a shared mail catcher. Each
  gets the same treatment as Redis: a per-checkout name or number
  inside the one server, defaulting to today's.

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

  If the test name already carries `ENV['TEST_ENV_NUMBER']` (parallel
  tests), keep it and put the checkout suffix before it.

- **Redis roles:** give each role its own variable, falling back to
  the variable it reads today, then to today's literal. Production
  sets only the old variable, so it resolves exactly as before.

  ```ruby
  url: ENV.fetch("PRJ_JOBS_REDIS_URL") { ENV.fetch("REDIS_URL") { "redis://localhost:6379/0" } }
  ```

  Never collapse two roles onto one per-checkout variable: a single
  `REDIS_URL` set per checkout would put jobs and Action Cable in one
  database. YAML files that read ERB (`config/cable.yml`) take the
  same nested fetch.

- **Ports:** where the app already reads a conventional variable
  (`PORT` for Puma), change nothing tracked -- the `.envrc` sets it.
  Where a port is a literal, read a prefixed variable instead:
  `Capybara.server_port = Integer(ENV.fetch("PRJ_CAPYBARA_PORT") { 3001 })`.
  If the literal already comes from an unprefixed variable, keep that
  variable name and let the `.envrc` set it.

- **The guard:** copy `templates/parallel_checkout_guard.rb` (in this
  skill's directory) to `config/initializers/parallel_checkout_guard.rb`,
  replacing `PRJ` with the prefix. It raises at boot in development
  and test when `PRJ_CHECKOUT_ROOT` is set and names a different
  directory than `Rails.root` -- the case of a shell that still
  carries one checkout's identity running another checkout's code,
  which would otherwise aim it at the first checkout's databases. It
  does nothing when the variable is unset, and nothing in production.

- **The doc:** write `docs/parallel-checkouts.md` from
  `templates/parallel-checkouts.md`, filling in the prefix, the
  variables and their defaults, the Redis roles, the `.envrc` block,
  and a registry table with the primary's row. Link it from the
  README's development section.

### Step 5 -- Verify, then ship

1. With the identity unset, run the project's full suite: it must
   pass exactly as on the default branch (defaults unchanged).
2. With a checkout-2 identity exported by hand in one shell, run
   `bin/rails runner 'puts ActiveRecord::Base.connection.current_database'`
   under `RAILS_ENV=test` after creating that database: it must print
   the suffixed name. This is a spot check; the real proof is running
   two suites at once after the add mode.
3. Open the pull request per the project's conventions. Its
   description says the change is inert until a checkout sets an
   identity, lists every default kept, and names the production
   configuration it does not touch.

## Mode: add checkout N

Run from the primary checkout. Pick N as the next number not in the
registry table and not already a directory on disk.

### Step 1 -- Clone

Clone from the primary's `origin` URL into a sibling directory named
`<primary-basename>N`:

```bash
git clone "$(git -C <primary> remote get-url origin)" <primary>N
```

Clone only `origin` (and `upstream` in a fork). Leave deploy remotes
(Heroku and the like) out: a second checkout is for development. When
the preparation has not merged yet, check out its branch in the new
clone; it is pushed, since its pull request is open.

### Step 2 -- Carry over what git does not

- **Excludes:** append each line of the primary's `.git/info/exclude`
  that the new clone's file lacks. Without this, files the primary
  hides (scratch directories, local tool-version files) show up as
  untracked in the new checkout, one `git add -A` from a commit.
- **Ignored configuration the app needs to boot:** list the primary's
  ignored files outside bulky directories --
  `git -C <primary> ls-files --others --ignored --exclude-standard`,
  skipping `tmp/`, `log/`, `node_modules/`, `coverage/`,
  `vendor/bundle/`, `public/assets/`, `public/packs*/`, `storage/`.
  Copy the ones the app reads (`config/master.key`,
  `config/credentials/*.key`, `.env`, a local tool-versions file),
  and show the user the list of what was copied. Never copy these
  anywhere but the new checkout.

### Step 3 -- Write the identity *(services)*

The new `.envrc` is the primary's `.envrc` with its identity block
replaced (or appended, when the primary has none yet). Never overwrite
an existing `.envrc` in the new checkout without merging: keep every
line outside the identity block. The block, for a project prefixed
`PRJ`:

```bash
# Parallel-checkout identity. See docs/parallel-checkouts.md.
export PRJ_CHECKOUT_SUFFIX=2
export PRJ_CHECKOUT_INDEX=1
export PRJ_PORT_OFFSET=$((200 * PRJ_CHECKOUT_INDEX))
export PRJ_CHECKOUT_ROOT="$PWD"
export PORT=$((3000 + PRJ_PORT_OFFSET))
export PRJ_CAPYBARA_PORT=$((3001 + PRJ_PORT_OFFSET))
export PRJ_JOBS_REDIS_URL="redis://localhost:6379/$((0 + 2 * PRJ_CHECKOUT_INDEX))"
export PRJ_CABLE_REDIS_URL="redis://localhost:6379/$((1 + 2 * PRJ_CHECKOUT_INDEX))"
```

The port and Redis lines come from the project's doc, which lists
exactly the variables that project reads. The Redis rule: each role
keeps its default database number and adds the checkout index times
the number of roles, so checkout blocks never overlap.

Then `direnv allow <checkout>`, and ask the user to run it themselves
if the harness refuses (allowing an `.envrc` is a trust decision).

### Step 4 -- Check the block fits *(services)*

- Every port in the block is free:
  `lsof -nP -iTCP:<port> -sTCP:LISTEN` prints nothing.
- The highest Redis database number is below the server's count:
  `redis-cli -p <port> CONFIG GET databases` (16 by default). If it
  does not fit, stop and say so: raising `databases` in the Redis
  config is the user's call, since it is shared by every project.

### Step 5 -- Databases and dependencies *(services)*

From inside the new checkout (so direnv loads its identity):

```bash
bundle install
bin/rails db:create db:schema:load
RAILS_ENV=test bin/rails db:create db:schema:load
```

For development data, offer to copy the primary's development
database rather than seed an empty one:
`createdb -T <app>_development <app>_development2` (it fails while the
source has open connections; stop the primary's dev server first), or
`pg_dump <app>_development | psql <app>_development2`.

### Step 6 -- Share Claude Code state with the primary

Two checkouts of one project should share what Claude Code has learned
about it, and nothing that belongs to one session:

- **Auto-memory.** Claude Code keeps per-project memory under
  `~/.claude/projects/<dir>/memory`, where `<dir>` is the checkout's
  absolute path with every `/` and `.` replaced by `-`. Create the new
  checkout's `<dir>` if needed and make its `memory` a relative symlink
  to the primary's.
- **The project's `.claude/` directory.** Link each **untracked**
  entry of the primary's `.claude/` into the new checkout, one by one,
  as relative symlinks. Tracked entries come from the clone; replacing
  one with a symlink shows as a type change in git, and an edit on a
  branch in the new checkout would land in the primary's working tree.
  An untracked directory that holds no tracked files is linked whole;
  a directory mixing both is walked, linking its untracked entries.
  List candidates with
  `git -C <primary> ls-files --others --directory -- .claude`.
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

### Step 7 -- Register and verify

1. Add the checkout's row to the registry table in
   `docs/parallel-checkouts.md` and commit it on its own branch per
   the project's conventions (it is the one tracked change add makes).
   Projects with no services have no doc and skip this.
2. Prove the isolation *(services)*: start the full suite in the
   primary and in the new checkout at the same moment. Both must pass,
   with identical example counts. A failure that appears only when
   the two overlap is a collision the inventory missed: find the
   shared resource, add it to the doc and the tracked config, and
   rerun.
3. Prove the guard *(services)*: run the new checkout's code under
   the primary's identity. `direnv exec` loads a directory's
   environment without changing directory, so
   `cd <new> && direnv exec <primary> bin/rails runner -e test 'puts 1'`
   must refuse with the guard's message, and the same command with
   `direnv exec <new>` must print `1`.

## Mode: remove checkout N

Destructive at every step; confirm the whole list with the user before
starting, and never remove the primary.

1. **Look before deleting.** In the checkout: `git status` must be
   clean, and every local branch must exist on `origin` at the same
   commit (`git branch -vv`, `git log --branches --not --remotes`
   prints nothing). Anything else stops the removal and goes back to
   the user.
2. **Stop its processes:** a dev server, a Sidekiq worker, anything
   bound to its ports.
3. *(services)* Drop its databases (`bin/rails db:drop` and
   `RAILS_ENV=test bin/rails db:drop`, run from inside it so its
   identity applies) and flush its Redis databases, one
   `redis-cli -n <db> FLUSHDB` per role number in its block. Name each
   database number before flushing; a wrong number empties another
   checkout's.
4. Remove its `~/.claude/projects/<dir>` directory. Its `memory` is a
   symlink, so the primary's memory is untouched; check that before
   deleting.
5. Delete the checkout directory.
6. Remove its registry row and commit that per the project's
   conventions.

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
- **Worktrees inside a checkout share its identity.** Two full suites
  from two worktrees of one checkout still collide. Run full suites
  one at a time per checkout.
