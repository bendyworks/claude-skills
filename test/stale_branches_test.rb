# frozen_string_literal: true

# Checks the oracle tables under test/fixtures/ against the fixture
# repositories they describe.
#
# The tables are the specification bin/stale-branches will be built
# against: one row per branch, naming the verdict the sweep must reach and
# the reason key its report must carry. The tests that drive the CLI
# against them arrive with the CLI itself. What can be checked before then
# is that the two halves agree about which branches exist -- a table that
# forgets a branch silently asserts nothing about it, and one that invents
# a branch would blame the sweep for the table's own mistake.

require_relative 'cli_test_case'
require_relative 'fixtures/branch_repo'
require_relative 'fixtures/gitflow_repo'

require 'tmpdir'

# One expected row: the branch, the verdict the sweep must reach, the
# reason key its report must carry, and prose saying why the row exists.
module Oracle
  Row = Struct.new(:branch, :verdict, :reason, :why)

  # A missing or empty table is a hard error, never an empty pass. A
  # grader that silently asserts nothing is indistinguishable from a
  # passing suite, which is the failure these tables exist to prevent.
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

class OracleTableTest < Minitest::Test
  FLAT = File.expand_path('fixtures/expected-degraded.txt', __dir__)
  GITFLOW = File.expand_path('fixtures/gitflow-expected-degraded.txt', __dir__)

  def test_the_flat_table_lists_exactly_the_branches_its_fixture_builds
    assert_tables_agree(Fixtures::BranchRepo, FLAT, 'flat')
  end

  def test_the_gitflow_table_lists_exactly_the_branches_its_fixture_builds
    assert_tables_agree(Fixtures::GitflowRepo, GITFLOW, 'gitflow')
  end

  # Both tables must reach a verdict of DELETE somewhere. A table of
  # nothing but keepers is satisfied by a sweep that never deletes
  # anything, which is precisely the implementation these fixtures are
  # meant to rule out.
  def test_both_tables_demand_at_least_one_deletion
    [FLAT, GITFLOW].each do |path|
      deletions = Oracle.load(path).count { |row| row.verdict == 'DELETE' }
      assert_operator deletions, :>, 0, "#{File.basename(path)} asks for no deletions at all"
    end
  end

  private

  def assert_tables_agree(builder, table, label)
    Dir.mktmpdir("stale-branches-#{label}") do |dir|
      repo = builder.new(File.join(dir, label)).build
      built = repo.local_refs.map { |ref| ref.sub('refs/heads/', '') }.sort
      listed = Oracle.load(table).map(&:branch).sort
      assert_equal built, listed,
                   "the #{label} oracle table and its fixture disagree about which branches exist"
    end
  end
end
