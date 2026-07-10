# Tracker Comments Survive Plans Falling Through

> **Precedence:** this file is a shared default. If anything here
> conflicts with the project's own CLAUDE.md, rules files, or a team
> agreement, the project wins.

Comments on tracker issues (Linear, Jira, GitHub Issues, and kin) are
read later, by other people, with none of the current session's
context -- often after the plan that prompted the comment has slipped
or been abandoned. When a comment references a planned or in-flight
action:

- Never state a plan as present-tense fact ("the API token is being
  rotated today"). Name it as an intention with an owner and an
  absolute date: "Dana plans to rotate the API token on 2026-06-18."
- Never write instructions that are only correct if the plan
  happened. Phrase them so the reader verifies instead of assumes:
  "check the token's updated date in the password manager -- if
  there's been no rotation since 2026-06-18, the existing token is
  still the current one."
- Convert relative time ("today", "next week") to absolute dates;
  relative words are meaningless to a reader arriving weeks later.

The failure mode this prevents: a comment says a change "is happening
today", the plan slips, and weeks later a teammate follows the
comment's instructions hunting for something that never existed.
