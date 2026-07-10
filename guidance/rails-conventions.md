# Rails Conventions

> **Precedence:** this file is a shared default. If anything here
> conflicts with the project's own CLAUDE.md, rules files, or a team
> agreement, the project wins.

## Use what Rails gives you

Follow Rails idioms rigorously. Use Rails built-in features
(counter_cache, enum, scopes, concerns) instead of reimplementing
functionality. Prefer ActiveRecord query methods over raw SQL. Follow
Rails conventions for file structure, naming (models singular,
controllers plural), and RESTful routes. Leverage helpers like
`delegate`, `alias_attribute`, and `has_secure_password`. Choose
service objects over fat models or controllers for complex business
logic. Use strong parameters, `respond_to` blocks, and Rails
validations. Question any manual implementation Rails might handle
better -- research the Rails-native solution before building custom
code.

Check method availability across contexts: view helpers like
`pluralize()` are not available in controllers -- use
`'word'.pluralize(count)` there instead.

## Database associations

Use standard Rails foreign keys (`user_id`, `project_id`) referencing
the `id` column, paired with standard `belongs_to` and `has_many`
associations. Never use non-standard keys like email or name fields
as relationship keys.

## Enums

- Use integer columns in the database for performance, but never
  reference the integer values in code.
- Define with `enum :status, { active: 0, archived: 1 },
  default: :active`.
- Always use symbols (`status: :active`) when setting or querying,
  plus the auto-generated query methods (`record.active?`), scopes
  (`Model.active`), and bang methods (`record.active!`).
- The enum hash (`Model.statuses[:active]`) is only for the rare case
  that genuinely needs the integer, such as raw SQL.
- These rules target production code. In a test that must drive an
  interface accepting only the raw integer (e.g. a numeric admin
  filter), derive the integer from the symbol via the enum hash
  (`Model.statuses[:active]`) rather than writing a bare literal; a
  bare integer literal is acceptable only when even the enum-hash
  form is not feasible. Never let the no-magic-integer rule block
  writing a test that pins real behavior.

## Avoid ActiveRecord callbacks in new code

Avoid ActiveRecord callbacks -- even in projects that already heavily
use them. Do not mimic existing callback-heavy patterns; the goal is
to remove them over time. Prefer explicit alternatives: override the
method, use a service object, or a dedicated method callers invoke.
Declarative options (`dependent:`, `accepts_nested_attributes_for`)
are fine. If a callback is genuinely the right tool (a hard invariant
that must cover every code path), call it out in the PR and say why
nothing else fits.
