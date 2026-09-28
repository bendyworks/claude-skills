# Browser Checks

> **Precedence:** this file is a shared default. If anything here
> conflicts with the project's own CLAUDE.md, rules files, or a team
> agreement, the project wins.

When a plan names a browser check -- confirm the page renders, walk the
real user flow, check the deployed change in the app -- and no signed-in
browser is ready for it, set up what can be set up and ask the developer
for the rest.

## A signed-in browser is something to ask for

- Where browser tooling is available, never say an authenticated app is
  out of reach. A session cannot sign in to staging, production, or a
  third-party service itself, and should not try, but the developer can
  sign in within seconds, so ask. No tab handed over means nobody has
  asked yet: an empty tab list starts the request, it does not end the
  check.
- A request spec, a script, or a signed-out visit that exercises the
  same code path is evidence to report beside the check, never in its
  place. The role is usually the point of the check: a page that loads
  for an admin, or a redirect to the sign-in screen, says nothing about
  what a signed-in regular user sees.

## Set the tab up, then ask

1. **Create the tab** rather than waiting for one to appear.
2. **Navigate it to the app's sign-in screen and judge by where it
   lands.** A login form, even one on another domain such as a single
   sign-on provider, means the browser holds no session: leave the tab
   there. A page showing a signed-in user (a name, an avatar, a sign-out
   control) means it does. When that session is the role the check needs
   and the check only reads, skip the ask and run it; a check that
   changes data confirms the account with the developer first, since the
   signed-in account is often the developer's own. When it is the wrong
   role, park the tab on a page that shows the sign-out control and ask
   the developer to sign out, then sign in as the role the check needs;
   with single sign-on, signing out of the app can leave the provider
   signed in as the same user. Offer to click sign-out rather than doing
   it unasked: signing out ends the developer's session on every tab in
   that browser, and the control often sits behind a menu and a
   confirmation.
3. **Name the role in the ask:** "sign in as a non-admin so I can
   confirm the refusal", not "please log in".
4. **Point the developer at that tab by its title and URL.** Bring it to
   the front where the tooling can, and give its title and URL in every
   ask, whichever page it is parked on, never only an ID the tooling
   assigned.
5. **Wait for the signed-in tab, then run the check.** The ask is for a
   session the check can use, not for the developer to perform the check
   by hand. In an unattended run nobody can answer, so leave the tab set
   up and put the ask in the summary rather than waiting.

## Outstanding until it runs

**Until the check has run and passed, the completion report says in so
many words that it is not done**, with what it needs, however much else
passed, and its box in the plan stays unticked. That holds for an
unattended run's summary, and for a session with no browser tooling at
all. Only the developer can drop the check, and a dropped check is
reported as dropped at their direction, never as passed. A run that
fails is reported as a failure to fix, not a closed check.

## Scope

This covers staging, production, and third-party services. In a local
development environment a team may let sessions create their own test
users; the project's own rules govern there. Frame the check as a
scenario ("a non-admin opening the reports page"), never by production
record IDs; the environments guidance covers why.
