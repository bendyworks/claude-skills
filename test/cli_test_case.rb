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
# hard-flunks on a leaked API token, while gh-issue-sync's tests name
# gh in shimmed_commands, so any code path that reaches a gh
# invocation hits a failing PATH shim and flunks -- no env scrub could
# cover gh's keyring-based auth.

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'

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

  # Subclasses override to name commands their CLI shells out to that
  # must never reach the real executable during a test (network-touching
  # binaries whose credentials live outside ENV, like gh's keyring
  # auth). Each name is shadowed by a PATH shim that records the
  # attempt and fails, and the test flunks after teardown if any shim
  # was hit.
  def shimmed_commands
    []
  end

  def before_setup
    super
    keys = (BASE_SCRUBBED_ENV_KEYS + extra_scrubbed_env_keys).uniq
    @saved_env = keys.to_h { |key| [key, ENV.delete(key)] }
    install_command_shims
  end

  def after_teardown
    remove_command_shims
    # nil only when before_setup raised before the env snapshot was
    # taken (a broken extra_scrubbed_env_keys override) -- that
    # failure already reported loudly, and nothing was scrubbed. A
    # later raise (a failed shim install) leaves the snapshot in
    # place, and this restore still runs.
    @saved_env&.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
    super
    # The verdict comes after super so a flunk cannot skip an
    # ancestor's cleanup.
    flunk "command intercepted by test shim (live call refused):\n#{@shim_hits}" if @shim_hits
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

  private

  def install_command_shims
    return if shimmed_commands.empty?

    # Saved before any fallible work: if anything below raises,
    # remove_command_shims must restore PATH from a real value, never
    # assign nil over it.
    @saved_path = ENV.fetch('PATH')
    @shim_dir = Dir.mktmpdir('cli-test-shims')
    shim_log = File.join(@shim_dir, 'invocations.log')
    shimmed_commands.each do |command|
      shim_path = File.join(@shim_dir, command)
      File.write(shim_path, <<~SCRIPT)
        #!/bin/sh
        echo "#{command} $*" >> "#{shim_log}"
        echo "#{command}: intercepted by test shim (live call refused)" >&2
        exit 1
      SCRIPT
      File.chmod(0o755, shim_path)
    end
    ENV['PATH'] = "#{@shim_dir}#{File::PATH_SEPARATOR}#{@saved_path}"
  end

  def remove_command_shims
    return unless @shim_dir

    ENV['PATH'] = @saved_path
    shim_log = File.join(@shim_dir, 'invocations.log')
    @shim_hits = File.exist?(shim_log) ? File.read(shim_log) : nil
    FileUtils.remove_entry(@shim_dir)
    @shim_dir = nil
  end
end
