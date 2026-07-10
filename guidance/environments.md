# Staging and Production Are Separate Datasets

> **Precedence:** this file is a shared default. If anything here
> conflicts with the project's own CLAUDE.md, rules files, or a team
> agreement, the project wins.

Staging and production are NEVER the same database. Records that
exist in production -- specific IDs, user accounts, transactions,
edge-case data states -- do not exist in staging unless explicitly
created there. Treat them as wholly independent datasets at all
times, on every project, regardless of stack or deploy target.

Consequences:

- **Smoke-test plans** must work from whatever staging actually has,
  or set up the needed data deliberately on staging. They must never
  reference production record IDs as breadcrumbs.
- **Bug reproductions**: a production-reported bug cannot be
  reproduced on staging by looking up the same record IDs. Either
  describe the bug in shape ("an order with a refunded line item
  whose invoice has no payment attached") so a matching record can be
  found or created on staging, or reproduce locally with a controlled
  test setup.
- **Database queries** referencing specific records must be aimed at
  the right environment -- the staging console for staging records,
  the production console for production records. Never assume a
  record exists in both.
- **Reviewer and QA hand-offs** (PR descriptions, chat messages,
  smoke-test checklists) must not name production records the reader
  is expected to find on staging. Frame them in scenario shape.

The recurring trap: after debugging a production issue with specific
production IDs in hand, those IDs drift into staging-bound
instructions. Stop and re-frame in scenario terms before writing the
instructions.
