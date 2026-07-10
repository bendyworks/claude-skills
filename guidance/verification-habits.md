# Verification Habits

> **Precedence:** this file is a shared default. If anything here
> conflicts with the project's own CLAUDE.md, rules files, or a team
> agreement, the project wins.

Plausibility is not verification. An AI session produces fluent,
confident-sounding claims by default; these habits exist so that
confidence is earned empirically before it lands in code, comments,
or anything other people will read.

## Verify before asserting a fix is needed

Before asserting code is broken ("X was removed from library Y",
"call Z will fail") and editing to fix it, verify the claim
empirically: read the installed library source, run or compile the
code path, build the assets. Don't rely on general knowledge of a
library's version history. Confident-sounding "orphaned call site"
findings are often dead code or simply wrong.

## Never write unverified facts about people

Never write a person's name, title, or attribution into any
deliverable (README, CONTRIBUTING, commits, PR bodies, tracker
issues, drafted messages) without verifying it against an
authoritative source: `gh api users/<login>`, `git config user.name`,
git log authorship, the tracker's user record, or asking the
developer. If unverified, use the handle or an explicit placeholder
(`<Name>`) and say it needs filling in. A fluent, plausible-sounding
full name is exactly how a fabricated one slips through.

## Check schemas and signatures before use

- Before using a database column, verify it exists with the exact
  name and type expected -- read the schema, don't assume. Sibling
  names are the classic trap: `archived` vs `archived_at`,
  `message_id` vs an integration-specific ID column.
- Before calling a method, check whether it is a class method or an
  instance method, and verify its return value. Handle both success
  and failure cases.
