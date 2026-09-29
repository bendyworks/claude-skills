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
  the code does and why, not what it used to do. A comment describing
  current behavior takes no side of a change: "now" and "previously"
  belong in the commit message or PR description.
- No "TODO: clean up after launch" comments without a tracker issue
  reference; if it needs cleaning, file the issue and reference it by
  ID and title (`TODO(ABC-123 Expire Stale Sessions): ...`), otherwise
  the TODO rots forever. The title is the one the issue had when the
  comment was written; a later rename does not call for editing it.

A comment that explains why the code is shaped a certain way (a
third-party quirk, a non-obvious data invariant, a stakeholder
constraint) is a great comment. A comment that narrates the
developer's recent debugging session is not. If a future reader has to
know what was happening in the author's head when they wrote it, the
comment is wrong.

Before writing a comment that explains *what* code does, try naming
it instead: a method, a variable, or a named query whose name says
it. Once the name carries the meaning, delete the comment; what
survives is the *why* a name cannot hold.

## Plain language

The same permanence test applies to the words themselves: write for
the future reader, not for insiders of the current moment.

- Never introduce an acronym unless every reader will instantly
  recognize it (HTTP, SQL, CSV are fine; "IAR" for
  InventoryAdjustmentReport is not). Spell domain terms out in code comments, commit messages, PR
  descriptions, and issues. This applies to what you author; quoted
  text may keep its author's acronyms.
- **Never refer to a tracker item (an issue, story, or epic) or a pull
  request by its ID alone, in a PR, an issue, a tracker comment, a
  plan, a message to a teammate, or chat: look up its title and put it
  beside the ID on first mention.** A reader who does not remember
  "ABC-123" or "#45" has to click through and back to learn what it
  is, while the writer almost always has the title in hand. In prose
  that reads "ABC-123 (Expire Stale Sessions)"; in a link the title
  goes in the link text, "[ABC-123 Expire Stale Sessions](...)" or
  "[#45 Retry Webhook Deliveries](...)", never "[ABC-123](...)" or
  "[PR #45](...)". First mention means the first in each message or
  document, a heading included; later mentions may use the bare ID.
  When a title already begins with its ID, write the ID once.
  - Look up every title with the tracker's command-line tool or `gh`,
    including for items the request already describes. A description
    is not a title, and neither is a URL slug or memory. If the lookup
    fails, never write anything presented as its title: name it in
    lowercase prose ("ABC-123, the session-expiry work") and say its
    title could not be checked.
  - Forms that tooling parses stay exactly as the tooling expects,
    with nothing inserted inside them: `Closes #45` (never
    `Closes [#45 ...](...)`), commit trailers (`Refs: ABC-123`),
    branch names, command arguments, and the `filed as #45` and
    `(deferred to #45)` notes a skill or script matches on. A title may follow a closing
    keyword's number, as in `Closes #45 (Retry Webhook Deliveries)`.
    The same follow-up mentioned in a comment or message to people
    still gets its title.
  - Commit messages are outside this rule: the `Refs:` trailer names
    the issue a commit serves, and cross-references to other issues
    belong in the PR description (see the commit-messages guidance).
- Prefer plain, concrete language over academic or testing-theory
  jargon. Say what the code or spec actually does ("pins the current
  report output") rather than naming the technique behind it.
- Before reaching for an analogy word (spelling, alias, flavor,
  clone), ask whether a developer describing the construct aloud
  would use it. `belongs_to :x` and `belongs_to :x, optional: false`
  are two declaration forms, not "two spellings". When in doubt,
  prefer the plain category noun: "form", "way to declare", "call
  shape".
- Never present a term coined during the working session as if it
  names something in the repo. "The optionality registry" for what
  the code calls `audited_required` reads like real machinery, but a
  future reader cannot grep for it. If the coined name is genuinely
  better, rename the thing in code first, in its own commit, then use
  the new name everywhere.
