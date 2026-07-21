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
end
