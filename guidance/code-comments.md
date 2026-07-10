# Comments Speak to Permanent Intent

> **Precedence:** this file is a shared default. If anything here
> conflicts with the project's own CLAUDE.md, rules files, or a team
> agreement, the project wins.

Comments belong to the code as it lives in the repository, not to the
moment in which they were written. A comment should describe permanent
intent: business rules, hidden constraints, non-obvious invariants,
architectural reasons the code is shaped a particular way. A comment
should **not** describe the transient context of "what we are fixing
right now" or assume the reader knows what task or bug prompted it.

This means:

- No "we found this during ABC-123 QA" or "after PR #456..."
  references in code comments. That context belongs in commit messages
  and PR descriptions, where it has a permanent home and decays
  gracefully alongside the work.
- No "this test exists because of the recent bug where..." preambles.
  Test names and descriptions should describe the behavior under test
  in timeless terms.
- No "we just changed X, so this now has to..." comments. State what
  the code does and why, not what it used to do.
- No "TODO: clean up after launch" comments without a tracker issue
  reference; if it needs cleaning, file the issue and reference it,
  otherwise the TODO rots forever.

A comment that explains why the code is shaped a certain way (a
third-party quirk, a non-obvious data invariant, a stakeholder
constraint) is a great comment. A comment that narrates the
developer's recent debugging session is not. If a future reader has to
know what was happening in the author's head when they wrote it, the
comment is wrong.

## Plain language

The same permanence test applies to the words themselves: write for
the future reader, not for insiders of the current moment.

- Never introduce an acronym unless every reader will instantly
  recognize it (HTTP, SQL, CSV are fine; "IAR" for
  InventoryAdjustmentReport is not). Spell domain terms out in code comments, commit messages, PR
  descriptions, and issues. This applies to what you author; quoted
  text may keep its author's acronyms.
- Prefer plain, concrete language over academic or testing-theory
  jargon. Say what the code or spec actually does ("pins the current
  report output") rather than naming the technique behind it.
