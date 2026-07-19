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

# The load runs the module body before any setup scrub can protect it,
# so bin/linear's module body must stay side-effect-free: no env reads,
# no network, nothing but definitions.
load File.expand_path('../bin/linear', __dir__)

# The usage and requiredness checks in every subcommand run before
# Linear::Client is instantiated, and the client's first act is to
# read LINEAR_API_TOKEN. With the token scrubbed, any invocation whose
# argv the parser accepts fails deterministically on this message
# before any network call -- so reaching it proves the parser accepted
# the arguments, and no test ever talks to the real API. It proves
# only that: the identifier-format checks in get/comments run AFTER
# the client is built, so with the token scrubbed a malformed
# identifier also lands here, not on its own message.
TOKEN_MISSING = 'linear: LINEAR_API_TOKEN env var not set'

# Shared across tests so the copies cannot drift from each other;
# still independent literals, never imported from bin/linear.
SEARCH_USAGE = 'Usage: linear search "phrase" [--team KEY] [--limit N] [--json]'
COMMENT_USAGE = 'Usage: linear comment ABC-NNN ("message" | --body TEXT | --body-file PATH)'

# Base class: scrubs the Linear-related environment so results do not
# depend on this machine's token, default team, or POSIX parsing mode.
class LinearTestCase < Minitest::Test
  SCRUBBED_ENV = %w[LINEAR_API_TOKEN LINEAR_TEAM_KEY POSIXLY_CORRECT].freeze

  def setup
    @saved_env = SCRUBBED_ENV.to_h { |key| [key, ENV.delete(key)] }
  end

  def teardown
    @saved_env.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

  # Runs the CLI expecting an abort; returns the SystemExit message
  # (Kernel#abort carries its message on the exception).
  def abort_message(argv)
    message = nil
    capture_io do
      error = assert_raises(SystemExit) { run_scrubbed(argv) }
      message = error.message
    end
    message
  end

  # Runs the CLI expecting a clean return; returns captured stdout.
  def cli_stdout(argv)
    out, _err = capture_io { run_scrubbed(argv) }
    out
  end

  # Defense in depth: the sentinel pins only stay offline while the
  # env scrub holds, and one of them reaches a live commentDelete
  # mutation if it does not. Refuse to run the CLI with a real token
  # present (e.g. a subclass overriding setup without super).
  def run_scrubbed(argv)
    flunk 'LINEAR_API_TOKEN leaked into the test environment' if ENV.key?('LINEAR_API_TOKEN')
    Linear::CLI.run(argv)
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

  def test_unknown_subcommand_warns_prints_usage_and_exits_nonzero
    status = nil
    out, err = capture_io do
      error = assert_raises(SystemExit) { run_scrubbed(['bogus-subcommand']) }
      status = error.status
    end
    assert_equal 1, status
    assert_includes err, 'linear: unknown subcommand "bogus-subcommand"'
    assert_includes out, 'semantic CLI for Linear'
  end
end

# A positional the subcommand has no slot for means part of the typed
# command was not understood, so every subcommand but comment (whose
# trailing words are the message) and help now rejects one.
class StrayPositionalRejectionsTest < LinearTestCase
  def test_get_rejects_stray_positional
    assert_equal 'linear: unexpected extra arguments: "extra"', abort_message(%w[get ABC-1 --full extra])
  end

  def test_comments_rejects_stray_positional
    assert_equal 'linear: unexpected extra arguments: "extra"', abort_message(%w[comments ABC-1 extra])
  end

  def test_search_rejects_stray_positional
    assert_equal 'linear: unexpected extra arguments: "extra"', abort_message(%w[search term --team ABC extra])
  end

  def test_list_rejects_stray_positional
    assert_equal 'linear: unexpected extra arguments: "stray"', abort_message(%w[list --team ABC --project Foo stray])
  end

  def test_update_rejects_second_identifier
    # The shape that used to update ABC-1 and drop ABC-2 on the floor.
    assert_equal 'linear: unexpected extra arguments: "ABC-2"', abort_message(%w[update ABC-1 ABC-2 --state Done])
  end

  def test_relate_rejects_third_identifier
    assert_equal 'linear: unexpected extra arguments: "ABC-3"', abort_message(%w[relate ABC-1 ABC-2 ABC-3])
  end

  def test_comment_delete_rejects_stray_positional
    assert_equal 'linear: unexpected extra arguments: "extra"', abort_message(%w[comment-delete some-id extra])
  end

  def test_create_rejects_stray_positional
    assert_equal 'linear: unexpected extra arguments: "stray"',
                 abort_message(%w[create --team ABC --title Title --priority medium --no-project stray])
  end

  def test_project_create_rejects_stray_positional
    assert_equal 'linear: unexpected extra arguments: "stray"',
                 abort_message(%w[project-create --team ABC --name Foo stray])
  end

  def test_project_update_rejects_stray_positional
    assert_equal 'linear: unexpected extra arguments: "stray"',
                 abort_message(%w[project-update --id X --name Foo stray])
  end

  def test_project_list_rejects_stray_positional
    assert_equal 'linear: unexpected extra arguments: "stray"', abort_message(%w[project-list --team ABC stray])
  end

  def test_every_stray_is_listed_and_inspect_quoted
    # Inspect-quoted because a mis-quoted shell line can leave a stray
    # containing spaces, which a bare token would read as two.
    assert_equal 'linear: unexpected extra arguments: "a b", "c"', abort_message(['get', 'ABC-1', 'a b', 'c'])
  end

  def test_comment_keeps_its_trailing_positionals_as_the_message
    # The sole opt-out: reaching the sentinel proves the parser took
    # the trailing words rather than rejecting them.
    assert_equal TOKEN_MISSING, abort_message(%w[comment ABC-1 words of message])
  end

  def test_help_stays_lenient_about_strays
    # Recorded decision, restated here next to the guard it exempts.
    assert_includes cli_stdout(%w[help junk]), 'semantic CLI for Linear'
  end
end

# Options the pop-style helpers used to drop on the floor now reach
# OptionParser, which rejects them by name. The messages are
# optparse's own, prefixed with the CLI name the way every other
# linear error is.
class ParseRejectionsTest < LinearTestCase
  def test_get_rejects_unknown_flag_and_suggests_the_near_miss
    # optparse appends its own did-you-mean line for a close match,
    # which is exactly the affordance a typo'd flag wants.
    assert_equal "linear: invalid option: --fulll\nDid you mean?  full",
                 abort_message(%w[get ABC-1 --fulll])
  end

  def test_get_rejects_leading_unknown_flag_instead_of_taking_it_as_the_identifier
    assert_equal 'linear: invalid option: --unknown', abort_message(%w[get --unknown ABC-1])
  end

  def test_comments_rejects_unknown_flag
    assert_equal 'linear: invalid option: --bogus', abort_message(%w[comments ABC-1 --bogus])
  end

  def test_search_rejects_unknown_flag
    assert_equal 'linear: invalid option: --bogus', abort_message(%w[search term --bogus])
  end

  def test_list_rejects_unknown_flag
    assert_equal 'linear: invalid option: --bogus', abort_message(%w[list --team ABC --bogus])
  end

  def test_comment_delete_rejects_unknown_flag
    assert_equal 'linear: invalid option: --bogus', abort_message(%w[comment-delete some-id --bogus])
  end

  def test_project_list_rejects_unknown_flag
    assert_equal 'linear: invalid option: --bogus', abort_message(%w[project-list --team ABC --bogus])
  end

  def test_double_dash_terminator_protects_a_dash_leading_search_term
    # The escape hatch for values the leading-dash guard would reject.
    assert_equal TOKEN_MISSING, abort_message(['search', '--', '-not-a-flag'])
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
    assert_equal SEARCH_USAGE, abort_message(['search'])
  end

  def test_search_rejects_empty_term
    assert_equal SEARCH_USAGE, abort_message(['search', ''])
  end

  def test_search_team_requires_value
    assert_equal 'linear: missing argument: --team', abort_message(%w[search term --team])
  end

  def test_search_team_rejects_flag_shaped_value
    # Every flag is now a candidate: --team's value is read by the same
    # parser pass that knows --json and --limit, so neither can be
    # swallowed as a value.
    assert_equal 'linear: invalid argument: --team --limit', abort_message(%w[search term --team --limit 5])
    assert_equal 'linear: invalid argument: --team --json', abort_message(%w[search term --team --json])
  end

  def test_search_team_rejects_single_dash_value
    assert_equal 'linear: invalid argument: --team -x', abort_message(%w[search term --team -x])
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
    assert_equal COMMENT_USAGE, abort_message(['comment'])
  end

  def test_comment_requires_body
    assert_equal COMMENT_USAGE, abort_message(%w[comment ABC-1])
  end

  def test_comment_with_body_but_no_identifier_shows_usage
    assert_equal COMMENT_USAGE, abort_message(%w[comment --body text])
  end

  def test_comment_rejects_unknown_flag
    assert_equal 'linear: invalid option: --badflag ' \
                 '(comment takes a positional message, --body TEXT, or --body-file PATH)',
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
    assert_equal 'Usage: linear relate ABC-AAA ABC-BBB [--type related|blocks|duplicate] [--json]',
                 abort_message(%w[relate ABC-1])
  end

  def test_project_create_requires_team_and_name
    assert_equal 'Usage: linear project-create --team KEY --name NAME ' \
                 '[--description TEXT] [--content TEXT | --content-file PATH] [--json]',
                 abort_message(%w[project-create --team ABC])
  end

  def test_project_update_requires_id
    assert_equal 'Usage: linear project-update --id PROJECT_ID ' \
                 '[--name NAME] [--description TEXT] [--content TEXT | --content-file PATH] [--json]',
                 abort_message(['project-update'])
  end

  def test_project_update_requires_a_field
    assert_equal 'linear: nothing to update; pass --name, --description, or --content',
                 abort_message(%w[project-update --id X])
  end

  def test_project_update_accepts_a_named_field
    # Landing on the sentinel rather than "nothing to update" is the
    # observable proof that --name's value reached the mutation input,
    # not just that the parser tolerated the flag.
    assert_equal TOKEN_MISSING, abort_message(%w[project-update --id X --name Foo])
  end

  def test_project_list_requires_team_when_env_unset
    assert_equal 'Usage: linear project-list --team KEY [--json] (or set LINEAR_TEAM_KEY)',
                 abort_message(['project-list'])
  end
end

# Repeating a value-taking option used to keep the last value and
# discard the first -- the same dropped-input shape as a stray
# positional, and worse when the surviving value aims the command at
# a different issue or project than the one typed first.
class DuplicateOptionRejectionsTest < LinearTestCase
  def test_search_rejects_duplicate_team
    assert_equal 'linear: duplicate --team', abort_message(%w[search term --team A --team B])
  end

  def test_search_rejects_duplicate_limit
    assert_equal 'linear: duplicate --limit', abort_message(%w[search term --limit 5 --limit 9])
  end

  def test_list_rejects_duplicate_project
    assert_equal 'linear: duplicate --project', abort_message(%w[list --team ABC --project P --project Q])
  end

  def test_project_list_rejects_duplicate_team
    assert_equal 'linear: duplicate --team', abort_message(%w[project-list --team A --team B])
  end

  def test_create_rejects_duplicate_team
    assert_equal 'linear: duplicate --team',
                 abort_message(%w[create --team A --team B --title T --priority medium --no-project])
  end

  def test_update_rejects_duplicate_state
    assert_equal 'linear: duplicate --state', abort_message(%w[update ABC-1 --state A --state B])
  end

  def test_relate_rejects_duplicate_type
    assert_equal 'linear: duplicate --type', abort_message(%w[relate ABC-1 ABC-2 --type blocks --type related])
  end

  def test_project_create_rejects_duplicate_name
    assert_equal 'linear: duplicate --name', abort_message(%w[project-create --team ABC --name X --name Y])
  end

  def test_project_update_rejects_duplicate_name
    assert_equal 'linear: duplicate --name', abort_message(%w[project-update --id X --name A --name B])
  end

  def test_comment_rejects_duplicate_body
    assert_equal 'linear: duplicate --body', abort_message(%w[comment ABC-1 --body a --body b])
  end

  def test_repeating_a_boolean_flag_stays_harmless
    # Deliberately out of scope: a repeated switch discards no input,
    # so there is nothing to protect the user from.
    assert_equal TOKEN_MISSING, abort_message(%w[get ABC-1 --json --json])
  end
end

# The subcommands that already used OptionParser never carried the
# acceptance pattern, so a mandatory-argument option would swallow a
# following flag as its value and act on the misread command.
class FlagShapedValueRejectionsTest < LinearTestCase
  def test_create_rejects_flag_shaped_title
    assert_equal 'linear: invalid argument: --title --json',
                 abort_message(%w[create --team ABC --title --json --priority medium --no-project])
  end

  def test_update_rejects_flag_shaped_state
    assert_equal 'linear: invalid argument: --state --json', abort_message(%w[update ABC-1 --state --json])
  end

  def test_relate_rejects_flag_shaped_type
    assert_equal 'linear: invalid argument: --type --json', abort_message(%w[relate ABC-1 ABC-2 --type --json])
  end

  def test_project_create_rejects_flag_shaped_name
    assert_equal 'linear: invalid argument: --name --json',
                 abort_message(%w[project-create --team ABC --name --json])
  end

  def test_project_update_rejects_flag_shaped_id
    assert_equal 'linear: invalid argument: --id --json', abort_message(%w[project-update --id --json])
  end

  def test_comment_rejects_flag_shaped_body
    assert_equal 'linear: invalid argument: --body --json ' \
                 '(comment takes a positional message, --body TEXT, or --body-file PATH)',
                 abort_message(%w[comment ABC-1 --body --json])
  end
end

# These five subcommands used to let OptionParser's own exception
# escape as a raw backtrace. Routing them through parse_options turns
# each into an ordinary aborted-with-a-message failure.
class UncaughtParseErrorRejectionsTest < LinearTestCase
  def test_create_rejects_unknown_option
    assert_equal 'linear: invalid option: --bogus', abort_message(%w[create --bogus])
  end

  def test_update_rejects_unknown_option
    assert_equal 'linear: invalid option: --bogus', abort_message(%w[update ABC-1 --bogus])
  end

  def test_relate_rejects_unknown_option
    assert_equal 'linear: invalid option: --bogus', abort_message(%w[relate ABC-1 ABC-2 --bogus])
  end

  def test_project_create_rejects_unknown_option
    assert_equal 'linear: invalid option: --bogus', abort_message(%w[project-create --bogus])
  end

  def test_project_update_rejects_unknown_option
    assert_equal 'linear: invalid option: --bogus', abort_message(%w[project-update --bogus])
  end
end

class PureHelpersTest < LinearTestCase
  def test_parse_limit_accepts_base_ten
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
    error = assert_raises(Linear::Error) { Linear.resolve_priority('nonsense') }
    assert_equal 'linear: invalid priority "nonsense"; use none|urgent|high|medium|low or 0-4', error.message
  end

  def test_pop_helpers_are_retired
    refute Linear.respond_to?(:pop_flag!), 'pop_flag! should be gone; every subcommand parses with OptionParser'
    refute Linear.respond_to?(:pop_option!), 'pop_option! should be gone; every subcommand parses with OptionParser'
  end
end
