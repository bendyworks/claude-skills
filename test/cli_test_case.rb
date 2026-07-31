# frozen_string_literal: true

# Shared scaffolding for tests that drive a bin/ CLI's entry point.
# This file lives outside CI's test/*_test.rb glob on purpose: the
# workflow runs every file matching that glob as its own suite, and
# this file defines no tests. The scaffolding's own contract tests
# live in test/cli_test_case_test.rb.
#
# Subclasses define dispatch_cli(argv) to name their CLI entry point
# and guard_cli_invocation(argv) for any per-CLI safety refusal, and
# may override extra_scrubbed_env_keys to extend the env scrub. run_cli
# itself is base-owned and refuses to be overridden, so that no suite
# can dispatch around its own guard. The scrub rides Minitest's
# before_setup/after_teardown lifecycle hooks, which run outside the
# user-level setup/teardown chain -- so subclasses may override setup
# or teardown freely, with or without super, without losing the scrub
# or the restore. Offline safety is per-CLI: the linear subclass
# hard-flunks on a leaked API token, while gh-issue-sync's tests name
# gh in shimmed_commands, so any code path that reaches a gh
# invocation hits a failing PATH shim and flunks -- no env scrub could
# cover gh's keyring-based auth.

# Coverage must load first: SimpleCov has to start before any bin/
# file is loaded, and before minitest loads, since minitest installs
# the reporting plugin only when it loads second. See the header of
# coverage_helper.rb; the order is pinned by a contract test.
require_relative 'coverage_helper'

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'

class CliTestCase < Minitest::Test
  # The variables that aim git at a repository other than the one named
  # on the command line. `git -C <dir>` does not override an inherited
  # GIT_DIR, and a CLI shelling out to git passes no environment of its
  # own -- in real use these variables are the developer saying where
  # their repository is, and honoring them is correct. In a test they
  # are the developer's own clone, reached by a CLI that believes it is
  # working on a throwaway. Scrubbed for every CLI suite rather than
  # only where a fixture builds one, because a test that drives a CLI
  # without building anything -- argument handling, a usage error --
  # still reaches far enough in for it to run git.
  GIT_LOCATION_ENV_KEYS = %w[
    GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE
    GIT_CEILING_DIRECTORIES
  ].freeze

  # Git variables that reach git's configuration without going through
  # any config file, so pointing GIT_CONFIG_GLOBAL and GIT_CONFIG_SYSTEM
  # at an empty one does not neutralize them. core.hooksPath arriving
  # this way is arbitrary script execution during a test, and
  # `git branch -d` does fire the reference-transaction hook.
  GIT_CONFIG_ENV_KEYS = %w[
    GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
    GIT_TEMPLATE_DIR
  ].freeze

  # Env vars whose machine values must not leak into any CLI test run,
  # deleted before each test and restored to their original values
  # afterward. POSIXLY_CORRECT is scrubbed for every CLI because
  # OptionParser's parsing mode depends on it.
  BASE_SCRUBBED_ENV_KEYS = (%w[POSIXLY_CORRECT] + GIT_LOCATION_ENV_KEYS +
                            GIT_CONFIG_ENV_KEYS).freeze

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

  # The invocation the tests drive, owned here rather than written per
  # suite: a safety check hand-rolled inside a subclass's own run_cli is
  # one the next suite copies by hand, and a copy that drifts or is
  # forgotten leaves a suite that goes on passing with nothing checked.
  # Subclasses name their entry point in dispatch_cli and their
  # refusals in guard_cli_invocation.
  def run_cli(argv)
    guard_cli_invocation(argv)
    dispatch_cli(argv)
  end

  # Subclasses override to refuse an invocation that must never reach
  # the CLI at all -- a leaked API token, a target repository outside
  # the throwaway directory -- by flunking. Runs before every dispatch.
  def guard_cli_invocation(argv); end

  # Subclasses override to name their CLI's entry point.
  def dispatch_cli(_argv)
    raise NotImplementedError, "#{self.class} must define dispatch_cli naming its CLI entry point"
  end

  def before_setup
    super
    # An overriding subclass looks exactly like a working one, and what
    # it drops is the guard, so this is refused rather than discouraged.
    if method(:run_cli).owner != CliTestCase
      flunk "#{self.class} overrides run_cli; define dispatch_cli instead, so a " \
            'per-CLI guard cannot be bypassed by overriding the runner that calls it'
    end

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

  # Everything a refusing CLI did on its way out. Kernel#abort carries
  # its message on the exception and exits 1; a CLI that prints its own
  # complaint and calls exit instead carries no message worth reading,
  # which is why the streams and the status are here beside it.
  AbortResult = Struct.new(:status, :message, :stdout, :stderr)

  # Runs the CLI expecting an abort; returns an AbortResult.
  def abort_result(argv)
    status = nil
    message = nil
    out, err = capture_io do
      error = assert_raises(SystemExit) { run_cli(argv) }
      status = error.status
      message = error.message
    end
    AbortResult.new(status, message, out, err)
  end

  # Runs the CLI expecting an abort; returns the SystemExit message
  # alone, which is all most rejection tests care about.
  def abort_message(argv)
    abort_result(argv).message
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
