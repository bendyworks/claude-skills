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

*Where* the full suite runs is a per-project choice between the two
modes below. The invariant itself never moves: every failure is owned
and fixed before the work is done.

### Full Verification Mode (the default)

The full lint+test suite runs locally before work is called done. A
project that declares nothing is in this mode -- it is exactly the
behavior described above, now with a name.

### Targeted Spec Verification Mode (opt-in)

Some suites are too slow for the local edit-verify loop -- as a rough
guide, a full run over about seven minutes, though the threshold is
each team's call. Such a project may declare Targeted Spec
Verification Mode: local verification runs whole-project lint plus a
targeted subset of specs selected from the branch's diff (the
`targeted-specs` skill, bundled in the bendyworks plugin, owns the
selection), and CI runs the full suite on every push.

When a Full Verification Mode project's runs keep exceeding that
guide and its CI runs the full suite on every push, proactively
recommend this declaration to the team rather than waiting to be
asked.

To opt in, a project adds a declaration like this to its CLAUDE.md or
a rules file:

> This project uses Targeted Spec Verification Mode: local
> verification runs whole-project lint plus targeted specs (the
> targeted-specs skill); CI owns the full suite.

The mode lives in the project's checked-in rules -- never an
environment variable or a per-developer preference -- so every session
and every teammate verifies the same way.

What targeted mode does NOT change:

- **The definition of done.** CI's full-suite run is the full gate. A
  red full-suite CI run is owned exactly like a red local rake: the
  branch is not done until it is fixed, no matter how green the local
  targeted run was.
- **Lint.** Whole-project lint runs locally in both modes; only the
  spec set is targeted.
- **Escalation.** When a branch touches blast-radius files (shared
  test infrastructure, dependency manifests, schema), the
  targeted-specs skill escalates -- declaring that this branch needs
  the full suite locally, just as in Full Verification Mode.
