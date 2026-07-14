# Commit Message Style

> **Precedence:** this file is a shared default. If anything here
> conflicts with the project's own CLAUDE.md, rules files, or a team
> agreement, the project wins.

Commit messages follow one shape, adapted from
[Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/):

```
type(scope): Title Case Outcome Description

Body: the WHAT and the HOW, in as many paragraphs as needed.

BREAKING CHANGE: what breaks, when something does
Refs: ABC-123
Co-authored-by: Name <email>
```

Treat the description -- the part after the prefix -- as a **title**,
not a sentence. It answers WHY: the user-visible outcome or the reason
the change exists, in the most succinct, instantly understandable form.
It should be skim-readable in `git log --oneline`. Quickly
understandable beats grammatically complete; some excellent
descriptions are just two words.

## The type(scope) prefix

- `type` names the mechanism category: `feat`, `fix`, `build`, `chore`,
  `ci`, `docs`, `style`, `refactor`, `perf`, or `test`.
- `scope` is optional: a short app-area noun in parentheses, e.g.
  `feat(marketplace):`. Keep scope names consistent within a project;
  drifting spellings (`marketplace` one week, `mktpl` the next) quietly
  erode the pattern's parseability.
- The prefix is the recommended default, not a hard requirement; a
  plain Title Case title is still acceptable. Be honest about the
  tradeoff, though: the structure's payoffs -- changelog generation,
  release automation, lint gates -- only accrue where a project carries
  the prefix on every commit. A team that wants that tooling should
  mandate the prefix in its own project rules.

## Descriptions

- Write for a teammate who knows the product but wasn't in the weeds
  of this change. Prefer the WHY / real-world outcome over the WHAT /
  code mechanism.
- Prefer Title Case noun phrases or a leading OUTCOME verb (`Limit`,
  `Prevent`, `Stop`, `Speed up`) over mechanism verbs (`Add`,
  `Update`, `Move`). The type already carries the mechanism category,
  which frees the description to carry the point of the change.
  - Strong: `feat(marketplace): Limit Public Search to Intended Fields`
  - Weak: `feat(marketplace): Add ransackable_attributes allowlists`
- Don't repeat the type as the description's leading verb.
  - Redundant: `fix(reports): Fix Broken CSV Export`
  - Better: `fix(reports): Broken CSV Export for Embedded Commas`

  The same logic makes `refactor` legitimate as a type even though it
  is a poor description verb: `refactor(billing): One Fee Calculation
  Path` says what the cleanup achieved; the prefix already says it was
  a refactor.
- Don't stack library jargon or internal nouns in the description. If
  a technical term is genuinely needed, it goes in the body; the
  description stays plain.
- No file lists, mechanism dumps, or "and also fix X" tail clauses. If
  the description needs an "and", it should usually be two commits; if
  the change genuinely can't be split, the description still names the
  single user-facing outcome and the body explains the rest.
- Keep the whole first line to roughly 72 characters. An unprefixed
  title keeps the old 60-character skim target; with a prefix, keep
  the description proportionally shorter. A description that can't fit
  is a smell that the scope is too long or the commit too big.
- Read it aloud before committing: if a teammate couldn't tell what
  changed and why it matters, rewrite it.

## Bodies

- After the blank line, cover the WHAT and the HOW: which files and
  mechanisms changed, the technical details, and any non-obvious
  tradeoffs. Multiple paragraphs are fine.
- Keep the body focused on the permanent record: motivation, mechanism,
  tradeoffs. Reviewer pointers ("start with file X", "the key test to
  scrutinize is Y") and out-of-scope notes ("filed as ABC-123",
  "deferred to the next PR") belong in the PR description instead.
  Commits live in `git log` forever and are read in many contexts;
  PR-scoped guidance decays badly when separated from its PR.
  The footer's `Refs:` names the one issue this commit serves;
  cross-references to any other issue stay at the PR level.

## Footers

Footers are git trailers -- `Token: value`, one per line, after a
blank line following the body:

- `Refs: <issue-id>` names the tracker issue the commit serves, in
  that tracker's native form: `Refs: ABC-123`, `Refs: SC-123`,
  `Refs: #123`. Use `Refs:`, never `Fixes`/`Closes` -- GitHub closes
  the referenced issue the moment a `Fixes`/`Closes` commit reaches
  the default branch, so reserve those for the rare commit where that
  is the intent.
- `BREAKING CHANGE: <description>` (uppercase, per the spec) marks a
  breaking change. The spec also offers a `!` shorthand
  (`feat(api)!:`), but prefer the explicit footer: with a bare `!` and
  no footer, the spec routes the breaking-change description into the
  first line, displacing the outcome phrase.
- `Co-authored-by: Name <email>` credits co-authors (GitHub's
  documented spelling of the trailer).

## Practices

- Prefer more, smaller, targeted commits over fewer, larger ones; each
  commit represents one logical change. A commit that seems to need
  two types is the same smell wearing a prefix: split it.
- Generated messages are exempt from this shape: merge commits,
  `git revert` defaults, and bot commits keep their tools' formats.
- Never amend or rewrite pushed commits without an explicit request.
