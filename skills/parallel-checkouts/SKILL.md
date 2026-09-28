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

If the user asks for a new checkout of an unprepared project, run
**prepare** first, then **add** from the preparation branch; the add
mode does not wait for the preparation to merge (see Step 1 of add).

**Tell which kind of project this is before anything else:**

- **No local services.** Nothing in the project talks to a database,
  Redis, or a server port during its suite (a gem, a CLI, a repository
  of prose and scripts). There is nothing to isolate: skip prepare,
  and in add skip every step marked *services*.
- **Native services.** The app's Postgres and Redis run directly on
  the host (Homebrew, a system package), shared by every project on
  the machine. This is the path this skill covers. A SQLite database
  already lives inside each checkout's directory and needs no edit.
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
| `PRJ_CHECKOUT_ROOT` | (unset) | the checkout's absolute path |

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
  port moves by the same 200-per-checkout offset, so the pinned ports
  must all fall within 200 of the lowest one, or checkout N's app port
  lands on checkout M's other port (3000 and 4000 collide at checkout
  6). When they do not, say so and ask which to move.
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

*(services)* Append the identity block, replacing an existing one
rather than adding a second. For a project prefixed `PRJ`, with the
lines after `PORT` taken from the project's doc, which lists exactly
the variables that project reads:

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

*(services)* Then record the suffix where the guard looks for it, in
the new clone's git directory, where `git clean` cannot reach it and
every worktree of the clone finds it:
`printf '2\n' > "$(git -C <new> rev-parse --path-format=absolute --git-common-dir)/parallel-checkout"`.
The guard refuses to boot this checkout when its identity is not
loaded.

Then tell the user which variables the `.envrc` sets and which lines
changed (names only), and `direnv allow <new>`. Ask the user to run it
themselves if the harness refuses: allowing an `.envrc` is a trust
decision.

### Step 4 -- Check the block is free *(services)*

- Every port in the block is free:
  `lsof -nP -iTCP:<port> -sTCP:LISTEN` prints nothing.
- Every Redis database number in the block is below the server's count
  and empty: `redis-cli -p <port> CONFIG GET databases` (16 by
  default) and `redis-cli -p <port> -n <db> DBSIZE` (0) for each.
  Without `redis-cli`, the primary can ask the same, since its gems
  are installed:
  `cd <primary> && direnv exec . bin/rails runner 'r = Redis.new(url: "redis://localhost:<port>/<db>"); p r.config(:get, "databases"), r.dbsize'`. A non-empty database belongs to something else --
  another project on the same server -- so stop and say which. If the
  block passes the count, stop and say so too: raising `databases` in
  the Redis config is the user's call, since every project shares it.
  With no Redis server running at all, say so and move on.

### Step 5 -- Databases and dependencies *(services)*

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
2. Prove the guard *(services)*, matching the guard's own words rather
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
it: N is 2 or more; the checkout's `origin` URL matches the primary's;
its marker (`<git-common-dir>/parallel-checkout`) says N; and
`realpath <checkout>` is neither the primary's realpath nor inside it.
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
3. *(services)* Resolve its database names the way add Step 5 does
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
  `post-checkout` hook from add Step 5 warns when this happens.
- **Worktrees share their checkout's identity.** A worktree nested in
  a checkout picks up its `.envrc`; one created elsewhere needs
  `direnv exec <checkout>`. Two full suites from two worktrees of one
  checkout still collide, so run full suites one at a time per
  checkout.
