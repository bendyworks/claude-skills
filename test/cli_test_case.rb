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
  # GIT_DIR, so a CLI that passes no environment of its own inherits
  # whatever the shell names. In a test that is the developer's own
  # clone, reached by a CLI that believes it is working on a
  # throwaway. (bin/stale-branches unsets these for its own children
  # too, because it deletes; this scrub covers every CLI, including the
  # ones that do not.) Scrubbed for every CLI suite rather than
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

  # How a serving stub reports back: one line per invocation to the
  # first, one line per invocation it does not serve to the second. The
  # installer sets both, and they are scrubbed alongside everything else
  # so an ambient value cannot send a stub's log somewhere this run
  # never reads -- which would look exactly like a CLI that asked
  # nothing.
  CLI_STUB_LOG_ENV = 'CLI_STUB_LOG'
  CLI_STUB_REFUSALS_ENV = 'CLI_STUB_REFUSALS'

  # Env vars whose machine values must not leak into any CLI test run,
  # deleted before each test and restored to their original values
  # afterward. POSIXLY_CORRECT is scrubbed for every CLI because
  # OptionParser's parsing mode depends on it.
  BASE_SCRUBBED_ENV_KEYS = (%w[POSIXLY_CORRECT] + GIT_LOCATION_ENV_KEYS +
                            GIT_CONFIG_ENV_KEYS +
                            [CLI_STUB_LOG_ENV, CLI_STUB_REFUSALS_ENV]).freeze

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

  # Subclasses override to name commands their CLI shells out to that a
  # test must ANSWER rather than refuse: a forge client whose replies
  # are the fixture's own data. Each entry maps the command's name to
  # the path of a program serving it, which the installer copies onto
  # PATH under that name.
  #
  # A path rather than a script body, so the program stays a file that
  # can be run, read, and tested on its own -- a stub reachable only
  # through the suite it serves is one nothing can check the shape of.
  #
  # The two lists are opposites, and a command in both would have one of
  # them silently win, so naming a command in both is refused.
  def served_commands
    {}
  end

  # Every invocation the serving stubs have recorded so far, one string
  # per call, readable during the test. What a CLI asked the forge is
  # half of what a forge test is asserting: a sweep that queries a
  # branch it should never have reached is wrong even when every verdict
  # it prints is right.
  def served_invocations
    log = @stub_log
    return [] unless log && File.exist?(log)

    File.readlines(log).map(&:chomp)
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
    install_path_stand_ins
  end

  def after_teardown
    remove_path_stand_ins
    # nil only when before_setup raised before the env snapshot was
    # taken (a broken extra_scrubbed_env_keys override) -- that
    # failure already reported loudly, and nothing was scrubbed. A
    # later raise (a failed shim install) leaves the snapshot in
    # place, and this restore still runs.
    @saved_env&.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
    super
    # The verdicts come after super so a flunk cannot skip an
    # ancestor's cleanup.
    flunk "command intercepted by test shim (live call refused):\n#{@shim_hits}" if @shim_hits
    return unless @stub_refusal_hits

    # A stub that answered a call it does not serve would teach the
    # suite that the CLI asked something it never asked, so the refusal
    # is carried out to here rather than left in the stub's exit status,
    # which a CLI degrading on failure is entitled to swallow.
    flunk "invocation refused by test stub (nothing serves it):\n#{@stub_refusal_hits}"
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

  # Both kinds of stand-in share one directory at the front of PATH: the
  # refusing shims, and the stubs that serve. The emptiness test covers
  # both lists, so a suite that only serves still gets a PATH to serve
  # from.
  def install_path_stand_ins
    refuse_overlapping_stand_ins
    return if shimmed_commands.empty? && served_commands.empty?

    # Saved before any fallible work: if anything below raises,
    # remove_path_stand_ins must restore PATH from a real value, never
    # assign nil over it.
    @saved_path = ENV.fetch('PATH')
    @stand_in_dir = Dir.mktmpdir('cli-test-stand-ins')
    @shim_log = File.join(@stand_in_dir, 'invocations.log')
    @stub_log = File.join(@stand_in_dir, 'served.log')
    @stub_refusals = File.join(@stand_in_dir, 'refusals.log')
    write_command_shims
    install_serving_stubs
    ENV['PATH'] = "#{@stand_in_dir}#{File::PATH_SEPARATOR}#{@saved_path}"
  end

  # A name in both lists asks for a command that is refused and also
  # answered. Whichever list won would win silently, and the suite would
  # go on passing either way, so this is refused rather than resolved.
  def refuse_overlapping_stand_ins
    overlap = shimmed_commands & served_commands.keys
    return if overlap.empty?

    flunk "#{self.class} names #{overlap.join(', ')} as both shimmed and served; " \
          'a command is either refused or answered, never both'
  end

  def write_command_shims
    shimmed_commands.each do |command|
      shim_path = File.join(@stand_in_dir, command)
      File.write(shim_path, <<~SCRIPT)
        #!/bin/sh
        echo "#{command} $*" >> "#{@shim_log}"
        echo "#{command}: intercepted by test shim (live call refused)" >&2
        exit 1
      SCRIPT
      File.chmod(0o755, shim_path)
    end
  end

  # Copied rather than symlinked: a stub that resolves its own directory
  # from $0 would find the source tree instead of the run's own
  # directory, and the copy is what makes the mode bit this run's to set.
  def install_serving_stubs
    return if served_commands.empty?

    ENV[CLI_STUB_LOG_ENV] = @stub_log
    ENV[CLI_STUB_REFUSALS_ENV] = @stub_refusals
    served_commands.each do |command, program|
      stub_path = File.join(@stand_in_dir, command)
      FileUtils.cp(program, stub_path)
      File.chmod(0o755, stub_path)
    end
  end

  def remove_path_stand_ins
    return unless @stand_in_dir

    ENV['PATH'] = @saved_path
    @shim_hits = read_stand_in_log(@shim_log)
    @stub_refusal_hits = read_stand_in_log(@stub_refusals)
    FileUtils.remove_entry(@stand_in_dir)
    # All four are nilled together: they name paths inside a directory
    # that no longer exists, and a half-cleared set invites a later read
    # of one that looks live.
    @stand_in_dir = @stub_log = @shim_log = @stub_refusals = nil
  end

  def read_stand_in_log(path)
    File.exist?(path) ? File.read(path) : nil
  end
end
