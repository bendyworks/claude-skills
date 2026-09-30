#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for the change-highlights skill's browser-discovery helper,
# find_chrome.sh, which the skill's shell scripts source.
# Candidate browsers are passed explicitly or placed on PATH as fakes,
# so the results never depend on which browsers the machine has.
# Coverage records nothing here: the project measures only bin/*.
# Run: ruby test/change_highlights_builder_test.rb

require_relative 'cli_test_case'
require 'erb'
require 'json'
require 'open3'
require 'tmpdir'

class FindChromeTest < Minitest::Test
  HELPER = File.expand_path('../skills/change-highlights/find_chrome.sh', __dir__)

  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def fake_browser(name)
    path = File.join(@dir, name)
    File.write(path, "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, path)
    path
  end

  def find_chrome(*candidates, env: {})
    script = %(. "$1"; shift; CHROME_CANDIDATES=("$@"); find_chrome)
    Open3.capture3({ 'CHROME' => nil }.merge(env), 'bash', '-c', script, 'bash', HELPER, *candidates)
  end

  def test_returns_the_first_executable_candidate
    browser = fake_browser('cs-fake-browser')
    out, _err, status = find_chrome(File.join(@dir, 'missing'), browser)

    assert_predicate status, :success?
    assert_equal browser, out.chomp
  end

  def test_finds_a_candidate_named_on_path
    fake_browser('brave-browser')
    out, _err, status = find_chrome('no-such-browser', 'brave-browser', env: { 'PATH' => "#{@dir}:/usr/bin:/bin" })

    assert_predicate status, :success?
    assert_equal 'brave-browser', out.chomp
  end

  def test_chrome_env_wins_over_candidates
    chosen = fake_browser('chosen')
    out, _err, status = find_chrome(fake_browser('other'), env: { 'CHROME' => chosen })

    assert_predicate status, :success?
    assert_equal chosen, out.chomp
  end

  def test_a_chrome_env_that_is_not_executable_fails_instead_of_falling_back
    plain_file = File.join(@dir, 'not-a-browser')
    File.write(plain_file, "#!/bin/sh\n")
    File.chmod(0o644, plain_file)
    out, err, status = find_chrome(fake_browser('other'), env: { 'CHROME' => plain_file })

    refute_predicate status, :success?
    assert_empty out
    assert_match(/CHROME is set but not executable/, err)
  end

  # "/Applications/Google Chrome.app" is a directory; the runnable file is
  # inside it.
  def test_a_chrome_env_naming_a_directory_is_rejected
    _out, err, status = find_chrome(fake_browser('other'), env: { 'CHROME' => @dir })

    refute_predicate status, :success?
    assert_match(/CHROME is set but not executable/, err)
  end

  # A bare name is looked up on PATH when the browser runs, so a file of
  # that name in the working directory does not make it runnable.
  def test_a_bare_name_found_only_in_the_working_directory_is_skipped
    fake_browser('cs-fake-browser')
    script = %(. "$1"; CHROME_CANDIDATES=(cs-fake-browser); cd "$2" && find_chrome)
    _out, err, status = Open3.capture3({ 'CHROME' => nil, 'PATH' => '/usr/bin:/bin' }, 'bash', '-c', script, 'bash', HELPER, @dir)

    refute_predicate status, :success?
    assert_match(/set CHROME=/, err)
  end

  # The browser runs as a program, so a shell function of the same name
  # does not count.
  def test_a_shell_function_named_like_a_candidate_is_not_a_browser
    script = %(. "$1"; cs-fake-browser() { :; }; CHROME_CANDIDATES=(cs-fake-browser); find_chrome)
    _out, err, status = Open3.capture3({ 'CHROME' => nil, 'PATH' => '/usr/bin:/bin' }, 'bash', '-c', script, 'bash', HELPER)

    refute_predicate status, :success?
    assert_match(/set CHROME=/, err)
  end

  def test_no_browser_found_fails_with_a_hint
    out, err, status = find_chrome(File.join(@dir, 'missing'), 'no-such-browser')

    refute_predicate status, :success?
    assert_empty out
    assert_match(/set CHROME=/, err)
  end
end
