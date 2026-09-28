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
| Before the change: a preview of unshipped work, a tracker comment on planned work, a release announcement | "has been slow", "has put" | "will show", "will not change" |
| After the change: a commit, a pull request, release notes, a changelog, a message about shipped work | "before this change, it loaded" | "shows", "now shows" |

- **In a preview of unshipped work, every sentence, heading and caption
  about behavior the change touches takes "will" or "has been", and so
  does behavior that stays the same ("will not change", never "is
  unchanged" or "stays the same").** Present tense leaves the reader to
  decide whether a sentence describes what they have or what they will
  get. Put the old behavior in the present perfect ("the report has
  been slow"): "was slow" claims a fix nobody has yet, and "used to"
  says the old behavior is already gone.
- **In a commit or pull request, behavior the diff contains takes
  present tense, "now" included, and the behavior it replaced takes a
  label: "before this change, any user could open it".** "The query
  now requires both timestamps" places the fact after the change;
  "This will paginate the table" is false, since it already does, and
  a bare "any user can open it" reads as a hole still open. Keep
  "will" for what happens after the merge: the deploy, and a follow-up
  that has not shipped ("a follow-up will scope it", never "scopes it"
  or "is fixed in").
- **Anchor the side to the change, never to the calendar.** "Now",
  "before this change" and "previously" read the same a year later.
  "Today", "currently" and "at present" name the day of writing, which
  the reader of a merged pull request cannot recover: "every signed-in
  user can see every repository today" reads after the merge as a live
  hole. Bare "still" expires the same way; anchor it ("this pull request
  still leaves the contributor list unscoped"). For planned work, the
  tracker-comments guidance replaces "today" with an absolute date.
- A heading that already names the side ("What changed", "Not in this
  pull request") lets the sentences under it use plain present tense.

Before sending a preview of unshipped work, search it, headings and
captions included, for `now`, `still`, `unchanged`, `stays`,
`remains`, `used to`, `as before` and `today`. Each hit about behavior
the change touches needs a "will" or a "has been".
