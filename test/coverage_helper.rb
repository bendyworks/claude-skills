# frozen_string_literal: true

# Opt-in SimpleCov bootstrap for the bin/ CLI test suite. Does nothing
# unless the COVERAGE env var is set, so a plain test run needs no
# gems and the bin/ CLIs' stdlib-only posture is untouched.
#
# Required at the very top of test/cli_test_case.rb, above
# minitest/autorun, so coverage starts before any bin/ file is loaded
# and SimpleCov's at_exit report runs after Minitest's.
#
# CI runs each test/*_test.rb as its own process, so every process
# records its own resultset entry (keyed by command_name below) and
# SimpleCov merges them; coverage/coverage.json carries the merged
# union and is the artifact of record. coverage/.resultset.json is
# per-process raw data, where a tracked-but-unloaded file shows as all
# zeros -- do not read uncovered lines from it directly.

if ENV['COVERAGE']
  # Must match the pinned install in .github/workflows/checks.yml
  # (ruby-tests job); update both together.
  SIMPLECOV_VERSION = '0.22.0'

  begin
    require 'simplecov'
  rescue LoadError
    abort "coverage_helper: COVERAGE is set but simplecov is not " \
          "installed; run: gem install simplecov -v #{SIMPLECOV_VERSION}"
  end
  require 'simplecov_json_formatter'

  # Root and the tracked glob are both pinned to absolute paths:
  # SimpleCov resolves each against the current working directory by
  # default, and a test run started from inside test/ would silently
  # drop all bin/ coverage.
  repo_root = File.expand_path('..', __dir__)

  SimpleCov.start do
    root repo_root
    command_name File.basename($PROGRAM_NAME)
    track_files File.join(repo_root, 'bin', '*')
    add_filter '/test/'
    enable_coverage :branch
    # Default merge window is 600s; a slow local gauntlet session can
    # exceed it between test-file processes, silently shrinking the
    # merged union.
    merge_timeout 3600
    formatter SimpleCov::Formatter::MultiFormatter.new(
      [
        SimpleCov::Formatter::HTMLFormatter,
        SimpleCov::Formatter::JSONFormatter
      ]
    )
  end
end
