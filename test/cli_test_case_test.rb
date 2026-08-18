#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for the shared CLI test scaffolding itself: the env
# scrub/restore contract every CLI suite inherits.
# Run: ruby test/cli_test_case_test.rb

require_relative 'cli_test_case'
require 'open3'

# Probe subclasses observe the scaffolding from inside a real Minitest
# run. Their test methods only record what they see -- the assertions
# live in CliTestCaseTest below, which runs each probe explicitly and
# inspects the recording. Autorun gives each probe class an extra pass
# at process exit; recording without asserting keeps that pass green.

class ScrubProbeCase < CliTestCase
  attr_reader :seen

  def extra_scrubbed_env_keys
    %w[CLI_TEST_CASE_SENTINEL]
  end

  def test_record_env_visibility
    @seen = {
      base_key_present: ENV.key?('POSIXLY_CORRECT'),
      extra_key_present: ENV.key?('CLI_TEST_CASE_SENTINEL')
    }
  end
end

class MutatingProbeCase < CliTestCase
  def test_mutate_scrubbed_key
    ENV['POSIXLY_CORRECT'] = 'mutated-by-test'
  end
end

# The mistake class the scrub must survive: both user-level hooks
# overridden without super.
class SkipSuperProbeCase < CliTestCase
  attr_reader :seen

  def setup; end

  def teardown; end

  def test_record_env_visibility
    @seen = { base_key_present: ENV.key?('POSIXLY_CORRECT') }
  end
end

# The variables that aim git at another repository are scrubbed for
# every CLI suite, not only the ones that build a repository of their
# own. A CLI shelling out to git inherits the test process's environment,
# and `git -C <dir>` does not override an inherited GIT_DIR -- so a test
# driving such a CLI without a fixture's neutralized environment operates
# on whatever repository the developer's shell happens to name.
class GitLocationProbeCase < CliTestCase
  attr_reader :seen

  def test_record_env_visibility
    @seen = CliTestCase::GIT_LOCATION_ENV_KEYS.to_h { |key| [key, ENV.key?(key)] }
  end
end

# A copy-paste override that re-lists a base key must not defeat the
# restore.
class DuplicateKeyProbeCase < CliTestCase
  attr_reader :seen

  def extra_scrubbed_env_keys
    %w[POSIXLY_CORRECT]
  end

  def test_record_env_visibility
    @seen = { base_key_present: ENV.key?('POSIXLY_CORRECT') }
  end
end

# Exercises the command shim: a shimmed command name resolving through
# PATH must hit the shim, never a real executable. Only the outer
# contract test arms the invocation, so autorun's extra pass over this
# class stays green.
class ShimProbeCase < CliTestCase
  class << self
    attr_accessor :armed
  end

  def shimmed_commands
    %w[cli-test-case-fake-command]
  end

  def test_invoke_shimmed_command_when_armed
    return unless self.class.armed

    system('cli-test-case-fake-command', out: File::NULL, err: File::NULL)
  end
end

# A shim name the installer cannot write (slash inside a command name)
# makes before_setup raise mid-install; the scaffolding must fail that
# test alone, not corrupt PATH for the rest of the process. Armed by
# the outer contract test only, so autorun's extra pass stays green.
class BrokenShimProbeCase < CliTestCase
  class << self
    attr_accessor :armed
  end

  def shimmed_commands
    self.class.armed ? %w[bad/shim-name] : []
  end

  def test_body_never_reached_when_install_raises; end
end

# The guard the base runs ahead of every dispatch. A per-CLI safety
# check hand-rolled inside run_cli is one the next suite copies by hand
# and drifts; declaring it as a hook keeps one runner responsible for
# calling it. Armed by the outer contract test only.
class GuardProbeCase < CliTestCase
  class << self
    attr_accessor :armed
  end

  attr_reader :dispatched

  def guard_cli_invocation(argv)
    flunk "guard refused #{argv.inspect}" if self.class.armed
  end

  def dispatch_cli(argv)
    @dispatched = argv
  end

  def test_run_the_cli
    run_cli(%w[some args])
  end
end

# Overriding run_cli puts a subclass back outside the base's guard,
# which is the bypass the two hooks exist to prevent -- and it is a
# silent one, since the suite goes on passing with nothing checked.
# The override itself is what the outer contract test arms, defined on
# this class for the length of that test alone: a permanent one would
# fail every autorun pass over this file, which is what a working
# refusal looks like from the outside.
class RunCliOverrideProbeCase < CliTestCase
  def dispatch_cli(argv); end

  def test_body_never_reached_when_the_override_is_refused; end
end

class MissingDispatchProbeCase < CliTestCase
  class << self
    attr_accessor :armed
  end

  def test_run_without_a_dispatch_hook
    run_cli([]) if self.class.armed
  end
end

# A CLI that refuses: something on each stream and a status that is not
# 1, which is the shape abort_message alone cannot describe.
class AbortProbeCase < CliTestCase
  attr_reader :seen

  def dispatch_cli(argv)
    puts "usage: #{argv.first}"
    warn "probe: refusing #{argv.first}"
    exit 3
  end

  def test_record_abort_result
    @seen = abort_result(%w[bogus])
  end
end

# Kernel#abort carries its message on the exception and exits 1, which
# is the case abort_message was written for and must keep answering
# now that it is rebuilt on abort_result.
class AbortMessageProbeCase < CliTestCase
  attr_reader :seen

  def dispatch_cli(argv)
    abort "probe: cannot #{argv.first}"
  end

  def test_record_abort_message
    @seen = { message: abort_message(%w[bogus]), status: abort_result(%w[bogus]).status }
  end
end

# Little programs the serving probes install, written once for this
# file and removed when the process ends. A probe names its program by
# path rather than by body, because that is what the seam takes: it
# copies a real executable onto PATH, which is what lets the gh stub be
# run and read on its own as well as through a suite.
module ProbePrograms
  DIR = Dir.mktmpdir('cli-test-case-probe-programs')
  Minitest.after_run { FileUtils.remove_entry(DIR) if File.directory?(DIR) }

  def self.write(name, body)
    path = File.join(DIR, name)
    File.write(path, body)
    File.chmod(0o755, path)
    path
  end
end

# Honors the two halves of the serving protocol: every invocation is
# logged, and one it does not recognize is refused rather than answered
# with a plausible nothing. A stub that answers an unrecognized call
# with an empty result teaches the suite that the CLI asked a question
# it never asked.
SERVING_PROGRAM = ProbePrograms.write('cli-test-case-served', <<~SCRIPT)
  #!/bin/sh
  echo "cli-test-case-served $*" >> "$CLI_STUB_LOG"
  if [ "${1:-}" = "unhandled" ]; then
    echo "cli-test-case-served: unhandled: $*" >> "$CLI_STUB_REFUSALS"
    exit 1
  fi
  echo "served $*"
SCRIPT

# Shims nothing, so its passing is also what proves the installer does
# not bail out on an empty shim list and leave a serving-only suite
# with no stub on PATH at all.
class ServeProbeCase < CliTestCase
  attr_reader :seen

  def served_commands
    { 'cli-test-case-served' => SERVING_PROGRAM }
  end

  def test_record_a_served_call
    out, status = Open3.capture2('cli-test-case-served', 'pr', 'list', '--head', 'x')
    @seen = { stdout: out.strip, ok: status.success?, log: served_invocations }
  end
end

# Serving and refusing side by side: the served call must come back
# answered and leave the run passing, while the shimmed one still
# flunks it. Armed by the outer contract test only, so autorun's extra
# pass stays green.
class ServeAndShimProbeCase < CliTestCase
  class << self
    attr_accessor :armed
  end

  attr_reader :seen

  def shimmed_commands
    %w[cli-test-case-fake-command]
  end

  def served_commands
    { 'cli-test-case-served' => SERVING_PROGRAM }
  end

  def test_call_the_served_command_and_maybe_the_shimmed_one
    out, status = Open3.capture2('cli-test-case-served', 'ok')
    @seen = { stdout: out.strip, ok: status.success? }
    system('cli-test-case-fake-command', out: File::NULL, err: File::NULL) if self.class.armed
  end
end

# A stub asked something it does not serve. The run must fail: the
# alternative is a suite that goes green while the CLI asked a question
# nothing answered.
class ServedRefusalProbeCase < CliTestCase
  class << self
    attr_accessor :armed
  end

  def served_commands
    { 'cli-test-case-served' => SERVING_PROGRAM }
  end

  def test_ask_the_stub_something_it_does_not_serve
    Open3.capture2e('cli-test-case-served', 'unhandled') if self.class.armed
  end
end

# One name in both lists is a contradiction -- refuse this command, and
# also answer it -- and whichever list won would be silent. Armed by the
# outer contract test only.
class OverlapProbeCase < CliTestCase
  class << self
    attr_accessor :armed
  end

  def shimmed_commands
    self.class.armed ? %w[cli-test-case-served] : []
  end

  def served_commands
    { 'cli-test-case-served' => SERVING_PROGRAM }
  end

  def test_body_never_reached_when_the_lists_overlap; end
end

class CliTestCaseTest < Minitest::Test
  SENTINEL_KEYS = (%w[POSIXLY_CORRECT CLI_TEST_CASE_SENTINEL] +
                   CliTestCase::GIT_LOCATION_ENV_KEYS).freeze

  def setup
    @saved_sentinels = SENTINEL_KEYS.to_h { |key| [key, ENV[key]] }
  end

  def teardown
    @saved_sentinels.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

  def run_probe(klass, test_name)
    instance = klass.new(test_name.to_s)
    result = instance.run
    assert result.passed?, "probe #{klass}##{test_name} failed: #{result.failure&.message}"
    instance
  end

  def test_scrub_hides_base_and_extra_keys_during_the_test
    ENV['POSIXLY_CORRECT'] = '1'
    ENV['CLI_TEST_CASE_SENTINEL'] = 'machine-value'
    probe = run_probe(ScrubProbeCase, :test_record_env_visibility)
    refute probe.seen[:base_key_present], 'POSIXLY_CORRECT leaked into the test body'
    refute probe.seen[:extra_key_present], 'subclass extra key leaked into the test body'
    assert_equal '1', ENV['POSIXLY_CORRECT']
    assert_equal 'machine-value', ENV['CLI_TEST_CASE_SENTINEL']
  end

  def test_restore_wins_over_a_mid_test_mutation
    ENV['POSIXLY_CORRECT'] = '1'
    run_probe(MutatingProbeCase, :test_mutate_scrubbed_key)
    assert_equal '1', ENV['POSIXLY_CORRECT']
  end

  def test_originally_unset_key_is_restored_to_unset
    ENV.delete('POSIXLY_CORRECT')
    run_probe(MutatingProbeCase, :test_mutate_scrubbed_key)
    refute ENV.key?('POSIXLY_CORRECT'), 'POSIXLY_CORRECT should be unset again after the run'
  end

  def test_scrub_survives_subclass_hooks_that_skip_super
    ENV['POSIXLY_CORRECT'] = '1'
    probe = run_probe(SkipSuperProbeCase, :test_record_env_visibility)
    refute probe.seen[:base_key_present], 'scrub must not depend on subclass hooks calling super'
    assert_equal '1', ENV['POSIXLY_CORRECT']
  end

  def test_duplicate_scrub_keys_still_restore_the_original
    ENV['POSIXLY_CORRECT'] = '1'
    probe = run_probe(DuplicateKeyProbeCase, :test_record_env_visibility)
    refute probe.seen[:base_key_present], 'duplicated key must still be scrubbed'
    assert_equal '1', ENV['POSIXLY_CORRECT']
  end

  # Scrubbed for every CLI suite rather than only where a fixture's
  # neutralized environment reaches, because the hole is the tests that
  # drive a git-shelling CLI without building a repository at all --
  # argument handling, a usage error, a refusal. Those still reach far
  # enough into the CLI for it to run git, and an ambient GIT_DIR points
  # that git at the developer's own clone.
  def test_git_location_keys_are_scrubbed_and_then_restored
    ambient = CliTestCase::GIT_LOCATION_ENV_KEYS.to_h { |key| [key, "ambient-#{key}"] }
    ambient.each { |key, value| ENV[key] = value }

    probe = run_probe(GitLocationProbeCase, :test_record_env_visibility)

    leaked = probe.seen.select { |_key, present| present }.keys
    assert_empty leaked, 'git location variables leaked into the test body'
    assert_equal ambient, CliTestCase::GIT_LOCATION_ENV_KEYS.to_h { |key| [key, ENV[key]] }
  end

  def test_invoking_a_shimmed_command_flunks_the_test
    ShimProbeCase.armed = true
    result = ShimProbeCase.new('test_invoke_shimmed_command_when_armed').run
    refute result.passed?, 'invoking a shimmed command must flunk the test'
    assert_match(/intercepted by test shim/, result.failure.message)
  ensure
    ShimProbeCase.armed = false
  end

  def test_shim_is_gone_from_path_after_the_run
    path_before = ENV.fetch('PATH')
    ShimProbeCase.armed = false
    result = ShimProbeCase.new('test_invoke_shimmed_command_when_armed').run
    assert result.passed?, "unarmed probe failed: #{result.failure&.message}"
    assert_equal path_before, ENV.fetch('PATH', nil),
                 'PATH must be restored to its exact pre-test value'
    assert_nil system('cli-test-case-fake-command', out: File::NULL, err: File::NULL),
               'shimmed command must not resolve once the test is over'
  end

  def test_the_guard_runs_before_the_dispatch_and_stops_it
    GuardProbeCase.armed = true
    probe = GuardProbeCase.new('test_run_the_cli')
    result = probe.run

    refute result.passed?, 'a refusing guard must fail the test'
    assert_match(/guard refused/, result.failure.message)
    assert_nil probe.dispatched, 'the CLI was dispatched after its guard refused'
  ensure
    GuardProbeCase.armed = false
  end

  def test_a_passing_guard_dispatches_the_argv_unchanged
    GuardProbeCase.armed = false
    probe = run_probe(GuardProbeCase, :test_run_the_cli)

    assert_equal %w[some args], probe.dispatched
  end

  # Refused rather than merely discouraged: an overriding subclass looks
  # exactly like a working one, and what it drops is the safety check.
  def test_a_subclass_that_overrides_run_cli_is_refused
    RunCliOverrideProbeCase.class_eval do
      def run_cli(argv)
        dispatch_cli(argv)
      end
    end
    result = RunCliOverrideProbeCase.new('test_body_never_reached_when_the_override_is_refused').run

    refute result.passed?, 'overriding run_cli must fail rather than bypass the guard'
    assert_match(/dispatch_cli/, result.failure.message)
  ensure
    RunCliOverrideProbeCase.send(:remove_method, :run_cli)
  end

  def test_a_subclass_with_no_dispatch_hook_says_which_hook_is_missing
    MissingDispatchProbeCase.armed = true
    result = MissingDispatchProbeCase.new('test_run_without_a_dispatch_hook').run

    refute result.passed?
    assert_match(/dispatch_cli/, result.failure.message)
  ensure
    MissingDispatchProbeCase.armed = false
  end

  def test_abort_result_carries_the_status_and_both_streams
    probe = run_probe(AbortProbeCase, :test_record_abort_result)

    assert_equal 3, probe.seen.status
    assert_includes probe.seen.stdout, 'usage: bogus'
    assert_includes probe.seen.stderr, 'probe: refusing bogus'
  end

  def test_abort_message_still_answers_with_the_abort_message_alone
    probe = run_probe(AbortMessageProbeCase, :test_record_abort_message)

    assert_equal 'probe: cannot bogus', probe.seen[:message]
    assert_equal 1, probe.seen[:status]
  end

  def test_shim_install_failure_leaves_path_intact
    path_before = ENV.fetch('PATH')
    BrokenShimProbeCase.armed = true
    result = BrokenShimProbeCase.new('test_body_never_reached_when_install_raises').run
    refute result.passed?, 'a broken shim install must fail the probe test'
    assert_equal path_before, ENV.fetch('PATH', nil),
                 'a mid-install failure must not corrupt PATH for later tests'
  ensure
    BrokenShimProbeCase.armed = false
  end

  def test_a_serving_only_subclass_still_gets_its_stub_on_path
    probe = run_probe(ServeProbeCase, :test_record_a_served_call)

    assert probe.seen[:ok], 'the served command did not resolve or did not succeed'
    assert_equal 'served pr list --head x', probe.seen[:stdout]
  end

  def test_served_invocations_are_readable_during_the_test
    probe = run_probe(ServeProbeCase, :test_record_a_served_call)

    assert_equal ['cli-test-case-served pr list --head x'], probe.seen[:log]
  end

  def test_a_served_call_does_not_flunk_a_run_that_also_shims
    ServeAndShimProbeCase.armed = false
    probe = run_probe(ServeAndShimProbeCase,
                      :test_call_the_served_command_and_maybe_the_shimmed_one)

    assert probe.seen[:ok], 'the served command must be answered, not refused'
    assert_equal 'served ok', probe.seen[:stdout]
  end

  def test_a_shimmed_call_still_flunks_a_run_that_also_serves
    ServeAndShimProbeCase.armed = true
    result = ServeAndShimProbeCase.new(
      'test_call_the_served_command_and_maybe_the_shimmed_one'
    ).run

    refute result.passed?, 'a shimmed command must still flunk when a stub is serving too'
    assert_match(/intercepted by test shim/, result.failure.message)
  ensure
    ServeAndShimProbeCase.armed = false
  end

  def test_an_unrecognized_served_invocation_flunks_the_test
    ServedRefusalProbeCase.armed = true
    result = ServedRefusalProbeCase.new('test_ask_the_stub_something_it_does_not_serve').run

    refute result.passed?, 'a stub refusal must flunk the test that caused it'
    assert_match(/refused by test stub/, result.failure.message)
  ensure
    ServedRefusalProbeCase.armed = false
  end

  def test_naming_one_command_in_both_lists_is_refused
    OverlapProbeCase.armed = true
    result = OverlapProbeCase.new('test_body_never_reached_when_the_lists_overlap').run

    refute result.passed?, 'a command named as both shimmed and served must be refused'
    assert_match(/both shimmed and served/, result.failure.message)
  ensure
    OverlapProbeCase.armed = false
  end

  def test_the_stub_is_gone_from_path_after_a_serving_only_run
    path_before = ENV.fetch('PATH')
    run_probe(ServeProbeCase, :test_record_a_served_call)

    assert_equal path_before, ENV.fetch('PATH', nil),
                 'PATH must be restored to its exact pre-test value'
    assert_nil system('cli-test-case-served', out: File::NULL, err: File::NULL),
               'served command must not resolve once the test is over'
  end

end
