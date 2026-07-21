# frozen_string_literal: true

# Shared scaffolding for tests that drive a bin/ CLI's entry point.
# This file lives outside CI's test/*_test.rb glob on purpose: the
# workflow runs every file matching that glob as its own suite, and
# this file defines no tests. The scaffolding's own contract tests
# live in test/cli_test_case_test.rb.
#
# Subclasses define run_cli(argv) to name their CLI entry point (and
# any per-CLI safety guard), and may override extra_scrubbed_env_keys
# to extend the env scrub. The scrub rides Minitest's
# before_setup/after_teardown lifecycle hooks, which run outside the
# user-level setup/teardown chain -- so subclasses may override setup
# or teardown freely, with or without super, without losing the scrub
# or the restore. Offline safety is per-CLI: the linear subclass
# hard-flunks on a leaked API token, while the gh-issue-sync tests
# stay offline by convention -- each CLI invocation fails on a local
# guard (a nonexistent plan or file path) before any gh call, and no
# env flunk could cover gh's keyring-based auth anyway.

require 'minitest/autorun'

class CliTestCase < Minitest::Test
  # Env vars whose machine values must not leak into any CLI test run,
  # deleted before each test and restored to their original values
  # afterward. POSIXLY_CORRECT is scrubbed for every CLI because
  # OptionParser's parsing mode depends on it.
  BASE_SCRUBBED_ENV_KEYS = %w[POSIXLY_CORRECT].freeze

  # Subclasses override to extend the scrub with their CLI's own env
  # keys (tokens, default-team settings, and kin).
  def extra_scrubbed_env_keys
    []
  end

  def before_setup
    keys = (BASE_SCRUBBED_ENV_KEYS + extra_scrubbed_env_keys).uniq
    @saved_env = keys.to_h { |key| [key, ENV.delete(key)] }
    super
  end

  def after_teardown
    super
    # nil only when before_setup itself raised -- that failure already
    # reported loudly, and nothing was scrubbed in that case.
    @saved_env&.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

  # Runs the CLI expecting an abort; returns the SystemExit message
  # (Kernel#abort carries its message on the exception).
  def abort_message(argv)
    message = nil
    capture_io do
      error = assert_raises(SystemExit) { run_cli(argv) }
      message = error.message
    end
    message
  end

  # Runs the CLI expecting a clean return; returns captured stdout.
  def cli_stdout(argv)
    out, _err = capture_io { run_cli(argv) }
    out
  end
end
