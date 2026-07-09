# Commit Message Style

> **Precedence:** this file is a shared default. If anything here
> conflicts with the project's own CLAUDE.md, rules files, or a team
> agreement, the project wins.

Treat the first line of a commit message as a **title**, not a
sentence. It answers WHY: the user-visible outcome or the reason the
change exists, in the most succinct, instantly understandable form.
It should be skim-readable in `git log --oneline`; aim for 60
characters or less. Quickly understandable beats grammatically
complete; some excellent titles are just two words.

## Titles

- Write for a teammate who knows the product but wasn't in the weeds
  of this change. Prefer the WHY / real-world outcome over the WHAT /
  code mechanism.
- Prefer Title Case noun phrases or a leading OUTCOME verb (`Limit`,
  `Prevent`, `Fix`, `Stop`, `Speed up`) over mechanism verbs (`Add`,
  `Update`, `Refactor`, `Move`). Mechanism verbs describe the edit;
  outcome verbs describe the point of it.
  - Strong: `Limit Public Marketplace Search to Intended Fields`
  - Weak: `Add ransackable_attributes allowlists to marketplace models`
- Don't stack library jargon or internal nouns in the title. If a
  technical term is genuinely needed, it goes in the body; the title
  stays plain.
- No file lists, mechanism dumps, or "and also fix X" tail clauses. If
  the title needs an "and", it should usually be two commits; if the
  change genuinely can't be split, the title still names the single
  user-facing outcome and the body explains the rest.
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

## Practices

- Prefer more, smaller, targeted commits over fewer, larger ones; each
  commit represents one logical change.
- Never amend or rewrite pushed commits without an explicit request.
