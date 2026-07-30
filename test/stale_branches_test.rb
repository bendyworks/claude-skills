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

require 'open3'
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

# A fixture build runs roughly a hundred git commands, several of them
# destructive, and its whole safety rests on every one of them landing in
# the throwaway repository it just created. Two mechanisms in git defeat
# that by default, and neither is visible at the call site:
#
# 1. `git -C <dir>` does not override an inherited GIT_DIR. Open3.capture3
#    merges its env hash into the parent's rather than replacing it, so a
#    build inheriting GIT_DIR operates on whatever repository that names
#    -- creating branches, deleting them, and pushing to that repository's
#    own remote, all reported as success.
# 2. GIT_CONFIG_COUNT/GIT_CONFIG_KEY_n/GIT_CONFIG_VALUE_n inject
#    configuration without going through any config file, so pointing
#    GIT_CONFIG_GLOBAL and GIT_CONFIG_SYSTEM at an empty file does not
#    neutralize them. core.hooksPath arriving this way is arbitrary script
#    execution during a build.
#
# These tests pin the neutralization rather than the fixtures' verdicts,
# which is why they assert against a sentinel repository that no fixture
# names: the question is not whether the build is correct but whether
# anything outside its own temporary root can observe that it ran.
class RepoBuilderContainmentTest < Minitest::Test
  def test_an_ambient_git_dir_cannot_redirect_a_fixture_build
    Dir.mktmpdir('stale-branches-containment') do |dir|
      sentinel = build_sentinel(File.join(dir, 'sentinel'))
      before = sentinel_state(sentinel)
      failure = nil

      with_env('GIT_DIR' => File.join(sentinel, '.git'), 'GIT_WORK_TREE' => sentinel) do
        Fixtures::GitflowRepo.new(File.join(dir, 'fixture')).build
      rescue StandardError => e
        failure = e
      end

      assert_equal before, sentinel_state(sentinel),
                   'a fixture build reached the repository named by an ambient GIT_DIR'
      assert_nil failure, "the build failed under an ambient GIT_DIR: #{failure&.message}"
    end
  end

  def test_ambient_git_config_pairs_cannot_reach_a_fixture_repo
    Dir.mktmpdir('stale-branches-containment') do |dir|
      hooks = File.join(dir, 'hooks')
      observed = nil

      with_env('GIT_CONFIG_COUNT' => '1',
               'GIT_CONFIG_KEY_0' => 'core.hooksPath',
               'GIT_CONFIG_VALUE_0' => hooks) do
        repo = Fixtures::GitflowRepo.new(File.join(dir, 'fixture')).build
        observed = repo.git('config', '--default', '', '--get', 'core.hooksPath').strip
      end

      assert_empty observed,
                   'an ambient GIT_CONFIG_KEY pair reached a fixture repository'
    end
  end

  # The guard is what turns a redirected build into a clean abort rather
  # than damage. It refuses before creating anything, so a refused build
  # leaves no trace at the root it was asked for.
  def test_a_build_refuses_a_root_outside_the_temp_directory
    outside = File.join(__dir__, 'stale-branches-guard-probe')
    refute File.exist?(outside), 'the probe path existed before the test ran'

    error = assert_raises(Fixtures::RepoBuilder::Error) do
      Fixtures::GitflowRepo.new(outside).build
    end

    assert_match(/outside/i, error.message)
    refute File.exist?(outside), 'a refused build still created its root directory'
  end

  private

  # A repository no fixture names, standing in for the developer's own
  # clone: if a build escapes its root, this is what it escapes onto.
  def build_sentinel(dir)
    FileUtils.mkdir_p(dir)
    run_git(dir, 'init', '-q', '-b', 'sentinel-main')
    File.write(File.join(dir, 'kept.txt'), "kept\n")
    run_git(dir, 'add', 'kept.txt')
    run_git(dir, '-c', 'user.name=Sentinel', '-c', 'user.email=sentinel@example.com',
            'commit', '-qm', 'sentinel')
    dir
  end

  def sentinel_state(dir)
    run_git(dir, 'for-each-ref', '--format=%(refname) %(objectname)')
  end

  def run_git(dir, *args)
    stdout, stderr, status = Open3.capture3('git', '-C', dir, *args)
    raise "sentinel git #{args.join(' ')} failed: #{stderr.strip}" unless status.success?

    stdout
  end

  def with_env(pairs)
    saved = pairs.keys.to_h { |key| [key, ENV[key]] }
    pairs.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
