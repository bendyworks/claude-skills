<!-- parallel-checkouts template v1 (bendyworks/claude-skills). Replace every
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
inside them by database name and Redis database number. Each Redis role
keeps its default database number and adds the checkout index times the
number of roles (<number of roles> here), so checkout blocks never overlap.

`config/initializers/parallel_checkout_guard.rb` refuses to boot development
or test when the shell's identity does not belong to the code being run:
when `PRJ_CHECKOUT_ROOT` names a different directory (a shell still carrying
one checkout's identity), or when the checkout's untracked `.parallel-checkout`
file names a suffix the shell does not carry (a second checkout run with no
identity loaded). Either would point one checkout's code at another
checkout's databases. The original checkout has no `.parallel-checkout` file
and sets nothing, so it always boots.

From a shell outside a checkout, use `direnv exec <checkout> <command>`, which
loads that checkout's environment without changing directory, with absolute
paths.

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

1. Clone into a sibling directory named `<app>N` from `origin`.
2. Copy the ignored files the app needs to boot from the original checkout
   (`config/master.key`, `.env`, ...), and the lines of its
   `.git/info/exclude`.
3. Copy the original `.envrc`, add the identity block above, write the
   suffix to `.parallel-checkout` (`printf 'N\n' > .parallel-checkout`), add
   `.parallel-checkout` to `.git/info/exclude`, and `direnv allow`.
4. Check the block is free: no listener on any of its ports
   (`lsof -nP -iTCP:<port> -sTCP:LISTEN`), and its highest Redis database
   number below the server's count (`redis-cli CONFIG GET databases`).
5. `bundle install`, then `bin/rails db:create db:schema:load` for
   development and test.
6. Start the full suite here and in another checkout at the same moment;
   both must pass with identical example counts.

## Caveats

- **One branch, one session.** Give each checkout's session its own branch;
  both on the default branch for verification is fine.
- **Worktrees inside a checkout share its identity**, so two full suites run
  from two worktrees of one checkout still collide.
- **Machine-level singletons stay single:** a browser-automation session in
  your own browser, a staging deploy.
