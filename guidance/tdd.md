# Test-Driven Development by Default

> **Precedence:** this file is a shared default. If anything here
> conflicts with the project's own CLAUDE.md, rules files, or a team
> agreement, the project wins.

Implement changes test-first whenever the change is testable. The order
is non-negotiable: spec first, run it RED, then production code, then
run it GREEN. Every new spec must be observed failing on the pre-change
codebase before any production change makes it pass. If you have not
watched the spec be RED, you have not done TDD, no matter how confident
you are that the change is correct.

The cycle:

1. **Write the spec first.** Describe the desired behavior in a failing
   test before writing any production code. Phrase it in timeless
   terms, not as "the bug we're fixing".
2. **Run the spec and watch it fail.** A meaningful failure (wrong
   return value, missing method, wrong DOM state) confirms the spec
   exercises the intended code path. A spec that passes before the
   production change won't catch the regression later. This step
   happens BEFORE step 3, not retroactively.
3. **Write the production code.** The smallest change that makes the
   spec pass.
4. **Run the spec and watch it pass.**

If the production change and the spec both already exist and the spec
was never observed RED, verify retroactively. Both options below touch
working-tree state, so get the developer's explicit go-ahead first:

- stash or revert the production change, confirm the spec fails,
  restore the change, confirm it passes; or
- run the spec against the pre-change commit (main or HEAD~), confirm
  it fails there, then re-run on the branch and confirm it passes.

Specs that have never been observed RED are presumed broken until
proven otherwise. A common temptation to skip the retroactive check is
fixing findings from a code-review pass after the fact; it applies
there exactly as everywhere else.

Why watch-it-fail is non-negotiable: a spec that "looks right" and a
production change that "looks right" can each pass on their own merits
while quietly testing the wrong thing. The RED run proves the spec
depends on the production behavior, not on something incidental (a
setup callback, a default value, an unrelated migration). Skip it and
you can ship code that's untested in spirit, even when CI is green.

When TDD doesn't fit:

- Pure refactors with no behavior change (the existing specs are the
  safety net; green after the refactor means done).
- Spike or exploratory code intended to be thrown away.
- Trivial config or string-only changes.
- Documentation, comments, README updates.

Otherwise, default to test-first. If you find yourself writing
production code before the spec, stop and back up.
