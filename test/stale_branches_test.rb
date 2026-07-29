# frozen_string_literal: true

# Grades bin/stale-branches against the fixture repositories under
# test/fixtures/, one assertion per branch.
#
# The oracle asserts a triple -- branch, verdict, reason -- rather than
# checking which branches still exist afterwards. Survival alone cannot
# distinguish a protection that fired from a deletion git refused on its
# own: `git branch -D` rejects the current branch, the default branch, and
# any branch checked out in another worktree, so a sweep with no protected
# set at all leaves those standing and would pass a survival-only grader.
# The reason is what says which rule actually ran.
#
# Every run also asserts that git printed no error: or fatal: line. A
# sweep that hands a full refname to `git branch -d` deletes nothing while
# reporting success, and the only evidence it went wrong is the noise git
# made on the way past.

require_relative 'cli_test_case'
require_relative 'fixtures/branch_repo'
require_relative 'fixtures/gitflow_repo'

require 'tmpdir'

CLI_PATH = File.expand_path('../bin/stale-branches', __dir__)
load CLI_PATH if File.exist?(CLI_PATH)

# One expected row: the branch, the verdict the sweep must reach, the
# reason key its report must carry, and prose saying why the row exists.
module Oracle
  Row = Struct.new(:branch, :verdict, :reason, :why)

  # A missing or empty table is a hard error, never an empty pass. A
  # grader that silently asserts nothing is indistinguishable from a
  # passing suite, which is the failure this whole file exists to prevent.
  def self.load(path)
    raise "oracle table not found: #{path}" unless File.exist?(path)

    rows = File.readlines(path).filter_map do |line|
      next if line.strip.empty? || line.lstrip.start_with?('#')

      branch, verdict, reason, *why = line.split
      raise "malformed oracle row in #{path}: #{line.inspect}" if reason.nil?
      raise "unknown verdict #{verdict.inspect} in #{path}" unless %w[KEEP DELETE].include?(verdict)

      Row.new(branch, verdict, reason, why.join(' '))
    end
    raise "oracle table has no rows: #{path}" if rows.empty?

    rows
  end
end

# Drives the CLI against a built fixture and turns its report back into
# rows the oracle can be compared with.
module SweepRun
  Result = Struct.new(:rows, :stdout, :stderr)

  # The report's reason column carries a stable key, optionally followed
  # by a parenthesized detail (a pull-request number, say). Only the key
  # is asserted, so the legend's wording stays free to change.
  REPORT_LINE = /\A(?<branch>\S+)\s{2,}(?<outcome>DELETE|keep)\s{2,}(?<reason>[a-z0-9:-]+)/

  GIT_COMPLAINT = /^(error|fatal):/

  def self.parse(stdout)
    stdout.lines.filter_map do |line|
      match = REPORT_LINE.match(line)
      next unless match

      Oracle::Row.new(match[:branch], match[:outcome] == 'DELETE' ? 'DELETE' : 'KEEP', match[:reason], nil)
    end
  end
end

# Shared driving and assertions; each fixture gets its own subclass so a
# failure names the repository shape it came from.
class OracleTestCase < CliTestCase
  def run_cli(argv)
    raise "#{CLI_PATH} does not exist yet" unless File.exist?(CLI_PATH)

    StaleBranches::CLI.run(argv)
  end

  # The CLI shells out to git, so it needs the same neutralized
  # configuration the fixture was built under: a developer's
  # commit.gpgsign or merge.ff must not be able to change a verdict.
  def sweep(repo, *extra)
    saved = repo.env.keys.to_h { |key| [key, ENV[key]] }
    repo.env.each { |key, value| ENV[key] = value }
    out, err = capture_io { run_cli(['-C', repo.work, *extra]) }
    SweepRun::Result.new(SweepRun.parse(out), out, err)
  ensure
    saved&.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

  # Collects every disagreement before failing, rather than stopping at
  # the first. A half-built sweep gets most of the table wrong at once,
  # and a grader that names one row per run turns that into one round
  # trip per row.
  def assert_matches_oracle(expected, result)
    actual = result.rows.to_h { |row| [row.branch, row] }

    mismatches = expected.filter_map do |row|
      got = actual[row.branch]
      if got.nil?
        "#{row.branch}: missing from the report -- #{row.why}"
      elsif got.verdict != row.verdict || got.reason != row.reason
        "#{row.branch}: expected #{row.verdict}/#{row.reason}, " \
          "got #{got.verdict}/#{got.reason} -- #{row.why}"
      end
    end

    mismatches += (actual.keys - expected.map(&:branch))
                  .map { |branch| "#{branch}: reported, but the oracle does not list it" }

    assert_empty mismatches, "#{mismatches.length} row(s) disagree with the oracle:\n" \
                             "#{mismatches.join("\n")}\n\nfull report:\n#{result.stdout}"
  end

  def refute_git_complaints(result)
    complaints = (result.stdout.lines + result.stderr.lines).grep(SweepRun::GIT_COMPLAINT)
    assert_empty complaints, "git reported errors during the sweep:\n#{complaints.join}"
  end
end

class FlatFixtureOracleTest < OracleTestCase
  ORACLE = File.expand_path('fixtures/expected-degraded.txt', __dir__)

  # The oracle and the fixture drift apart silently otherwise: a branch
  # the table forgets is never asserted on, and a branch the table invents
  # reads as "missing from the report", which blames the sweep for the
  # table's mistake. This one needs no CLI, so it stays green while the
  # rest of the file is red.
  def test_the_oracle_lists_exactly_the_branches_the_fixture_builds
    Dir.mktmpdir('stale-branches-coverage') do |dir|
      repo = Fixtures::BranchRepo.new(File.join(dir, 'flat')).build
      built = repo.local_refs.map { |ref| ref.sub('refs/heads/', '') }.sort
      listed = Oracle.load(ORACLE).map(&:branch).sort
      assert_equal built, listed, 'the oracle table and the fixture disagree about which branches exist'
    end
  end

  def test_report_matches_the_oracle_with_no_forge_available
    Dir.mktmpdir('stale-branches-flat') do |dir|
      repo = Fixtures::BranchRepo.new(File.join(dir, 'flat')).build
      result = sweep(repo)
      assert_matches_oracle(Oracle.load(ORACLE), result)
      refute_git_complaints(result)
    end
  end

  # Standing on a branch must protect it, whatever the evidence says.
  # a-squash-clean is otherwise deleted by the content check, so it is the
  # branch that tells current-branch protection from no protection at all.
  def test_the_checked_out_branch_is_protected_even_when_deletable
    Dir.mktmpdir('stale-branches-head') do |dir|
      repo = Fixtures::BranchRepo.new(File.join(dir, 'flat')).build
      repo.checkout('a-squash-clean')
      row = sweep(repo).rows.find { |candidate| candidate.branch == 'a-squash-clean' }
      refute_nil row, 'the checked-out branch is missing from the report'
      assert_equal 'KEEP', row.verdict
      assert_equal 'protected:current', row.reason
    end
  end

  # With HEAD detached there is no current branch to protect, and the
  # sweep must not mistake the empty answer for a branch named "HEAD".
  def test_a_detached_head_leaves_every_other_verdict_unchanged
    Dir.mktmpdir('stale-branches-detached') do |dir|
      repo = Fixtures::BranchRepo.new(File.join(dir, 'flat')).build
      repo.detach_head
      result = sweep(repo)
      refute_includes result.rows.map(&:branch), 'HEAD', 'a detached HEAD was reported as a branch'
      assert_matches_oracle(Oracle.load(ORACLE), result)
    end
  end
end

class GitflowOracleTest < OracleTestCase
  ORACLE = File.expand_path('fixtures/gitflow-expected-degraded.txt', __dir__)

  # A repository whose default branch is develop, with a non-default main
  # beside it. Every row here fails when the sweep assumes main.
  def test_report_matches_the_oracle_with_no_forge_available
    Dir.mktmpdir('stale-branches-gitflow') do |dir|
      repo = Fixtures::GitflowRepo.new(File.join(dir, 'gf')).build
      result = sweep(repo)
      assert_matches_oracle(Oracle.load(ORACLE), result)
      refute_git_complaints(result)
    end
  end

  # The reason a forge was not consulted belongs in a warning, once, not
  # in a per-branch reason. Reporting "no pull request" for a lookup that
  # never happened states an absence nobody checked.
  def test_no_row_claims_a_pull_request_was_absent
    Dir.mktmpdir('stale-branches-gitflow-reasons') do |dir|
      repo = Fixtures::GitflowRepo.new(File.join(dir, 'gf')).build
      result = sweep(repo)
      offenders = result.rows.select { |row| row.reason.include?('no-pull-request') }
      assert_empty offenders.map(&:branch), 'a reason claimed a pull request was absent without checking'
    end
  end
end
