# Contributing

These skills are working tools, not polished products. They encode how we
actually work, they evolve as we learn, and rough edges are expected.
Improvements of any size are welcome -- a typo fix, a sharper trigger
description, a whole new audit lane in gauntlet.

## How changes ship

- All changes land through pull requests against `main`.
- **Merged means shipped.** The plugin has no version field, so every
  commit on `main` is immediately installable by everyone via
  `/plugin marketplace update bendyworks`. Review accordingly.
- Maintainer: Stephen Anderson (@bendycode) merges. If a PR sits for more
  than a few days, nudge him.

## Before you open a PR

1. Run the local checks CI will run:

   ```bash
   bash scripts/check-identifiers.sh
   claude plugin validate .
   ```

2. **No client or personal identifiers.** Use the neutral `ABC-NNN` form
   for tracker-ID examples, `teammate@example.com` for emails, and
   `${CLAUDE_PLUGIN_ROOT}` or relative paths instead of absolute
   home-directory paths. CI enforces the patterns; you are responsible
   for anything a pattern can't catch (a client's name in prose, a
   real-world anecdote that identifies a project).
3. **Test the skill you changed.** Invoke it through Claude Code against
   a real (or toy) project and confirm the changed behavior. For a new
   skill, run `claude --plugin-dir .` so the plugin loads from your
   working tree.
4. No trailing whitespace, no emdashes (use `--`).

## Writing a new skill

A skill is a folder under `skills/<name>/` with a `SKILL.md` and any
supporting files (scripts, templates). Start from this frontmatter:

```markdown
---
name: my-skill
description: One or two sentences saying what the skill does, then "Use
  when the user ..." with the concrete phrasings that should trigger it.
---

# My skill

Numbered, imperative instructions Claude can follow without you in the
room. Prefer bundled scripts over prose for anything mechanical.
```

The `description` is the API: it is all Claude sees when deciding whether
to invoke the skill, so spend your effort there. Name the trigger phrases
users actually say. Skills that reference each other should say "the
<name> skill (bundled in this plugin)" rather than a bare `/name`, so the
reference survives plugin namespacing.

Executables go in `bin/` (added to PATH when the plugin is enabled) and
must not require configuration beyond documented environment variables.

## Proposing without building

Open an issue with the "New skill proposal" template. A rough sketch of
the trigger phrases and the workflow is enough to start the conversation.
