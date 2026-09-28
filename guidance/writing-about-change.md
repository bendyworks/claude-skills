# Writing About Change

> **Precedence:** this file is a shared default. If anything here
> conflicts with the project's own CLAUDE.md, rules files, or a team
> agreement, the project wins.

Prose about a change describes two states, before and after, and the
tense is what tells the reader which one a sentence means. It gets
written once the work is finished, when present tense feels natural and
every sentence is true from the author's seat, so the reader is left to
guess the side.

**Choose the tense from where the reader stands relative to the change,
and label the side of every sentence about behavior the change
touches.** A clause that defines a term ("a payment that covers several
loans") or describes the reader's own action ("the date range you
chose") needs no label.

| Where the reader stands | Old behavior | New behavior |
| --- | --- | --- |
| Before the change: a preview for the people who will receive it, an announcement of an upcoming release | "has been slow" | "will show", "will not change" |
| After the change: a commit, a pull request, release notes, a changelog, a message about shipped work | "before this change, it loaded" | "shows", "now shows" |

A tracker comment on planned work names an owner and an absolute date
instead of a bare "will"; the tracker-comments guidance covers it. A
document that mixes shipped and unshipped changes picks the tense
sentence by sentence.

- **In a preview of unshipped work, every sentence, heading and
  caption about behavior takes "will" or "has been", including behavior
  that stays the same ("will not change").** A preview is a message to
  the customers, stakeholders or users who will receive the change; a
  commit or pull request is never one, even while it is open. Present
  tense leaves that reader to decide whether a sentence describes what
  they have or what they will get, and "is unchanged", "stays the
  same", "remains" and "works as before" do the same for behavior the
  change leaves alone. Put the old behavior in the present perfect
  ("the report has been slow"): "was slow" claims a fix nobody has yet,
  and "used to" says the old behavior is already gone.
- **In a commit or pull request, merged or not, and in release notes,
  the code the change contains takes present tense, "now" included,
  and the behavior it replaced takes a label: "before this change, any
  user could open it".** The reader of a diff stands after the change:
  "the query now requires both timestamps" is right, and "this will
  paginate the table" is false, since it already does. Keep "will" for
  what happens at or after the merge: the deploy, a migration or
  backfill that runs then, anything live only after a later promotion,
  and a follow-up that has not shipped ("a follow-up will scope it",
  never "a follow-up scopes it").
- **Anchor the side to the change, never to a relative day.** In a
  commit or pull request, "now", "before this change" and "previously"
  read the same a year later. Elsewhere, name the change or give an
  absolute date ("before #123 merged", "before the 2026-09-12
  deploy"). "Today", "currently" and "at present" name the day of
  writing, which the reader of an undated artifact cannot recover:
  "every signed-in user can see every repository today" reads after
  the merge as a live hole. Bare "still" expires the same way; anchor
  it ("this pull request still leaves the contributor list
  unscoped").
- After the change, a heading that already names the side ("What
  changed", "Not in this pull request") lets the sentences under it
  drop "now" and "before this change".

Before sending a preview of unshipped work, search it, headings and
captions included, for `now`, `still`, `unchanged`, `stays`,
`remains`, `used to`, `as before`, `today`, `currently` and `at
present`. Each hit about behavior, changed or not, needs a "will" or a
"has been". Then reread every present-tense verb about behavior; a
plain "the report shows 100 rows" carries no marker word.
