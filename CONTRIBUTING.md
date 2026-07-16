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
- **Announce guidance changes.** A substantive change to a `guidance/`
  file changes how a consuming teammate's Claude behaves on their next
  `git pull` or vendoring refresh -- silently, if nobody tells them. The
  PR description for such a change must say what behavior changes and
  why, in wording a consuming team can relay to its own channel. Typo
  and formatting fixes are exempt.

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
   a real (or toy) project and confirm the changed behavior. The
   "Dry-running a skill" section below has the mechanics that make this
   cheap; for a new skill it is the whole test plan.
4. No trailing whitespace, no emdashes (use `--`).

## Dry-running a skill

The cheapest faithful test of a skill is a headless Claude session run
against a real project, with the plugin loaded from your working tree.
Three techniques cover most skills:

**Invocation.** Run from the target project's directory and point
`--plugin-dir` at your clone of this repo. Headless (`-p`) sessions
cannot answer permission prompts, so pre-approve the tools the skill
needs:

```bash
cd path/to/target-project
claude --plugin-dir path/to/claude-skills \
  -p "Invoke the <name> skill from the bendyworks plugin on the current
      branch, following it exactly. Report what it produces." \
  --allowedTools "Bash,Read,Grep,Glob"
```

Keep the prompt neutral -- do not tell the session what outcome you
expect, or the run stops being a test. Decide the expected answer
beforehand from your own reading of the project's state, then grade the
output against it.

**Trigger injection.** To force a specific code path (an escalation
rule, an edge case), plant an untracked dummy file that matches the
trigger instead of mutating anything real -- e.g.
`touch spec/factories/zz_dry_run.rb` to trip a rule keyed on
`spec/factories/**`. It exercises the genuine path end to end, risks
nothing in the target repo, and one `rm` reverts it. When the skill
claims to produce an artifact (a log file, a report), verify it exists
on disk.

**Selection-only paper runs.** For judgment-heavy rules that would be
slow or side-effectful to execute, prompt the session to apply the
skill's rules against real code but run nothing: stipulate a
hypothetical diff ("pretend the branch diff were exactly: ..."), tell it
to substitute real files when a stipulated one does not exist and say
so, and require the full decision output. This validates heuristics in
one pass without paying for their execution.

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
Err on the side of keeping them stdlib-only Ruby (no gems, no Gemfile)
so installers need nothing beyond a Ruby on their PATH. When a helper has logic worth
testing (see `bin/gh-issue-sync`), structure it as a pure module whose
functions raise a custom error, plus a thin CLI class that talks to the
outside world and rescues to `abort`, dispatched behind
`if $PROGRAM_NAME == __FILE__` -- the test file under `test/` can then
`load` the bin file without executing the CLI, and CI runs it with a
bare `ruby test/<name>_test.rb`.

## Proposing without building

Open an issue with the "New skill proposal" template. A rough sketch of
the trigger phrases and the workflow is enough to start the conversation.
