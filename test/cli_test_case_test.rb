#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for the shared CLI test scaffolding itself.
# Run: ruby test/cli_test_case_test.rb

require_relative 'cli_test_case'

class CliTestCaseTest < Minitest::Test
  def test_teardown_flunks_when_a_subclass_setup_never_ran
    # A subclass overriding setup without super never saves the env
    # snapshot. The guard must name that mistake, not die on nil.
    instance = Class.new(CliTestCase).new('example')
    error = assert_raises(Minitest::Assertion) { instance.teardown }
    assert_match(/setup did not run/, error.message)
  end
end
