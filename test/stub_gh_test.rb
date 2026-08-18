#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for the canned GitHub CLI under test/fixtures/stub_gh.rb.
# Run: ruby test/stub_gh_test.rb
#
# The stub is the only thing standing between the sweep's forge tests
# and a real network call, and every verdict those tests assert is
# reached from what it says. A stub that answered a question it does
# not know -- an empty array for a repository it has no data for, a
# null for a field a record does not carry -- would hand the sweep the
# exact evidence shape that means "no pull request", and the suite
# would grade a wrong verdict as right. So its refusals are tested as
# closely as its answers.
#
# It is run here as a program rather than loaded, which is how the
# sweep reaches it: its argument handling, its exit statuses, and the
# two logs it writes are the whole of its contract, and none of them
# are observable from a method call.

require_relative 'coverage_helper'

require 'json'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'

class StubGhTest < Minitest::Test
  STUB = File.expand_path('fixtures/stub_gh.rb', __dir__)

  REPO = 'github.com/fixture/repo'
  UPSTREAM = 'github.com/fixture/upstream'

  MERGED = { 'number' => 101, 'state' => 'MERGED', 'headRefName' => 'a-landed',
             'headRefOid' => 'a' * 40, 'baseRefName' => 'main',
             'isCrossRepository' => false }.freeze
  OPENED = { 'number' => 102, 'state' => 'OPEN', 'headRefName' => 'b-open',
             'headRefOid' => 'b' * 40, 'baseRefName' => 'main',
             'isCrossRepository' => false }.freeze
  FORKED = { 'number' => 103, 'state' => 'MERGED', 'headRefName' => 'a-landed',
             'headRefOid' => 'c' * 40, 'baseRefName' => 'main',
             'isCrossRepository' => true }.freeze

  DATA = { REPO => [MERGED, OPENED, FORKED], UPSTREAM => [] }.freeze

  FIELDS = 'number,state,headRefName,headRefOid,baseRefName,isCrossRepository'

  def setup
    @dir = Dir.mktmpdir('stub-gh-test')
    @data_path = File.join(@dir, 'prs.json')
    File.write(@data_path, JSON.generate(DATA))
    @log = File.join(@dir, 'served.log')
    @refusals = File.join(@dir, 'refusals.log')
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  # Result of one run: the parsed stdout where there is any, the raw
  # streams, the exit status, and whatever the two logs recorded.
  Run = Struct.new(:stdout, :stderr, :status, :log, :refusals) do
    def ok?
      status.zero?
    end

    def json
      JSON.parse(stdout)
    end
  end

  def stub_env(overrides = {})
    { 'STUB_GH_PRS' => @data_path,
      'CLI_STUB_LOG' => @log,
      'CLI_STUB_REFUSALS' => @refusals }.merge(overrides)
  end

  def run_stub(*argv, env: {})
    out, err, status = Open3.capture3(stub_env(env), STUB, *argv)
    Run.new(out, err, status.exitstatus, read_log(@log), read_log(@refusals))
  end

  def read_log(path)
    File.exist?(path) ? File.readlines(path).map(&:chomp) : []
  end

  def list(*argv, env: {})
    run_stub('pr', 'list', '--repo', REPO, '--json', FIELDS, '--state', 'all', *argv, env: env)
  end

  def test_a_matching_query_answers_with_the_records_for_that_branch
    result = list('--head', 'a-landed')

    assert result.ok?, "stub failed: #{result.stderr}"
    assert_equal [101, 103], result.json.map { |record| record['number'] }
    assert_empty result.refusals
  end

  def test_head_matches_on_branch_name_alone_so_a_forks_request_comes_back_too
    forked = list('--head', 'a-landed').json.find { |record| record['number'] == 103 }

    assert forked, 'the cross-repository pull request must not be filtered out by --head'
    assert forked['isCrossRepository'], 'the sweep has to be able to see that it came from a fork'
  end

  def test_a_query_matching_nothing_is_an_empty_array_and_a_clean_exit
    result = list('--head', 'never-existed')

    assert result.ok?, "a no-match must not be a failure: #{result.stderr}"
    assert_empty result.json
    assert_empty result.refusals, 'a no-match is an answer, not a refusal'
  end

  def test_state_defaults_to_open_the_way_the_real_client_does
    result = run_stub('pr', 'list', '--repo', REPO, '--json', FIELDS)

    assert result.ok?, "stub failed: #{result.stderr}"
    assert_equal [102], result.json.map { |record| record['number'] },
                 'omitting --state must hide merged pull requests, as it does for real'
  end

  def test_limit_truncates_in_silence
    result = list('--limit', '1')

    assert result.ok?, "stub failed: #{result.stderr}"
    assert_equal 1, result.json.length
    assert_empty result.stderr, 'the real client says nothing when it truncates'
  end

  def test_only_the_requested_fields_come_back
    record = list('--head', 'b-open').json.fetch(0)

    assert_equal %w[number state], run_stub('pr', 'list', '--repo', REPO, '--state', 'all',
                                            '--head', 'b-open', '--json',
                                            'number,state').json.fetch(0).keys
    assert_equal FIELDS.split(','), record.keys
  end

  def test_a_configured_failure_is_a_message_and_a_nonzero_exit
    result = list('--head', 'a-landed', env: { 'STUB_GH_FAIL' => '1' })

    refute result.ok?, 'a configured failure must not exit 0'
    assert_match(/error connecting/, result.stderr)
    assert_empty result.stdout, 'a failure must not also print a result the sweep could parse'
    assert_empty result.refusals, 'a failure the sweep must degrade on is served, not refused'
  end

  def test_every_invocation_is_logged_including_a_refused_one
    list('--head', 'a-landed')
    run_stub('pr', 'view', '1')

    assert_equal ["gh pr list --repo #{REPO} --json #{FIELDS} --state all --head a-landed",
                  'gh pr view 1'],
                 @log.then { read_log(_1) }
  end

  def refusal_case(*argv, env: {})
    result = run_stub(*argv, env: env)

    refute result.ok?, "expected a refusal, got a clean exit: #{result.stdout}"
    refute_empty result.refusals, 'a refusal must be recorded where the seam reads it'
    result
  end

  def test_an_unserved_subcommand_is_refused
    result = refusal_case('pr', 'view', '1')

    assert_match(/unserved command: pr view/, result.refusals.join("\n"))
  end

  def test_an_unserved_flag_is_refused_rather_than_skipped
    result = refusal_case('pr', 'list', '--repo', REPO, '--json', FIELDS, '--author', 'someone')

    assert_match(/unserved flag: --author/, result.refusals.join("\n"))
  end

  def test_a_flag_given_no_value_is_refused
    result = refusal_case('pr', 'list', '--repo', REPO, '--json', FIELDS, '--head')

    assert_match(/--head given no value/, result.refusals.join("\n"))
  end

  def test_a_listing_without_json_is_refused
    result = refusal_case('pr', 'list', '--repo', REPO)

    assert_match(/without --json/, result.refusals.join("\n"))
  end

  def test_a_listing_without_repo_is_refused
    result = refusal_case('pr', 'list', '--json', FIELDS)

    assert_match(/without --repo/, result.refusals.join("\n"))
  end

  def test_a_repo_the_data_does_not_describe_is_refused_rather_than_answered_empty
    result = refusal_case('pr', 'list', '--repo', 'github.com/somebody/else',
                          '--json', FIELDS, '--state', 'all')

    assert_match(/no data for repo github\.com\/somebody\/else/, result.refusals.join("\n"))
  end

  def test_a_repo_the_data_describes_as_empty_is_answered_empty
    result = run_stub('pr', 'list', '--repo', UPSTREAM, '--json', FIELDS, '--state', 'all')

    assert result.ok?, "stub failed: #{result.stderr}"
    assert_empty result.json
    assert_empty result.refusals,
                 'a repository the data covers and that has no pull requests is an answer'
  end

  def test_a_field_no_record_carries_is_refused
    result = refusal_case('pr', 'list', '--repo', REPO, '--state', 'all',
                          '--json', 'number,mergedAtt')

    assert_match(/unknown --json field/, result.refusals.join("\n"))
  end

  def test_unset_data_is_refused
    result = refusal_case('pr', 'list', '--repo', REPO, '--json', FIELDS,
                          env: { 'STUB_GH_PRS' => nil })

    assert_match(/STUB_GH_PRS is unset/, result.refusals.join("\n"))
  end

  def test_a_data_path_naming_no_file_is_refused
    result = refusal_case('pr', 'list', '--repo', REPO, '--json', FIELDS,
                          env: { 'STUB_GH_PRS' => File.join(@dir, 'absent.json') })

    assert_match(/names no such file/, result.refusals.join("\n"))
  end

  def test_a_limit_that_is_not_a_positive_number_is_refused
    result = refusal_case('pr', 'list', '--repo', REPO, '--json', FIELDS, '--limit', '0')

    assert_match(/--limit is not a positive number/, result.refusals.join("\n"))
  end

  # Without a refusals log there is nowhere to report a refusal, and a
  # refusal reported nowhere is a test that passes on a question the
  # stub threw out. It exits non-zero saying so rather than serving.
  def test_a_run_with_nowhere_to_report_refusals_says_so_and_serves_nothing
    _out, err, status = Open3.capture3(stub_env('CLI_STUB_REFUSALS' => nil), STUB, 'pr', 'view')

    refute status.success?, 'a run that cannot report refusals must not exit 0'
    assert_match(/CLI_STUB_REFUSALS is unset/, err)
  end

  def test_a_run_with_nowhere_to_log_says_so_before_doing_anything
    _out, err, status = Open3.capture3(stub_env('CLI_STUB_LOG' => nil), STUB,
                                       'pr', 'list', '--repo', REPO, '--json', FIELDS)

    refute status.success?, 'a run whose calls go unrecorded must not exit 0'
    assert_match(/CLI_STUB_LOG is unset/, err)
    assert_empty read_log(@refusals), 'nothing ran far enough to refuse'
  end
end
