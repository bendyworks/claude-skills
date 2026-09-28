# Browser Checks

> **Precedence:** this file is a shared default. If anything here
> conflicts with the project's own CLAUDE.md, rules files, or a team
> agreement, the project wins.

A plan that names a browser check -- confirm the page renders, walk the
real user flow, check the deployed change in the app -- is closed only
by the session performing that check in a browser. When nothing is set
up for it, the session sets up what it can and asks for the rest. It
never substitutes other evidence and calls the check done.

## A signed-in browser is something to ask for

- Where browser tooling is available, never say an authenticated app
  is out of reach. A session cannot sign in to staging, production, or
  a third-party service itself, and should not try, but the developer
  can sign in within seconds, so ask.
- No tab handed over means nobody has asked yet, not that no browser
  session exists. An empty tab list starts the request; it does not
  end the check.
- A request spec, a script, or a signed-out visit that exercises the
  same code path is evidence to report beside the check, never in its
  place. The role is usually the point of the check: a page that loads
  for an admin, or a redirect to the sign-in screen, says nothing about
  what a signed-in regular user sees.

## Set the tab up, then ask

1. **Create the tab** rather than waiting for one to appear.
2. **Navigate it to the app's sign-in screen.** If the app redirects
   away or shows a signed-in user, the browser already holds a session.
   When that session is the role the check needs, skip the ask and run
   the check. When it is the wrong role, park the tab on a page that
   shows the sign-out control and ask the developer to sign out, then
   sign in as the role the check needs. Offer to click sign-out rather
   than doing it unasked: signing out ends the developer's session on
   every tab in that browser, and the control often sits behind a menu
   and a confirmation.
3. **Name the role in the ask:** "sign in as a non-admin so I can
   confirm the refusal", not "please log in". A tab signed in as the
   wrong role costs a second round trip.
4. **Point the developer at that tab by its title and URL.** Bring it to
   the front where the tooling can, and give its title and URL in every
   ask, whichever page it is parked on. A tab number means nothing to
   the developer, who should never hunt for the tab among other open
   ones.
5. **Wait for the signed-in tab, then run the check.** The ask is for a
   session the check can use, not for the developer to perform the check
   by hand. In an unattended run nobody can answer, so leave the tab set
   up and put the ask in the summary rather than waiting.

## Outstanding until it runs

**Until the check has run, the completion report says in so many words
that it is not done**, with what it needs, however much else passed, and
its box in the plan stays unticked. That holds for an unattended run's
summary, and for a session with no browser tooling at all. Only the
developer can drop the check, and a dropped check is reported as dropped
at their direction, never as passed.

## Scope

This covers staging, production, and third-party services. In a local
development environment a team may let sessions create their own test
users; the project's own rules govern there. Staging and production
hold separate data, so frame the check as a scenario ("a non-admin
opening the reports page"), never by production record IDs; the
environments guidance covers that.
