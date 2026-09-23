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

## Name the query on the model

**Move a query into a named scope on the model when it is built from
join keys or SQL rather than domain words, even when it has one
caller.** The shapes that trigger it, anywhere but the model: a
subquery on join keys (`where(id: other.select(:some_id))`), a join,
an `or` of conditions, or a SQL string fragment. The name earns its
place by making the call site read as the question it answers
("records shared with this user"), not by reuse.

**Leave a hash-condition `where` on the model's own columns where it
is, however many keys it has.** `where(owner: user, status: :draft)`
already reads as its question. A hash condition on a joined table
(`joins(:grants).where(grants: { user: user })`) is still a join.

- **Put the query with the data and the rule with the rule.** The
  model holds the relation; the policy, service, or job holds who
  gets it and when. The scope makes no authorization decision (an
  admin check stays in the policy), and the policy repeats none of
  the scope's SQL.
- **Reaching for a comment to explain what a query selects is the
  signal to name it.** Name it, then delete the comment. A comment
  that survives carries something a name cannot: a third-party quirk,
  a stakeholder constraint.
- **Keep a framework's documented call shape at the call site.**
  Pundit's `policy_scope(Record).find(params[:id])` stays, since
  `verify_policy_scoped` depends on it; what changes is that the
  query behind it has a name.
- Pick the form by what the query needs: a `scope` for a relation
  that answers one question; a class method when a branch could
  return `nil`, since a scope turns `nil` into `all` and widens the
  result; a query object or service when the query spans several
  models or many parameters, per the service-object rule above.

```ruby
# app/models/record.rb
scope :shared_with, ->(user) { where(id: user.access_grants.select(:record_id)) }

# app/policies/record_policy.rb
def resolve
  return scope.none unless user
  return scope.all if user.admin?

  scope.shared_with(user)
end
```

The subquery narrows whatever relation the scope is called on, which
is what a Pundit scope needs: returning a `has_many :through`
association such as `user.shared_records` from `resolve` would ignore
the `scope` the policy was handed, and a `joins(:access_grants)`
version would return a record once for each of the user's grants on
it.

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
