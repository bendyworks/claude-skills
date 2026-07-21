# frozen_string_literal: true

# Shared scaffolding for tests that drive a bin/ CLI's entry point.
# This file lives outside CI's test/*_test.rb glob on purpose: the
# workflow runs every file matching that glob as its own suite, and
# this file defines no tests.
#
# Subclasses define run_cli(argv) to name their CLI entry point (and
# any per-CLI safety guard), and may override scrubbed_env_keys to
# extend the env scrub. Offline safety is per-CLI: the linear subclass
# hard-flunks on a leaked API token, while the gh-issue-sync tests
# stay offline by convention -- each CLI invocation fails on a local
# guard (a nonexistent plan or file path) before any gh call, and no
# env flunk could cover gh's keyring-based auth anyway.

require 'minitest/autorun'

class CliTestCase < Minitest::Test
  # Env vars whose machine values must not leak into a test run,
  # deleted in setup and restored to their original values in
  # teardown. A method rather than a constant so the base's setup sees
  # subclass overrides. POSIXLY_CORRECT is scrubbed for every CLI
  # because OptionParser's parsing mode depends on it.
  def scrubbed_env_keys
    %w[POSIXLY_CORRECT]
  end

  def setup
    @saved_env = scrubbed_env_keys.to_h { |key| [key, ENV.delete(key)] }
  end

  def teardown
    @saved_env.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
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
