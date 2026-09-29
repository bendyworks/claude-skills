#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for scripts/park-claude-md.sh, which parks the user-level
# CLAUDE.md for the length of a dry-run batch. Every test points the
# script at a throwaway config directory through CLAUDE_CONFIG_DIR, and
# setup refuses to run unless that directory sits under the test's own
# temporary directory, so no test can park the real file. Coverage
# records nothing here: the project measures only bin/*.
# Run: ruby test/park_claude_md_test.rb

require_relative 'cli_test_case'
require 'open3'
require 'tmpdir'

class ParkClaudeMdTest < Minitest::Test
  SCRIPT = File.expand_path('../scripts/park-claude-md.sh', __dir__)
  ORIGINAL = "# user rules\nalways say hello\n"

  def setup
    @tmp = File.realpath(Dir.mktmpdir('park-claude-md-test'))
    @config = File.join(@tmp, 'config')
    Dir.mkdir(@config)
    flunk "config dir #{@config} is outside #{@tmp}" unless @config.start_with?("#{@tmp}/")
    @live = File.join(@config, 'CLAUDE.md')
    @lock = File.join(@config, 'CLAUDE.md.park-lock')
    File.write(@live, ORIGINAL)
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def env
    { 'CLAUDE_CONFIG_DIR' => @config, 'CLAUDE_MD_PARK_HOLDER' => nil }
  end

  def park(*args)
    Open3.capture3(env, 'bash', SCRIPT, *args)
  end

  def test_runs_the_command_with_the_file_parked_and_restores_it
    probe = File.join(@tmp, 'probe')
    _out, err, status = park('--', 'sh', '-c', "ls '#{@config}' > '#{probe}'; test -e '#{@live}' && echo present >> '#{probe}'; true")

    assert status.success?, err
    refute_includes File.read(probe), 'present', 'CLAUDE.md was visible while parked'
    assert_equal ORIGINAL, File.read(@live)
    refute File.exist?(@lock), 'lock left behind after a clean run'
  end

  def test_exits_with_the_command_status
    _out, _err, status = park('--', 'sh', '-c', 'exit 7')

    assert_equal 7, status.exitstatus
    assert_equal ORIGINAL, File.read(@live)
    refute File.exist?(@lock)
  end

  def test_passes_every_argument_through_unchanged
    args = ['two words', "it's", '$HOME', '--', '*', '']
    out, err, status = park('--', 'ruby', '-e', 'print ARGV.inspect', *args)

    assert status.success?, err
    assert_equal args.inspect, out
  end

  def test_refuses_without_the_separator_and_parks_nothing
    _out, err, status = park('true')

    assert_equal 2, status.exitstatus
    assert_match(/usage/, err)
    assert_equal ORIGINAL, File.read(@live)
    refute File.exist?(@lock)
  end
end
