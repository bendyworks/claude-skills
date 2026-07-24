#!/usr/bin/env ruby
# frozen_string_literal: true

# Contract tests for test/coverage_helper.rb, the opt-in SimpleCov
# bootstrap. Each test drives the helper in a subprocess so the
# COVERAGE guard and the missing-gem abort can be exercised without
# disturbing this process's own (possibly coverage-measuring) run.
# Run: ruby test/coverage_helper_test.rb

require_relative 'cli_test_case'

require 'open3'
require 'tmpdir'

class CoverageHelperTest < Minitest::Test
  REPO_ROOT = File.expand_path('..', __dir__)
  HELPER = File.join(REPO_ROOT, 'test', 'coverage_helper.rb')

  def test_noop_when_coverage_unset
    out, err, status = Open3.capture3(
      { 'COVERAGE' => nil },
      RbConfig.ruby, '-e', "require #{HELPER.dump}; print defined?(SimpleCov).inspect",
      chdir: REPO_ROOT
    )
    assert status.success?, "helper subprocess failed: #{err}"
    assert_equal 'nil', out, 'SimpleCov must not load when COVERAGE is unset'
  end

  def test_abort_names_install_hint_when_gem_unfindable
    Dir.mktmpdir('no-gems') do |empty_gem_dir|
      _out, err, status = Open3.capture3(
        { 'COVERAGE' => '1', 'GEM_HOME' => empty_gem_dir, 'GEM_PATH' => empty_gem_dir },
        RbConfig.ruby, '-e', "require #{HELPER.dump}",
        chdir: REPO_ROOT
      )
      refute status.success?, 'helper must abort when COVERAGE is set but simplecov is unfindable'
      assert_includes err, 'gem install simplecov -v 0.22.0'
    end
  end
end
