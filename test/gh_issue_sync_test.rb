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
      - [x] **1.** Ship the first thing (deferred to #99)
      - [ ] **2.** Ship the second thing
    TODOS
    items = GhIssueSync.parse_plan_todos(plan)
    assert_equal [1, 2], items.map { |i| i[:number] }
    assert_equal [true, false], items.map { |i| i[:checked] }
    assert_equal 'Ship the first thing (deferred to #99)', items[0][:text]
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

  def test_raises_on_indented_nested_checkboxes
    plan = plan_with_todos(<<~TODOS)
      - [ ] **1.** Parent item
        - [x] **9.** nested but strict-shaped
    TODOS
    assert_raises(GhIssueSync::Error) { GhIssueSync.parse_plan_todos(plan) }

    plan = plan_with_todos(<<~TODOS)
      - [ ] **1.** Parent item
        - [ ] plain nested sub-step
    TODOS
    assert_raises(GhIssueSync::Error) { GhIssueSync.parse_plan_todos(plan) }
  end

  def test_ignores_unchecked_boxes_outside_the_todos_section
    plan = plan_with_todos('- [x] **1.** Only to-do')
    assert_equal 1, GhIssueSync.parse_plan_todos(plan).length
  end

  def test_ignores_markdown_link_bullets_in_the_todos_section
    plan = plan_with_todos(<<~TODOS)
      - [ ] **1.** Real item
      - [see the RFC](https://example.com/rfc) for background
    TODOS
    items = GhIssueSync.parse_plan_todos(plan)
    assert_equal [1], items.map { |i| i[:number] }
  end

  def test_ignores_a_fenced_todos_heading_before_the_real_section
    plan = <<~PLAN
      # abc-nnn-sample-plan

      ## Format example

      ```
      ## To-dos
      - [ ] **7.** fenced example, not real
      ```

      ## To-dos

      - [x] **1.** The real item
    PLAN
    items = GhIssueSync.parse_plan_todos(plan)
    assert_equal [1], items.map { |i| i[:number] }
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

  def test_renders_backslash_sequences_in_item_text_literally
    body = "Intro.\n\n#{rendered}\n"
    tricky = rendered([{ number: 1, checked: false, text: 'Support \\& and \\1 and \\\\ escapes' }])
    result = GhIssueSync.upsert_section(body, tricky, slug: SLUG)
    assert_includes result, 'Support \\& and \\1 and \\\\ escapes'
    assert_equal 1, result.scan("<!-- /gh-issue-sync: #{SLUG} -->").length
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

  def test_never_adopts_another_plans_marker_wrapped_section
    other_slug = 'abc-nnn-other-plan'
    other = GhIssueSync.render_section([{ number: 1, checked: false, text: 'Other plan item' }],
                                       slug: other_slug, heading_suffix: other_slug)
    body = "Intro.\n\n#{other}\n"
    result = GhIssueSync.upsert_section(body, rendered, slug: SLUG)
    assert_includes result, 'Other plan item'
    assert_equal 1, result.scan("<!-- gh-issue-sync: #{other_slug} -->").length
    assert_equal 1, result.scan("<!-- /gh-issue-sync: #{other_slug} -->").length
    assert_includes result, "<!-- gh-issue-sync: #{SLUG} -->"
    assert_includes result, "<!-- /gh-issue-sync: #{SLUG} -->"
  end

  def test_adoption_stops_before_a_neighboring_marker_section
    other_slug = 'abc-nnn-other-plan'
    other = GhIssueSync.render_section([{ number: 1, checked: false, text: 'Other item' }],
                                       slug: other_slug, heading_suffix: other_slug)
    body = <<~BODY
      Intro.

      ## To-dos
      - [ ] **1.** pre-helper item

      #{other}
    BODY
    result = GhIssueSync.upsert_section(body, rendered, slug: SLUG)
    assert_equal 1, result.scan("<!-- gh-issue-sync: #{other_slug} -->").length
    assert_equal 1, result.scan("<!-- /gh-issue-sync: #{other_slug} -->").length
    assert_includes result, 'Other item'
    assert_includes result, "<!-- gh-issue-sync: #{SLUG} -->"
    refute_includes result, 'pre-helper item'
  end

  def test_stays_idempotent_when_item_text_mentions_a_marker
    tricky = rendered([{ number: 1, checked: false,
                         text: "documents the <!-- /gh-issue-sync: #{SLUG} --> close marker" }])
    body = "Intro.\n\n#{tricky}\n"
    once = GhIssueSync.upsert_section(body, tricky, slug: SLUG)
    assert_equal once, GhIssueSync.upsert_section(once, tricky, slug: SLUG)
    assert_equal 1, once.scan(/^<!-- \/gh-issue-sync: #{SLUG} -->$/).length
  end

  def test_never_adopts_a_todos_heading_inside_a_code_fence
    body = <<~BODY
      Intro documenting the format:

      ```
      ## To-dos
      - [ ] **1.** fenced example
      ```

      Tail prose.
    BODY
    result = GhIssueSync.upsert_section(body, rendered, slug: SLUG)
    assert_includes result, "```\n## To-dos\n- [ ] **1.** fenced example\n```"
    assert_includes result, "Tail prose.\n\n#{rendered}\n"
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
  def test_reports_a_tick_the_plan_lacks
    body_items = [{ number: 1, checked: true, text: 'One' }]
    plan_items = [{ number: 1, checked: false, text: 'One' }]
    divs = GhIssueSync.divergences(body_items, plan_items)
    assert_equal 1, divs.length
    assert_match(/item 1.*ticked on GitHub/, divs[0])
  end

  def test_reports_a_body_item_absent_from_the_plan
    body_items = [{ number: 15, checked: true, text: 'hotfix landed' }]
    plan_items = [{ number: 1, checked: true, text: 'One' }]
    divs = GhIssueSync.divergences(body_items, plan_items)
    assert_equal 1, divs.length
    assert_match(/item 15.*only on GitHub/, divs[0])
  end

  def test_reports_a_text_edit_made_on_github
    body_items = [{ number: 2, checked: false, text: 'Migrate (NOT before the 15th)' }]
    plan_items = [{ number: 2, checked: false, text: 'Migrate' }]
    divs = GhIssueSync.divergences(body_items, plan_items)
    assert_equal 1, divs.length
    assert_match(/item 2.*text differs/, divs[0])
  end

  def test_silent_when_plan_is_ahead_of_or_equal_to_github
    body_items = [{ number: 1, checked: false, text: 'One' }, { number: 2, checked: true, text: 'Two' }]
    plan_items = [{ number: 1, checked: true, text: 'One' }, { number: 2, checked: true, text: 'Two' }]
    assert_empty GhIssueSync.divergences(body_items, plan_items)
  end
end

class SyncSectionTest < Minitest::Test
  def test_returns_regenerated_body_and_no_warnings_when_clean
    items = [{ number: 1, checked: true, text: 'One' }]
    body = "Intro.\n\n#{GhIssueSync.render_section([{ number: 1, checked: false, text: 'One' }], slug: SLUG)}\n"
    new_body, warnings = GhIssueSync.sync_section(body, items, slug: SLUG)
    assert_includes new_body, '- [x] **1.** One'
    assert_empty warnings
  end

  def test_returns_one_consolidated_warning_for_all_divergences
    items = [{ number: 1, checked: false, text: 'One' }, { number: 2, checked: false, text: 'Two' }]
    stale = [{ number: 1, checked: true, text: 'One' }, { number: 2, checked: true, text: 'Two' }]
    body = "Intro.\n\n#{GhIssueSync.render_section(stale, slug: SLUG)}\n"
    new_body, warnings = GhIssueSync.sync_section(body, items, slug: SLUG)
    assert_includes new_body, '- [ ] **1.** One'
    assert_equal 1, warnings.length
    assert_match(/item 1.*item 2.*plan file wins/m, warnings[0])
  end

  def test_warns_about_state_in_an_adopted_pre_helper_section
    body = <<~BODY
      Intro.

      ## To-dos
      - [x] **1.** hand-ticked before the helper existed
    BODY
    items = [{ number: 1, checked: false, text: 'hand-ticked before the helper existed' }]
    new_body, warnings = GhIssueSync.sync_section(body, items, slug: SLUG)
    assert_includes new_body, "<!-- gh-issue-sync: #{SLUG} -->"
    assert_equal 1, warnings.length
    assert_match(/item 1.*ticked on GitHub/, warnings[0])
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

  def test_preserves_first_line_indentation_of_the_addition
    assert_equal "Body.\n\n    code line\nprose\n",
                 GhIssueSync.append_body("Body.\n", "    code line\nprose\n")
    assert_equal "Body.\n\n    code line\n",
                 GhIssueSync.append_body("Body.\n", "\n\n    code line\n")
  end

  def test_empty_body_gets_no_leading_blank_line
    assert_equal "More.\n", GhIssueSync.append_body('', "More.\n")
  end
end

class RenderContentSectionTest < Minitest::Test
  def test_wraps_file_content_verbatim_in_paired_markers
    content = "## User story\n\nAs a developer, I want repeatable writes.\n"
    expected = <<~SECTION.chomp
      <!-- gh-issue-sync: user-story -->
      ## User story

      As a developer, I want repeatable writes.
      <!-- /gh-issue-sync: user-story -->
    SECTION
    assert_equal expected, GhIssueSync.render_content_section(content, slug: 'user-story')
  end

  def test_close_marker_gets_its_own_line_when_content_lacks_a_trailing_newline
    section = GhIssueSync.render_content_section('One line, no newline', slug: 'user-story')
    assert_includes section, "One line, no newline\n<!-- /gh-issue-sync: user-story -->"
  end

  def test_normalizes_crlf_content
    section = GhIssueSync.render_content_section("## Story\r\n\r\nWindows text.\r\n", slug: 'user-story')
    refute_includes section, "\r"
  end

  def test_preserves_first_line_indentation
    section = GhIssueSync.render_content_section("    code line\nprose\n", slug: 'user-story')
    assert_includes section, "-->\n    code line\nprose\n<!--"
  end
end

class UpsertContentSectionTest < Minitest::Test
  STORY = "## User story\n\nRepeatable writes.\n"

  def upsert(body, content = STORY, slug: 'user-story')
    GhIssueSync.upsert_content_section(body, content, slug: slug)
  end

  def test_creates_the_section_at_the_end_with_one_blank_line
    rendered = GhIssueSync.render_content_section(STORY, slug: 'user-story')
    new_body, outcome = upsert("Issue intro.\n")
    assert_equal "Issue intro.\n\n#{rendered}\n", new_body
    assert_equal :created, outcome
  end

  def test_replaces_the_section_in_place_leaving_the_rest_untouched
    checklist = GhIssueSync.render_section([{ number: 1, checked: false, text: 'One' }], slug: SLUG)
    story = GhIssueSync.render_content_section(STORY, slug: 'user-story')
    body = "Intro.\n\n#{story}\n\n#{checklist}\n\nTail prose.\n"
    new_body, outcome = upsert(body, "## User story\n\nEdited story.\n")
    assert_equal :replaced, outcome
    assert_includes new_body, 'Edited story.'
    refute_includes new_body, 'Repeatable writes.'
    assert_includes new_body, checklist
    assert_includes new_body, "Intro.\n"
    assert_includes new_body, "Tail prose.\n"
  end

  def test_rerunning_with_the_same_content_is_byte_identical_and_reports_unchanged
    once, = upsert("Intro.\n")
    twice, outcome = upsert(once)
    assert_equal once, twice
    assert_equal :unchanged, outcome
  end

  def test_never_adopts_a_marker_less_todos_heading
    body = <<~BODY
      Intro.

      ## To-dos
      - [ ] **1.** pre-helper checklist item
    BODY
    new_body, outcome = upsert(body)
    assert_equal :created, outcome
    assert_includes new_body, "## To-dos\n- [ ] **1.** pre-helper checklist item"
    assert_operator new_body.index('pre-helper checklist item'), :<,
                    new_body.index('<!-- gh-issue-sync: user-story -->')
  end

  def test_refuses_to_overwrite_a_checklist_section_with_content
    checklist = GhIssueSync.render_section([{ number: 1, checked: false, text: 'One' }], slug: SLUG)
    body = "Intro.\n\n#{checklist}\n"
    error = assert_raises(GhIssueSync::Error) { upsert(body, STORY, slug: SLUG) }
    assert_match(/checklist/, error.message)
  end

  def test_rejects_content_containing_an_open_marker_line_for_any_slug
    content = "Story.\n<!-- gh-issue-sync: unrelated-slug -->\nMore.\n"
    error = assert_raises(GhIssueSync::Error) { upsert("Intro.\n", content) }
    assert_match(/marker/, error.message)
  end

  def test_rejects_content_containing_a_close_marker_line_for_any_slug
    content = "Story.\n<!-- /gh-issue-sync: unrelated-slug -->\n"
    assert_raises(GhIssueSync::Error) { upsert("Intro.\n", content) }
  end

  def test_rejects_marker_lines_even_inside_code_fences
    content = "Example:\n\n```\n<!-- gh-issue-sync: demo -->\n```\n"
    error = assert_raises(GhIssueSync::Error) { upsert("Intro.\n", content) }
    assert_match(/marker/, error.message)
  end

  def test_rejects_marker_lines_hidden_behind_crlf
    content = "Story.\r\n<!-- gh-issue-sync: demo -->\r\n"
    assert_raises(GhIssueSync::Error) { upsert("Intro.\n", content) }
  end

  def test_rejects_marker_lines_hidden_behind_lone_cr
    content = "Story.\r<!-- gh-issue-sync: demo -->\r"
    assert_raises(GhIssueSync::Error) { upsert("Intro.\n", content) }
  end

  def test_allows_mid_line_marker_mentions
    content = "Discusses the <!-- gh-issue-sync: demo --> marker format mid-line.\n"
    new_body, outcome = upsert("Intro.\n", content)
    assert_equal :created, outcome
    rerun, second_outcome = GhIssueSync.upsert_content_section(new_body, content, slug: 'user-story')
    assert_equal :unchanged, second_outcome
    assert_equal new_body, rerun
  end

  def test_rejects_empty_or_blank_content
    assert_raises(GhIssueSync::Error) { upsert("Intro.\n", '') }
    assert_raises(GhIssueSync::Error) { upsert("Intro.\n", "  \n\n") }
  end

  def test_rejects_content_opening_with_a_todos_heading
    error = assert_raises(GhIssueSync::Error) { upsert("Intro.\n", "## To-dos\nquoted example\n") }
    assert_match(/To-dos/, error.message)
  end

  def test_rejects_a_todos_heading_behind_leading_blank_lines
    assert_raises(GhIssueSync::Error) { upsert("Intro.\n", "\n\n## To-dos and scope\nbody\n") }
  end

  def test_treats_a_checklist_with_a_stray_blank_line_after_its_marker_as_a_checklist
    checklist = GhIssueSync.render_section([{ number: 1, checked: false, text: 'One' }], slug: SLUG)
    body = "Intro.\n\n#{checklist.sub("-->\n## To-dos", "-->\n\n## To-dos")}\n"
    error = assert_raises(GhIssueSync::Error) { upsert(body, STORY, slug: SLUG) }
    assert_match(/is a checklist section/, error.message)
  end

  def test_rejects_slugs_outside_the_tight_charset
    assert_raises(GhIssueSync::Error) { upsert("Intro.\n", STORY, slug: 'x-->') }
  end

  def test_refuses_a_body_with_an_unpaired_open_marker_for_the_slug
    body = "Intro.\n\n<!-- gh-issue-sync: user-story -->\nOld story\nUnrelated prose.\n"
    error = assert_raises(GhIssueSync::Error) { upsert(body) }
    assert_match(/unpaired/, error.message)
  end

  def test_refuses_a_body_with_an_orphan_close_marker_for_the_slug
    body = "Intro.\n\nOld tail.\n<!-- /gh-issue-sync: user-story -->\n"
    assert_raises(GhIssueSync::Error) { upsert(body) }
  end

  def test_normalizes_crlf_bodies
    new_body, = upsert("Intro.\r\n")
    refute_includes new_body, "\r"
  end
end

class ChecklistCoexistenceTest < Minitest::Test
  def test_checklist_sync_refuses_to_overwrite_a_content_section_sharing_its_slug
    content = GhIssueSync.render_content_section("## Notes\n\nNot a checklist.\n", slug: SLUG)
    body = "Intro.\n\n#{content}\n"
    items = [{ number: 1, checked: false, text: 'One' }]
    error = assert_raises(GhIssueSync::Error) { GhIssueSync.sync_section(body, items, slug: SLUG) }
    assert_match(/checklist/, error.message)
  end

  def test_checklist_sync_repairs_a_stray_blank_line_after_its_own_marker
    checklist = GhIssueSync.render_section([{ number: 1, checked: false, text: 'One' }], slug: SLUG)
    body = "Intro.\n\n#{checklist.sub("-->\n## To-dos", "-->\n\n## To-dos")}\n"
    new_body, _warnings = GhIssueSync.sync_section(body, [{ number: 1, checked: true, text: 'One' }], slug: SLUG)
    assert_includes new_body, '- [x] **1.** One'
    refute_includes new_body, "-->\n\n## To-dos"
  end

  def test_checklist_sync_refuses_a_body_with_an_unpaired_marker_for_its_slug
    body = "Intro.\n\n<!-- gh-issue-sync: #{SLUG} -->\n- [ ] **1.** One\n"
    items = [{ number: 1, checked: false, text: 'One' }]
    error = assert_raises(GhIssueSync::Error) { GhIssueSync.sync_section(body, items, slug: SLUG) }
    assert_match(/unpaired/, error.message)
  end

  def test_checklist_adoption_ignores_todo_shaped_lines_inside_content_sections
    tricky = GhIssueSync.render_content_section(
      "## To-dos\n- [ ] **1.** quoted example, not a real to-do\n", slug: 'user-story'
    )
    body = "Intro.\n\n#{tricky}\n"
    items = [{ number: 2, checked: true, text: 'Real item' }]
    new_body, warnings = GhIssueSync.sync_section(body, items, slug: SLUG)
    assert_includes new_body, tricky
    assert_includes new_body, '- [x] **2.** Real item'
    assert_empty warnings
  end
end

class ContentSectionSlugGuardTest < Minitest::Test
  def test_enforces_a_tight_charset_with_a_flag_appropriate_message
    error = assert_raises(GhIssueSync::Error) { GhIssueSync.assert_valid_section_slug!('x-->') }
    assert_match(/--slug/, error.message)
    assert_raises(GhIssueSync::Error) { GhIssueSync.assert_valid_section_slug!('a b') }
    assert_raises(GhIssueSync::Error) { GhIssueSync.assert_valid_section_slug!('') }
    GhIssueSync.assert_valid_section_slug!('user-story')
    GhIssueSync.assert_valid_section_slug!('18-keyed.Body_section')
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

  def test_slug_guard_rejects_whitespace_slugs
    assert_raises(GhIssueSync::Error) { GhIssueSync.assert_valid_slug!('my plan') }
    GhIssueSync.assert_valid_slug!('16-gh-issue-sync-helper')
  end

  def test_slug_guard_rejects_marker_breaking_characters_in_plan_basenames
    error = assert_raises(GhIssueSync::Error) { GhIssueSync.assert_valid_slug!('notes-->') }
    assert_match(/rename the plan file/, error.message)
  end

  def test_length_guard_raises_past_the_github_body_limit_and_reports_bytes
    error = assert_raises(GhIssueSync::Error) { GhIssueSync.check_length!('a' * 262_145) }
    assert_match(/bytes/, error.message)
    GhIssueSync.check_length!('a' * 262_144)
  end
end
