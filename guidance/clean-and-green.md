# Clean and Green

> **Precedence:** this file is a shared default. If anything here
> conflicts with the project's own CLAUDE.md, rules files, or a team
> agreement, the project wins.

Every project's normal status quo is for lint and tests to be
completely passing. Think "clean and green". Unless explicitly told
otherwise, assume every failure has to be fixed to get back to 100%
passing.

## Zero warnings, zero failures

- All linting tools must show zero offenses (rubocop, eslint, etc.).
- All tests must pass with zero failures.
- The project's full check task (rake, npm test, and kin) must
  complete successfully.
- Never commit code with warnings or failing tests.
- Never describe a warning or failure as "acceptable" -- not "the
  offenses are only in the test file", not "these failures are
  pre-existing". If you believe a warning is bogus, escalate to a
  human instead of unilaterally accepting it.
- If satisfying a lint rule would make the code worse, call that to
  the developer's attention instead of blindly applying the change.

## No suppression comments

Never silence a linter with a suppression comment: no
`rubocop:disable`, `eslint-disable`, `noqa`, `@ts-ignore`, or their
equivalents. Always fix the underlying cause. If fixing a violation
would cause more harm than good, discuss it with the developer first.
Quality standards exist for a reason; a proper solution beats a quick
workaround.

## Done means fully passing

A multi-file change is not finished until the project's full
lint-plus-test run passes entirely. If it genuinely cannot -- a
pre-existing failure, a flaky suite, a rule you believe is wrong --
stop and escalate to a human for an explicit decision. Accepting a red
suite is a call only a human gets to make.
