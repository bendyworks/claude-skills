# claude-skills

This repo is the `bendyworks` Claude Code plugin marketplace: the skills,
guidance files, and CLIs other people install and run. Contributor mechanics
-- how changes ship, the checks to run before a PR, how to write and
dry-run a skill -- live in [CONTRIBUTING.md](CONTRIBUTING.md). Read it before
opening a PR; this file carries only what a session working here needs in
order to behave correctly.

## Deploy-on-Merge Mode

This project uses Deploy-on-Merge Mode: merging to the default branch is the
production deploy, with no later step that could still fail or be skipped.

The plugin carries no version field, so the merged commit is what installers
get. An installer running `/plugin marketplace update bendyworks` later is
adoption, not a deploy step that could fail, so nothing stands between a merge
and the change being live.

## Tracker

GitHub Issues is this repo's tracker of record. Plan files, branches, and PRs
are named after the issue they serve, in `NNN-title-slug` form.

## Everything here is public

This repo is public and its history is permanent. No client names, real
tracker IDs (use the neutral `ABC-NNN` form), personal email addresses, or
absolute home-directory paths -- in code, prose, commits, or PR descriptions.
CONTRIBUTING.md has the full rule and the checks that enforce the mechanical
half of it.

Skills and guidance stay installer-generic: they are read by people with no
access to our machines or our private notes, so they must not reference
personal skills, private CLAUDE.md files, or anything a reader outside
Bendyworks could not act on.
