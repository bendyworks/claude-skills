<!-- parallel-checkouts template v1 (bendyworks/rules-that-bend). Replace every
<angle-bracket> placeholder and PRJ prefix, delete rows that do not apply,
and remove this comment. -->

# Parallel Checkouts

This repository can be cloned more than once on the same machine, with each
clone (a *checkout*) running its own dev server and its own full test suite
at the same time as the others. Each checkout is a full, permanent clone, not
a git worktree: git refuses to check out one branch in two worktrees, and two
worktrees of one checkout would share its test database anyway.

Nothing here is required. A checkout that sets none of the variables below
behaves exactly as before, on the same ports and databases.

## How it works

A checkout's identity is a handful of `PRJ_*` variables its untracked
`.envrc` ([direnv](https://direnv.net/)) exports. Everything two checkouts
would otherwise share reads them, falling back to the old value when unset:

| What | Where | Variable | Default |
| --- | --- | --- | --- |
| Development database | `config/database.yml` | `PRJ_CHECKOUT_SUFFIX` | `<app>_development` |
| Test database | `config/database.yml` | `PRJ_CHECKOUT_SUFFIX` | `<app>_test` |
| <Redis role> | `<file>` | `PRJ_<ROLE>_REDIS_URL`, then `REDIS_URL` | `redis://localhost:6379/<n>` |
| Dev server port | `config/puma.rb`, `Procfile.dev` | `PORT`, `PRJ_APP_PORT` | `3000` |
| <Pinned test server port> | `<file>` | `PRJ_CAPYBARA_PORT` | `<port>` |

Postgres and Redis stay one shared server each; a checkout is isolated
inside them by database name and Redis database number. Checkout N's number
for a Redis role is that role's default plus N - 1 times the stride, one more
than the highest default number among the roles development and test use
(<stride> here), so no two checkouts share a Redis database.

`config/initializers/00_parallel_checkout_guard.rb` refuses to boot
development or test when the shell's identity does not belong to the code
being run: when `PRJ_CHECKOUT_ROOT` names a different checkout (a shell still
carrying one checkout's identity), or when the checkout's marker names a
suffix the shell does not carry (a second checkout run with no identity
loaded). Either would point one checkout's code at another checkout's
databases. The marker is a file named `parallel-checkout` in the clone's git
directory, where `git clean` cannot reach it and every worktree of the clone
finds it. The original checkout has no marker and sets nothing, so it always
boots.

To run a command in a checkout from a shell that is not already in it, use
`direnv exec <checkout> <command>`, which loads that checkout's environment
without changing directory: `cd <checkout> && direnv exec . <command>`.

## The `.envrc` identity block

For checkout N (the original checkout is 1 and needs no block):

```bash
# Parallel-checkout identity. See docs/parallel-checkouts.md.
export PRJ_CHECKOUT_SUFFIX=<N>
export PRJ_CHECKOUT_INDEX=<N - 1>
export PRJ_PORT_OFFSET=$((200 * PRJ_CHECKOUT_INDEX))
export PRJ_CHECKOUT_ROOT="$PWD"
export PRJ_APP_PORT=$((3000 + PRJ_PORT_OFFSET))
export PORT=$PRJ_APP_PORT
<one line per remaining row of the table above>
```

## Adding a checkout

1. Clone into a sibling directory named `<directory>N` from `origin`, where
   `<directory>` is the original checkout's directory name.
2. Copy the ignored files the app needs to boot from the original checkout
   (`config/master.key`, `.env`, ...), and the lines of its
   `.git/info/exclude`.
3. Copy the original `.envrc`, add the identity block above, record the
   suffix in the git directory
   (`printf 'N\n' > "$(git rev-parse --path-format=absolute --git-common-dir)/parallel-checkout"`),
   and `direnv allow`.
4. Check the block is free: no listener on any of its ports
   (`lsof -nP -iTCP:<port> -sTCP:LISTEN`), and each of its Redis database
   numbers below the server's count and empty
   (`redis-cli -p <port> CONFIG GET databases`, `redis-cli -p <port> -n <db> DBSIZE`).
5. `direnv exec . bundle install`, then check that
   `config/initializers/00_parallel_checkout_guard.rb` exists and that both
   `direnv exec . bin/rails runner 'puts ActiveRecord::Base.connection_db_config.database'`
   and the same with `-e test` print suffixed names. Only then
   `direnv exec . bin/rails db:create db:schema:load` (development and test).
6. Start the full suite here and in another checkout at the same moment;
   both must pass with identical example counts.

## Caveats

- **One branch, one session.** Give each checkout's session its own branch;
  both on the default branch for verification is fine.
- **A branch older than this setup uses the original checkout's data**, since
  the suffix and the guard live in tracked files. Merge the default branch
  into a branch before checking it out in a second checkout.
- **Worktrees share their checkout's identity**, so two full suites run from
  two worktrees of one checkout still collide.
- **Machine-level singletons stay single:** a browser-automation session in
  your own browser, a staging deploy.
