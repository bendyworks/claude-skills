#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for the pure parse/render core of bin/gh-issue-sync.
#
# The bin file guards its CLI dispatch behind $PROGRAM_NAME == __FILE__,
# so loading it here exposes the GhIssueSync module without executing
# the CLI. Run: ruby test/gh_issue_sync_test.rb

require 'minitest/autorun'

load File.expand_path('../bin/gh-issue-sync', __dir__)

SLUG = 'abc-nnn-sample-plan'

def plan_with_todos(todos)
  <<~PLAN
    # abc-nnn-sample-plan

    ## Why

    A sample plan. This unchecked box is outside the to-dos section
    and must never trip the reconcile guard:

    - [ ] an acceptance criterion, not a to-do

    ## To-dos

    #{todos.chomp}

    ## Out of scope

    - Nothing here is a to-do either.
  PLAN
end

class ParsePlanTodosTest < Minitest::Test
  def test_parses_numbered_items_with_state_and_text
    plan = plan_with_todos(<<~TODOS)
      - [x] **1.** Ship the first thing
      - [ ] **2.** Ship the second thing
    TODOS
    items = GhIssueSync.parse_plan_todos(plan)
    assert_equal [1, 2], items.map { |i| i[:number] }
    assert_equal [true, false], items.map { |i| i[:checked] }
    assert_equal 'Ship the second thing', items[1][:text]
  end

  def test_joins_indented_continuation_lines_into_item_text
    plan = plan_with_todos(<<~TODOS)
      - [ ] **1.** A long item that wraps onto
        a continuation line
    TODOS
    items = GhIssueSync.parse_plan_todos(plan)
    assert_equal 'A long item that wraps onto a continuation line', items[0][:text]
  end

  def test_keeps_deferred_note_verbatim
    plan = plan_with_todos('- [x] **3.** Polish the docs (deferred to #99)')
    assert_equal 'Polish the docs (deferred to #99)', GhIssueSync.parse_plan_todos(plan)[0][:text]
  end

  def test_allows_gaps_in_numbering
    plan = plan_with_todos(<<~TODOS)
      - [x] **1.** First
      - [x] **5.** Fifth, after renumber-free deletions
    TODOS
    assert_equal [1, 5], GhIssueSync.parse_plan_todos(plan).map { |i| i[:number] }
  end

  def test_raises_on_near_miss_checkbox_inside_todos_section
    plan = plan_with_todos(<<~TODOS)
      - [x] **1.** Fine
      - [x] (deferred to #99) missing its bold number
    TODOS
    error = assert_raises(GhIssueSync::Error) { GhIssueSync.parse_plan_todos(plan) }
    assert_match(/missing its bold number/, error.message)
  end

  def test_ignores_unchecked_boxes_outside_the_todos_section
    plan = plan_with_todos('- [x] **1.** Only to-do')
    assert_equal 1, GhIssueSync.parse_plan_todos(plan).length
  end

  def test_raises_when_plan_has_no_todos_section
    error = assert_raises(GhIssueSync::Error) { GhIssueSync.parse_plan_todos("# plan\n\nNo list here.\n") }
    assert_match(/To-dos/, error.message)
  end

  def test_normalizes_crlf_plans
    plan = plan_with_todos('- [ ] **1.** Windows-edited item').gsub("\n", "\r\n")
    assert_equal 'Windows-edited item', GhIssueSync.parse_plan_todos(plan)[0][:text]
  end
end

class RenderSectionTest < Minitest::Test
  def test_wraps_heading_and_items_in_paired_markers
    items = [{ number: 1, checked: true, text: 'Done thing' },
             { number: 2, checked: false, text: 'Pending thing' }]
    expected = <<~SECTION.chomp
      <!-- gh-issue-sync: #{SLUG} -->
      ## To-dos
      - [x] **1.** Done thing
      - [ ] **2.** Pending thing
      <!-- /gh-issue-sync: #{SLUG} -->
    SECTION
    assert_equal expected, GhIssueSync.render_section(items, slug: SLUG)
  end

  def test_heading_suffix_names_the_plan_for_multi_plan_issues
    section = GhIssueSync.render_section([], slug: SLUG, heading_suffix: SLUG)
    assert_includes section, "## To-dos (#{SLUG})"
  end
end

class UpsertSectionTest < Minitest::Test
  def rendered(items = [{ number: 1, checked: false, text: 'One' }])
    GhIssueSync.render_section(items, slug: SLUG)
  end

  def test_appends_section_when_body_has_none
    body = "Issue intro.\n"
    result = GhIssueSync.upsert_section(body, rendered, slug: SLUG)
    assert_equal "Issue intro.\n\n#{rendered}\n", result
  end

  def test_replaces_existing_section_in_the_middle_of_the_body
    body = "Intro.\n\n#{rendered}\n\n## Later heading\n\nKeep me.\n"
    fresh = rendered([{ number: 1, checked: true, text: 'One' }])
    result = GhIssueSync.upsert_section(body, fresh, slug: SLUG)
    assert_includes result, '- [x] **1.** One'
    refute_includes result, '- [ ] **1.** One'
    assert_includes result, "## Later heading\n\nKeep me.\n"
  end

  def test_replacement_is_idempotent
    body = "Intro.\n\n#{rendered}\n"
    once = GhIssueSync.upsert_section(body, rendered, slug: SLUG)
    assert_equal once, GhIssueSync.upsert_section(once, rendered, slug: SLUG)
  end

  def test_adopts_a_pre_helper_marker_less_todos_heading
    body = <<~BODY
      Intro.

      ## To-dos
      - [ ] **1.** Written by the prose-era flow

      ## Later heading
    BODY
    result = GhIssueSync.upsert_section(body, rendered, slug: SLUG)
    assert_includes result, "<!-- gh-issue-sync: #{SLUG} -->"
    assert_equal 1, result.scan('## To-dos').length
    assert_includes result, '## Later heading'
  end

  def test_only_touches_the_section_matching_the_slug
    other = GhIssueSync.render_section([{ number: 1, checked: false, text: 'Other plan item' }],
                                       slug: 'abc-nnn-other-plan', heading_suffix: 'abc-nnn-other-plan')
    body = "Intro.\n\n#{other}\n\n#{rendered}\n"
    fresh = rendered([{ number: 1, checked: true, text: 'One' }])
    result = GhIssueSync.upsert_section(body, fresh, slug: SLUG)
    assert_includes result, 'Other plan item'
    assert_includes result, '- [x] **1.** One'
  end

  def test_normalizes_crlf_bodies_from_web_ui_edits
    body = "Intro.\r\n\r\n#{rendered.gsub("\n", "\r\n")}\r\n"
    result = GhIssueSync.upsert_section(body, rendered, slug: SLUG)
    refute_includes result, "\r"
    assert_equal 1, result.scan('## To-dos').length
  end
end

class DivergenceTest < Minitest::Test
  def test_warns_when_github_has_a_tick_the_plan_lacks
    body_items = [{ number: 1, checked: true, text: 'One' }]
    plan_items = [{ number: 1, checked: false, text: 'One' }]
    warnings = GhIssueSync.divergences(body_items, plan_items)
    assert_equal 1, warnings.length
    assert_match(/item 1.*plan wins/m, warnings[0])
  end

  def test_silent_when_plan_is_ahead_of_or_equal_to_github
    body_items = [{ number: 1, checked: false, text: 'One' }, { number: 2, checked: true, text: 'Two' }]
    plan_items = [{ number: 1, checked: true, text: 'One' }, { number: 2, checked: true, text: 'Two' }]
    assert_empty GhIssueSync.divergences(body_items, plan_items)
  end
end

class SectionItemsTest < Minitest::Test
  def test_reads_items_back_out_of_a_body_section
    section = GhIssueSync.render_section([{ number: 2, checked: true, text: 'Two' }], slug: SLUG)
    items = GhIssueSync.section_items("Intro.\n\n#{section}\n", slug: SLUG)
    assert_equal [{ number: 2, checked: true, text: 'Two' }], items
  end

  def test_returns_empty_for_a_body_without_the_section
    assert_empty GhIssueSync.section_items("Just an intro.\n", slug: SLUG)
  end
end

class AppendBodyTest < Minitest::Test
  def test_separates_addition_with_exactly_one_blank_line
    assert_equal "Body.\n\nMore.\n", GhIssueSync.append_body("Body.\n", "More.\n")
  end

  def test_handles_missing_trailing_newline_and_extra_blank_lines
    assert_equal "Body.\n\nMore.\n", GhIssueSync.append_body("Body.\n\n\n", 'More.')
    assert_equal "Body.\n\nMore.\n", GhIssueSync.append_body('Body.', 'More.')
  end

  def test_empty_body_gets_no_leading_blank_line
    assert_equal "More.\n", GhIssueSync.append_body('', "More.\n")
  end
end

class GuardsTest < Minitest::Test
  def test_reconcile_guard_lists_bare_unchecked_items_and_raises
    items = [{ number: 1, checked: true, text: 'Done' },
             { number: 2, checked: false, text: 'Forgotten' },
             { number: 3, checked: false, text: 'Also forgotten' }]
    error = assert_raises(GhIssueSync::Error) { GhIssueSync.assert_reconcilable!(items) }
    assert_match(/2/, error.message)
    assert_match(/3/, error.message)
  end

  def test_reconcile_guard_passes_when_every_item_is_checked
    GhIssueSync.assert_reconcilable!([{ number: 1, checked: true, text: 'Done (deferred to #99)' }])
  end

  def test_length_guard_raises_past_the_github_body_limit
    assert_raises(GhIssueSync::Error) { GhIssueSync.check_length!('a' * 65_537) }
    GhIssueSync.check_length!('a' * 65_536)
  end
end
