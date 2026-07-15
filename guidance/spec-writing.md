---
paths: ["spec/**/*"]
---

# Spec-Writing Defaults

> **Precedence:** this file is a shared default. If anything here
> conflicts with the project's own CLAUDE.md, rules files, or a team
> agreement, the project wins.

Defaults for RSpec suites, applied at code-generation time so reviewers
don't have to ask twice.

## Syntax

- Use `is_expected.to ...` for one-liners; `should ...` is deprecated
  as of RSpec 3.
- Use `described_class` over the hard-coded class name.
- Use `be_<predicate>` matchers for `?` methods
  (`expect(user).to be_active`, never
  `expect(user.active?).to eq(true)`).
- Use `have_attributes(a: x, b: y)` whenever you'd otherwise write two
  or more `expect(obj.a).to eq(...)` lines on the same object.
- Use `expect { ... }.to change { ... }` / `not_to change` for behavior
  under an action; don't capture-then-compare manually.
- Use `be(n)` for numbers and other immediates; reserve `eq` for
  non-primitive equality.
- Declare `:aggregate_failures` at the tightest possible scope and only
  where needed: on the individual example that asserts multiple
  independent facts. Never blanket it on a top-level `describe`, and
  never add it to a file you are not otherwise changing. Two halves of
  one logical assertion don't need it.
- In Capybara specs, assert CSS class membership against
  `element[:class].split`, never the raw string. Substring matching
  ('unpaid-fee' contains 'paid-fee') makes negation assertions silently
  pass wrong.

## Doubles and stubs

- Default to `instance_double(Klass, method: value)`; reach for plain
  `double` only when there is no class to verify against.
- When you stub a method to drive behavior, also assert it was called:
  `expect(stub).to have_received(:method).with(specific_args)`. A spec
  that only checks the stubbed return value doesn't exercise the
  production code.
- Prefer real factory-built objects over `instance_double`, even for
  required arguments the code path doesn't read; use a double only when
  a real instance is genuinely expensive or impossible. Never pass
  `nil` to a required parameter just because the branch under test
  ignores it.

## Setup via factories, not literals

- Use `create(:thing, ...)`, not `Thing.create!(...)`, anywhere a
  factory exists. If one is missing, add it; a one-line factory pays
  for itself the next time the model gains a required column.
- Pass associations directly (`user: user`), never foreign-key IDs.
- Prefer real factory records over stubbing service objects when an
  integration path exists; stubbing a lookup hides whether the
  production query does what you think.
- Underscore-prefix `let!` bindings that exist only for their side
  effect and are never referenced in the example body
  (`let!(:_existing_fee) { create(:fee, ...) }`). Keep the named
  binding over an anonymous `before { create(...) }`: the name
  documents the record's role in the scenario, so a reader knows why
  the row exists without reverse-engineering the setup.

## Minimal base factories, traits for the rest

- A base factory sets only the minimally required attributes for a
  valid record (required `belongs_to` associations are part of that
  minimum) -- and no optional associations. Anything more rides along
  invisibly into every test that uses the factory, slowing the suite
  and surprising the test writer with records they never asked for.
  Treat factory defaults like permissions: give nothing unless it is
  needed.
- Everything beyond the minimum lives in traits (`:expired`,
  `:with_billing_plan`, ...), so each test declares exactly the state
  it needs.
- A softer suggestion for the calling side: let the factory call sing
  to the reader -- pass only the attributes the example actually
  cares about, so the call names what's being created and the state
  that matters. Traits usually serve both rules at once. When they
  pull apart, the minimal-base rule wins: never fatten a base factory
  just to shorten call sites, because unneeded records damage more
  than extra text in a spec file.

## Describe-block hygiene

- Don't wrap method describes in a "scopes" / "class methods" parent
  block; the `.method` / `#method` naming convention already conveys
  class-vs-instance.
- For repetitive specs across a known list, iterate
  (`CONSTANT.each do |x| describe "...#{x}..." do ... end end`) rather
  than stamping out copies by hand.

## Don't write specs that exercise no custom code

- A spec for a static list or hard-coded constant, a spec that only
  checks `respond_to`, or a spec that only verifies a vanilla
  `store_accessor` or plain column read tells you nothing real; delete
  it.
- A spec must drive a code path with at least one input. "It defines an
  enum" or "it includes the module" are framework tests, not behavior
  tests.
- When a coverage pass turns up dead production code, remove the dead
  code rather than write a spec to document it.

## Titles name behavior, not mechanism

Read the full nested string aloud (`describe` + `context` + `it`) as
one sentence; if it doesn't sound like something a person would say
about the behavior, rewrite it. Avoid:

- Vague verbs that restate the assertion ("does nothing", "works").
  Name the observable behavior instead.
- Implementation or framework mechanism in the title:
  `adds an access_token for the user`, not
  `adds a row to the user's access tokens`.
- Parenthetical clarifications; the parenthetical is usually the real
  title, so lead with it.
- Inconsistent sibling phrasing; parallel examples share sentence
  structure and name the same entity.
