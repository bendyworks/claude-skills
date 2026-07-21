#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for the shared CLI test scaffolding itself: the env
# scrub/restore contract every CLI suite inherits.
# Run: ruby test/cli_test_case_test.rb

require_relative 'cli_test_case'

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

class CliTestCaseTest < Minitest::Test
  SENTINEL_KEYS = %w[POSIXLY_CORRECT CLI_TEST_CASE_SENTINEL].freeze

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
end
