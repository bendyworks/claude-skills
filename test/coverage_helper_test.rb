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

  def test_noop_when_coverage_set_but_empty
    out, err, status = Open3.capture3(
      { 'COVERAGE' => '' },
      RbConfig.ruby, '-e', "require #{HELPER.dump}; print defined?(SimpleCov).inspect",
      chdir: REPO_ROOT
    )
    assert status.success?, "helper subprocess failed: #{err}"
    assert_equal 'nil', out, 'an empty COVERAGE value must not turn coverage on'
  end

  def test_abort_names_install_hint_when_gem_unfindable
    Dir.mktmpdir('no-gems') do |empty_gem_dir|
      _out, err, status = Open3.capture3(
        { 'COVERAGE' => '1', 'GEM_HOME' => empty_gem_dir, 'GEM_PATH' => empty_gem_dir },
        RbConfig.ruby, '-e', "require #{HELPER.dump}",
        chdir: REPO_ROOT
      )
      assert_equal 1, status.exitstatus, 'the missing-gem path must abort (exit 1), not crash'
      # The version is hardcoded on purpose: a bump to the pins in
      # test/coverage_helper.rb and .github/workflows/checks.yml must
      # consciously touch this tripwire too, so the three sites cannot
      # drift apart silently.
      assert_includes err, 'gem install simplecov -v 0.22.0'
    end
  end

  # Guards the two settings CI cannot: SimpleCov.root resolution
  # (CI always runs from the repo root, so a regression to
  # CWD-relative roots stays green there) and the widened merge
  # window (CI finishes inside the 600s default). Process.exit! skips
  # SimpleCov's at_exit, so the probe writes no artifact and leaves
  # no resultset entry behind.
  def test_pins_root_and_merge_window_from_any_cwd
    out, err, status = Open3.capture3(
      { 'COVERAGE' => '1' },
      RbConfig.ruby, '-e',
      "require #{HELPER.dump}; print [SimpleCov.root, SimpleCov.merge_timeout].inspect; " \
      '$stdout.flush; Process.exit!(0)',
      chdir: File.join(REPO_ROOT, 'test')
    )
    skip 'simplecov not installed in this environment' if err.include?('gem install simplecov')
    assert status.success?, "helper subprocess failed: #{err}"
    assert_equal [REPO_ROOT, 3600].inspect, out
  end
end
