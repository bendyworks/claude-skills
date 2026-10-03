# Ruby Style

> **Precedence:** this file is a shared default. If anything here
> conflicts with the project's own CLAUDE.md, rules files, or a team
> agreement, the project wins.

## Lay out a file top to bottom

**Write a class so it reads downward: the public interface first,
then one `private` keyword with every private method beneath it, and
each helper defined below the first method that calls it.** A reader
who meets a call can find the definition further down or skip it, and
never has to scroll up to learn what a method does or whether it is
private.

The order:

1. `include` and `extend`, constants, then macros (`attr_reader`,
   `delegate`, associations, validations).
2. Public class methods (`def self.build`).
3. `initialize`.
4. Public instance methods.
5. `protected` methods, when there are any.
6. One `private` keyword, then every private method.

- **A helper goes below the first method that calls it**, so private
  methods read in the order they are first needed. This applies inside
  the `private` section too. Two helpers that call each other keep
  whichever order reads better.
- **The `private` section is the only way to make a method private.**
  Never a trailing `private :name` line, which leaves the method among
  the public ones and states its visibility somewhere else, and never
  an inline `private def name`, which scatters private methods through
  the public interface. `private` followed by `attr_reader :name` is
  fine. A private class method goes in a `class << self` block with
  its own `private` section; `private` above `def self.name` does
  nothing, and `private_class_method :name` is the trailing form
  again. **A project whose own style declares private methods inline
  (`private def`), in its CLAUDE.md or its own `.rubocop.yml`, keeps
  that style: follow it, and do not convert its files.**
- **A method you add is private unless something outside the class
  calls it.** Framework entry points (a controller action, a job's
  `perform`, a policy's `update?`) are called from outside and stay
  public. Making an existing method private is a separate decision:
  its callers may be in views or other classes, or reach it through
  `public_send`, `respond_to?`, or ActiveSupport's `try`, which turns
  a call to a private method into a silent `nil`.
- Spec files are outside this rule; `let` and example groups follow
  RSpec's own order.

## Bring the whole file along

**When you change a Ruby file that is laid out differently, reorder
the whole file in a commit of its own that only moves code.** A file
half in the new order reads worse than either. The reorder commit:

- changes no method body, and every method keeps the visibility it
  had: moving a public method under `private` breaks its callers;
- keeps order-sensitive lines in order, such as an `alias_method`
  below the method it aliases;
- lets a reviewer skip the moves and read the real change on its own.

**Ask before reordering when the moves alone would carry the pull
request past the size the team reviews comfortably (400 changed lines,
where the team has no figure of its own), or when the change is a
hotfix or a revert.**

## Let RuboCop hold the line

**Two settings make a project's normal lint run catch most of this:**

```yaml
Layout/ClassStructure:
  Enabled: true

Style/AccessModifierDeclarations:
  AllowModifiersOnSymbols: false
```

`Layout/ClassStructure` is off by default; enabled, it flags a method
out of the order above, including a private method above public ones.
`AllowModifiersOnSymbols: false` flags a trailing `private :name`.
RuboCop's defaults already flag an inline `private def` and a
`private` above `def self.name`. Where the bundle includes RuboCop,
run each command below through `bundle exec`, so it uses the version
and plugins the project pins.

- `rubocop -A --only Layout/ClassStructure,Style/AccessModifierDeclarations <file>`
  does most of a reorder, on a file no to-do list excludes: a listed
  file reports no offenses and is left as it is. The correction is
  marked unsafe, so check the result, run
  `rubocop -a --only Layout <file>` to repair the spacing and
  indentation it leaves, and finish by hand what it can leave out of
  order: a `public` keyword that reopens the public section, a
  constant below the methods, and helper order.
- On an existing codebase, generate a to-do file that lists each
  offending file instead of switching the rule off:
  `rubocop --auto-gen-config --auto-gen-only-exclude --no-exclude-limit --no-auto-gen-enforced-style`.
  Without the last two flags, RuboCop disables `Layout/ClassStructure`
  once more than 15 files offend, and can rewrite
  `AccessModifierDeclarations` to allow the inline style. The command
  regenerates the whole `.rubocop_todo.yml` with those flags applied
  to every cop, so where one already exists, keep the two cops' new
  entries and review the rest of the diff; adding `--only` instead
  drops every other cop's entries. When you next change a listed
  file, remove it from the list, then reorder it as above.
- A to-do file that already sets `EnforcedStyle: inline` on
  `Style/AccessModifierDeclarations` makes lint fail the `private`
  section this file asks for. Regenerate with the command above, which
  replaces that entry with a list of the offending files.
- No cop checks that a helper sits below its caller or that a new
  method could be private, and none flags a
  `private_class_method :name`. Those stay yours to check.
