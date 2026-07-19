#!/usr/bin/env ruby
# frozen_string_literal: true

# Golden-master tests for bin/linear's argument handling and pure
# helpers. They pin current behavior exactly as it stands, including
# the silent drops (unknown flags and stray positionals ignored by the
# pop-style helpers) -- those pins are the flip vehicle for the
# hardening work, which edits them to expect rejection messages.
#
# The bin file guards its CLI dispatch behind $PROGRAM_NAME == __FILE__,
# so loading it here exposes the Linear module without executing the
# CLI. Run: ruby test/linear_test.rb

require 'minitest/autorun'

load File.expand_path('../bin/linear', __dir__)

# Every argument-validation path in bin/linear runs before
# Linear::Client is instantiated, and the client's first act is to
# read LINEAR_API_TOKEN. With the token scrubbed, any invocation whose
# parsing succeeds fails deterministically on this message before any
# network call -- so reaching it proves the parser accepted the
# arguments, and no test ever talks to the real API.
TOKEN_MISSING = 'linear: LINEAR_API_TOKEN env var not set'

# Base class: scrubs the Linear-related environment so results do not
# depend on this machine's token, default team, or POSIX parsing mode.
class LinearTestCase < Minitest::Test
  SCRUBBED_ENV = %w[LINEAR_API_TOKEN LINEAR_TEAM_KEY POSIXLY_CORRECT].freeze

  def setup
    @saved_env = SCRUBBED_ENV.to_h { |key| [key, ENV.delete(key)] }
  end

  def teardown
    @saved_env.each { |key, value| ENV[key] = value if value }
  end

  # Runs the CLI expecting an abort; returns the SystemExit message
  # (Kernel#abort carries its message on the exception).
  def abort_message(argv)
    message = nil
    capture_io do
      error = assert_raises(SystemExit) { Linear::CLI.run(argv) }
      message = error.message
    end
    message
  end

  # Runs the CLI expecting a clean return; returns captured stdout.
  def cli_stdout(argv)
    out, _err = capture_io { Linear::CLI.run(argv) }
    out
  end
end

class DispatchTest < LinearTestCase
  def test_no_arguments_prints_usage_without_exiting
    assert_includes cli_stdout([]), 'semantic CLI for Linear'
  end

  def test_help_prints_usage
    assert_includes cli_stdout(['help']), 'semantic CLI for Linear'
  end

  def test_dash_dash_help_prints_usage
    assert_includes cli_stdout(['--help']), 'semantic CLI for Linear'
  end

  def test_dash_h_prints_usage
    assert_includes cli_stdout(['-h']), 'semantic CLI for Linear'
  end

  def test_help_ignores_stray_arguments
    # Recorded decision: help stays lenient about strays.
    assert_includes cli_stdout(%w[help junk]), 'semantic CLI for Linear'
  end

  def test_unknown_subcommand_warns_prints_usage_and_exits_nonzero
    out = nil
    err = nil
    status = nil
    out, err = capture_io do
      error = assert_raises(SystemExit) { Linear::CLI.run(['bogus-subcommand']) }
      status = error.status
    end
    assert_equal 1, status
    assert_includes err, 'linear: unknown subcommand "bogus-subcommand"'
    assert_includes out, 'semantic CLI for Linear'
  end
end

# Pins of the current silent drops: the parser ignores the offending
# token and the command sails on to the token-missing sentinel. The
# hardening flips each of these to expect a rejection message instead.
class SilentDropPinsTest < LinearTestCase
  def test_get_silently_drops_unknown_flag
    assert_equal TOKEN_MISSING, abort_message(%w[get ABC-1 --fulll])
  end

  def test_get_silently_drops_unknown_flag_before_identifier
    assert_equal TOKEN_MISSING, abort_message(%w[get --unknown ABC-1])
  end

  def test_get_silently_ignores_stray_positional
    assert_equal TOKEN_MISSING, abort_message(%w[get ABC-1 --full extra])
  end

  def test_comments_silently_ignores_stray_positional
    assert_equal TOKEN_MISSING, abort_message(%w[comments ABC-1 extra])
  end

  def test_search_silently_ignores_stray_positional
    assert_equal TOKEN_MISSING, abort_message(%w[search term --team ABC extra])
  end

  def test_search_silently_ignores_leftover_repeated_option
    # pop_option! consumes only the first --limit pair; the second
    # lingers in the positionals unread.
    assert_equal TOKEN_MISSING, abort_message(%w[search term --limit 5 --limit abc])
  end

  def test_list_silently_ignores_stray_positional
    assert_equal TOKEN_MISSING, abort_message(%w[list --team ABC --project Foo stray])
  end

  def test_update_silently_ignores_stray_identifier
    assert_equal TOKEN_MISSING, abort_message(%w[update ABC-1 ABC-2 --state Done])
  end

  def test_relate_silently_ignores_third_identifier
    assert_equal TOKEN_MISSING, abort_message(%w[relate ABC-1 ABC-2 ABC-3])
  end

  def test_comment_delete_silently_ignores_stray_positional
    assert_equal TOKEN_MISSING, abort_message(%w[comment-delete some-id extra])
  end

  def test_create_silently_ignores_stray_positional
    assert_equal TOKEN_MISSING,
                 abort_message(%w[create --team ABC --title Title --priority medium --no-project stray])
  end

  def test_project_create_silently_ignores_stray_positional
    assert_equal TOKEN_MISSING, abort_message(%w[project-create --team ABC --name Foo stray])
  end

  def test_project_list_silently_ignores_stray_positional
    assert_equal TOKEN_MISSING, abort_message(%w[project-list --team ABC stray])
  end
end

# Exact usage and validation messages that survive the hardening
# unchanged.
class UsageErrorsTest < LinearTestCase
  def test_get_requires_identifier
    assert_equal 'Usage: linear get ABC-NNN [--full] [--json]', abort_message(['get'])
  end

  def test_comments_requires_identifier
    assert_equal 'Usage: linear comments ABC-NNN [--json]', abort_message(['comments'])
  end

  def test_search_requires_term
    assert_equal 'Usage: linear search "phrase" [--team KEY] [--limit N] [--json]', abort_message(['search'])
  end

  def test_search_rejects_empty_term
    assert_equal 'Usage: linear search "phrase" [--team KEY] [--limit N] [--json]', abort_message(['search', ''])
  end

  def test_search_team_requires_value
    assert_equal 'linear: --team requires a value', abort_message(%w[search term --team])
  end

  def test_search_team_rejects_flag_shaped_value
    assert_equal 'linear: --team requires a value', abort_message(%w[search --team --json])
  end

  def test_search_limit_requires_integer
    assert_equal 'linear: --limit must be an integer, got "abc"', abort_message(%w[search term --limit abc])
  end

  def test_list_requires_team_when_env_unset
    assert_includes abort_message(['list']), 'Usage: linear list --team KEY'
  end

  def test_list_requires_project_or_since
    assert_includes abort_message(%w[list --team ABC]), 'Usage: linear list --team KEY'
  end

  def test_list_since_requires_iso_date
    assert_equal 'linear: --since must be YYYY-MM-DD, got "01-01-2026"',
                 abort_message(%w[list --team ABC --since 01-01-2026])
  end

  def test_create_requires_team_and_title
    assert_includes abort_message(['create']), 'Usage: linear create --team KEY --title TITLE'
  end

  def test_create_requires_priority
    assert_includes abort_message(%w[create --team ABC --title Title]),
                    'linear: --priority is required on create'
  end

  def test_create_requires_project_or_no_project
    assert_includes abort_message(%w[create --team ABC --title Title --priority medium]),
                    'linear: --project is required (or pass --no-project to override).'
  end

  def test_update_requires_identifier
    assert_includes abort_message(['update']), 'Usage: linear update ABC-NNN'
  end

  def test_update_requires_identifier_even_with_flags
    assert_includes abort_message(%w[update --state Done]), 'Usage: linear update ABC-NNN'
  end

  def test_comment_requires_identifier
    assert_equal 'Usage: linear comment ABC-NNN ("message" | --body TEXT | --body-file PATH)',
                 abort_message(['comment'])
  end

  def test_comment_requires_body
    assert_equal 'Usage: linear comment ABC-NNN ("message" | --body TEXT | --body-file PATH)',
                 abort_message(%w[comment ABC-1])
  end

  def test_comment_with_body_but_no_identifier_shows_usage
    assert_equal 'Usage: linear comment ABC-NNN ("message" | --body TEXT | --body-file PATH)',
                 abort_message(%w[comment --body text])
  end

  def test_comment_rejects_unknown_flag
    assert_equal 'linear: unknown option --badflag (comment takes a positional message, --body TEXT, or --body-file PATH)',
                 abort_message(%w[comment ABC-1 --badflag])
  end

  def test_comment_body_file_must_exist
    assert_equal 'linear: --body-file not found: /nonexistent-battery-file',
                 abort_message(%w[comment ABC-1 --body-file /nonexistent-battery-file])
  end

  def test_comment_delete_requires_id
    assert_equal 'Usage: linear comment-delete COMMENT_ID (see "linear comments ABC-NNN")',
                 abort_message(['comment-delete'])
  end

  def test_relate_requires_two_identifiers
    assert_includes abort_message(%w[relate ABC-1]), 'Usage: linear relate ABC-AAA ABC-BBB'
  end

  def test_project_create_requires_team_and_name
    assert_includes abort_message(%w[project-create --team ABC]), 'Usage: linear project-create --team KEY --name NAME'
  end

  def test_project_update_requires_id
    assert_includes abort_message(['project-update']), 'Usage: linear project-update --id PROJECT_ID'
  end

  def test_project_update_requires_a_field
    assert_equal 'linear: nothing to update; pass --name, --description, or --content',
                 abort_message(%w[project-update --id X])
  end

  def test_project_list_requires_team_when_env_unset
    assert_equal 'Usage: linear project-list --team KEY [--json] (or set LINEAR_TEAM_KEY)',
                 abort_message(['project-list'])
  end
end

# The OptionParser-based subcommands currently let unknown-option
# errors escape uncaught (a raw backtrace, not an abort). Pinned so
# the change to friendly rejection messages is a visible flip.
class OptionParserEscapePinsTest < LinearTestCase
  def test_create_unknown_option_escapes_uncaught
    error = assert_raises(OptionParser::InvalidOption) { Linear::CLI.run(%w[create --bogus]) }
    assert_equal 'invalid option: --bogus', error.message
  end

  def test_update_unknown_option_escapes_uncaught
    error = assert_raises(OptionParser::InvalidOption) { Linear::CLI.run(%w[update ABC-1 --bogus]) }
    assert_equal 'invalid option: --bogus', error.message
  end

  def test_relate_unknown_option_escapes_uncaught
    error = assert_raises(OptionParser::InvalidOption) { Linear::CLI.run(%w[relate ABC-1 ABC-2 --bogus]) }
    assert_equal 'invalid option: --bogus', error.message
  end

  def test_project_create_unknown_option_escapes_uncaught
    error = assert_raises(OptionParser::InvalidOption) { Linear::CLI.run(%w[project-create --bogus]) }
    assert_equal 'invalid option: --bogus', error.message
  end
end

class PureHelpersTest < LinearTestCase
  def test_parse_limit_accepts_decimal
    assert_equal 25, Linear.parse_limit('25')
  end

  def test_parse_limit_rejects_non_integer
    error = assert_raises(Linear::Error) { Linear.parse_limit('abc') }
    assert_equal 'linear: --limit must be an integer, got "abc"', error.message
  end

  def test_parse_limit_currently_reads_leading_zero_as_octal
    # Bare Integer() semantics, pinned; the hardening moves to base 10.
    assert_equal 8, Linear.parse_limit('010')
  end

  def test_parse_limit_currently_reads_hex_prefix
    assert_equal 16, Linear.parse_limit('0x10')
  end

  def test_parse_limit_currently_accepts_zero_and_negative
    assert_equal 0, Linear.parse_limit('0')
    assert_equal(-5, Linear.parse_limit('-5'))
  end

  def test_resolve_priority_names_and_case
    assert_equal 3, Linear.resolve_priority('medium')
    assert_equal 1, Linear.resolve_priority('URGENT')
    assert_equal 0, Linear.resolve_priority('none')
  end

  def test_resolve_priority_accepts_digit_strings
    assert_equal 2, Linear.resolve_priority('2')
  end

  def test_resolve_priority_rejects_out_of_range_and_nonsense
    error = assert_raises(Linear::Error) { Linear.resolve_priority('7') }
    assert_equal 'linear: invalid priority "7"; use none|urgent|high|medium|low or 0-4', error.message
    assert_raises(Linear::Error) { Linear.resolve_priority('nonsense') }
  end

  def test_pop_flag_removes_first_occurrence_and_reports_presence
    args = %w[a --json b]
    assert Linear.pop_flag!(args, '--json')
    assert_equal %w[a b], args
    refute Linear.pop_flag!(args, '--json')
  end

  def test_pop_option_takes_following_token_as_value
    args = %w[a --team ABC b]
    assert_equal 'ABC', Linear.pop_option!(args, '--team')
    assert_equal %w[a b], args
  end

  def test_pop_option_returns_nil_when_absent
    assert_nil Linear.pop_option!(%w[a b], '--team')
  end

  def test_pop_option_rejects_missing_and_double_dash_values
    error = assert_raises(Linear::Error) { Linear.pop_option!(%w[--team], '--team') }
    assert_equal 'linear: --team requires a value', error.message
    assert_raises(Linear::Error) { Linear.pop_option!(%w[--team --json], '--team') }
  end

  def test_pop_option_currently_accepts_single_dash_values
    # Only double-dash values are rejected today; pinned, the
    # hardening rejects any leading dash.
    assert_equal '-x', Linear.pop_option!(%w[--team -x], '--team')
  end
end
