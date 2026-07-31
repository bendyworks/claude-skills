# frozen_string_literal: true

# Checks the oracle tables under test/fixtures/ against the fixture
# repositories they describe, and both against the vocabulary they share.
#
# The tables are the specification bin/stale-branches will be built
# against: one row per branch, naming the verdict the sweep must reach and
# the reason key its report must carry. The tests that drive the CLI
# against them arrive with the CLI itself. Everything checkable before
# then is checked here, and it is more than it first appears, because
# each of these can go wrong while every other test stays green:
#
#   - the two halves must agree about which branches exist; a table that
#     forgets a branch silently asserts nothing about it, and one that
#     invents a branch would blame the sweep for the table's own mistake
#   - every reason the vocabulary documents must be demanded by a row, or
#     the rule behind it can be omitted from the sweep entirely with
#     nothing going red
#   - each table must demand a deletion from every stage that can reach
#     one, or a sweep implementing one stage scores full marks
#   - the loader's own guards must fire, since a guard that stops firing
#     yields a table specifying less than it appears to
#   - the fixtures must still build the structure the reasons rest on --
#     the worktree, the shadowing tags, the deleted remote refs
#
# Together those are what stops the tables from being gradable by a sweep
# nobody would ship, which is the failure the fixtures were rebuilt to
# close.

require_relative 'cli_test_case'
require_relative 'fixtures/branch_repo'
require_relative 'fixtures/gitflow_repo'
require_relative 'fixtures/oracle'

require 'open3'
require 'tmpdir'

class OracleTableTest < Minitest::Test
  FLAT = File.expand_path('fixtures/expected-degraded.txt', __dir__)
  GITFLOW = File.expand_path('fixtures/gitflow-expected-degraded.txt', __dir__)

  def test_the_flat_table_lists_exactly_the_branches_its_fixture_builds
    assert_tables_agree(Fixtures::BranchRepo, FLAT, 'flat')
  end

  def test_the_gitflow_table_lists_exactly_the_branches_its_fixture_builds
    assert_tables_agree(Fixtures::GitflowRepo, GITFLOW, 'gitflow')
  end

  # Both tables must demand a deletion from EVERY stage that can reach
  # one, not merely somewhere. A table whose only deletions come from the
  # cheap ancestor pass is satisfied by a sweep that implements that pass
  # and stops, and a table with no keepers is satisfied by one that
  # deletes everything -- the same accidental-full-marks shape that made
  # the earlier oracle gradable by implementations nobody would ship.
  # Derived from the vocabulary rather than listed, so a stage added to
  # REASONS later cannot slip past this guarantee. A hardcoded list would
  # keep passing when PR 3 adds proof-b, and the neighbouring test would
  # not catch it either: that one only demands each reason be claimed by
  # SOME row, and the row claiming a new stage may well be a KEEP.
  #
  # A stage counts as deleting when it can reach a deletion at all, which
  # is a property of the rule rather than of a table. protected:* never
  # deletes -- that is what protection means -- and kept:* is a keep by
  # name, so what remains is the stages that weigh evidence.
  NON_DELETING_STAGES = %w[protected kept].freeze

  def self.deleting_stages
    Fixtures::Oracle::REASONS.map { |reason| Fixtures::Oracle.stage(reason) }
                             .uniq - NON_DELETING_STAGES
  end

  def test_both_tables_demand_a_deletion_from_every_deciding_stage
    [FLAT, GITFLOW].each do |path|
      rows = Fixtures::Oracle.load(path)
      table = File.basename(path)

      self.class.deleting_stages.each do |stage|
        deletions = rows.count do |row|
          row.verdict == 'DELETE' && Fixtures::Oracle.stage(row.reason) == stage
        end
        assert_operator deletions, :>, 0, "#{table} asks for no deletion decided by #{stage}"
      end

      assert_operator rows.count { |row| row.verdict == 'KEEP' }, :>, 0,
                      "#{table} asks for no keeps at all"
    end
  end

  # Every reason the vocabulary documents must be demanded by some row in
  # some table. A key nothing claims is a rule the sweep can omit
  # entirely with nothing going red -- which is not a hypothetical: the
  # current-branch protection was documented, implemented nowhere, and
  # graded by nothing, and a classifier with that protection deleted
  # outright scored full marks on both tables.
  def test_every_documented_reason_is_demanded_by_some_row
    claimed = [FLAT, GITFLOW].flat_map { |path| Fixtures::Oracle.load(path).map(&:reason) }.uniq
    unclaimed = Fixtures::Oracle::REASONS - claimed

    assert_empty unclaimed,
                 'these reasons are documented but no row demands them, so nothing tests them'
  end

  # The flat table's header explains the vocabulary to a human reader
  # while REASONS enforces it on a row, and a reader who trusts the wrong
  # one of those writes a sweep that reports keys nothing accepts. Rows
  # in the vocabulary block are indented three spaces, which is what
  # separates them from the prose that discusses the same keys inline.
  # The prose column is the only place a row says why it exists, and a
  # row that stops saying so is one a later reader deletes as redundant
  # with its neighbour. Cheap to keep honest, and the two rows that were
  # hardest to tell apart had drifted to identical prose.
  def test_every_row_says_why_it_exists
    [FLAT, GITFLOW].each do |path|
      Fixtures::Oracle.load(path).each do |row|
        refute_empty row.why, "#{File.basename(path)} row #{row.branch} says nothing about why"
      end
    end
  end

  def test_the_table_header_documents_exactly_the_enforced_vocabulary
    documented = File.readlines(FLAT).filter_map do |line|
      line[/\A#   (\S+:\S+)\s/, 1]
    end

    assert_equal Fixtures::Oracle::REASONS.sort, documented.sort,
                 'the vocabulary the table explains and the one the loader enforces have drifted'
  end

  private

  def assert_tables_agree(builder, table, label)
    Dir.mktmpdir("stale-branches-#{label}") do |dir|
      repo = builder.new(File.join(dir, label)).build
      built = repo.local_refs.map { |ref| ref.delete_prefix('refs/heads/') }.sort
      listed = Fixtures::Oracle.load(table).map(&:branch).sort
      # The table goes in the expected slot: it is the specification, so
      # a diff should read as what the fixture did wrong against it.
      assert_equal listed, built,
                   "the #{label} oracle table and its fixture disagree about which branches exist"
    end
  end
end

# Every reason in the tables is a claim about the shape of the fixture,
# and the tables assert those reasons against a sweep rather than against
# the repository. So if a fixture quietly stopped building the shape its
# rows describe -- the worktree not registered, the shadowing tag absent,
# a remote ref that was supposed to be deleted still present -- the sweep
# would be graded against a specification nothing else holds it to, and
# every test here would stay green while doing it.
#
# These tests hold the fixtures to their own descriptions. They assert
# structure, never verdicts: what makes a row's reason reachable, not
# what the reason is.
class FixtureShapeTest < Minitest::Test
  FLAT = File.expand_path('fixtures/expected-degraded.txt', __dir__)
  GITFLOW = File.expand_path('fixtures/gitflow-expected-degraded.txt', __dir__)

  # The reasons decided by looking at the repository rather than at a
  # name. Each is a falsifiable claim about git's own answer, so each can
  # be checked here without a sweep existing.
  EVIDENCE_REASONS = %w[
    pass1:ancestor proof-a:content-landed proof-a:conflict kept:not-landed
  ].freeze

  # The rows that say "protected" are graded elsewhere; these are the ones
  # that say what git will report, and they are the rows a wrong fixture
  # would silently invalidate. proof-a:conflict matters most: it is the
  # only route to the forge, so a row claiming it that does not actually
  # conflict removes a pull-request rule's only subject, and the rule
  # could then be dropped from the sweep with nothing going red.
  def test_the_flat_tables_evidence_reasons_are_what_git_reports
    assert_evidence_matches(Fixtures::BranchRepo, FLAT, 'main', 'flat')
  end

  def test_the_gitflow_tables_evidence_reasons_are_what_git_reports
    assert_evidence_matches(Fixtures::GitflowRepo, GITFLOW,
                            Fixtures::GitflowRepo::DEFAULT_BRANCH, 'gitflow')
  end

  def test_the_flat_fixture_stands_somewhere_the_evidence_would_clear
    with_flat do |repo|
      assert_equal Fixtures::BranchRepo::CURRENT, repo.git('branch', '--show-current').strip,
                   'HEAD must stand on a branch that only current-branch protection saves'
      assert ancestor?(repo, Fixtures::BranchRepo::CURRENT, 'main'),
             'the current branch must be one the evidence would otherwise clear'
    end
  end

  def test_the_flat_fixture_builds_the_protections_its_table_calls_load_bearing
    with_flat do |repo|
      protected_by_name = Fixtures::BranchRepo::LONG_LIVED + [Fixtures::BranchRepo::BACKUP]
      (protected_by_name + %w[n-worktree]).each do |branch|
        assert ancestor?(repo, branch, 'main'),
               "#{branch} is protected by name, but the evidence would not have cleared it anyway"
      end

      worktrees = repo.git('worktree', 'list', '--porcelain')
      assert_includes worktrees, 'branch refs/heads/n-worktree',
                      'n-worktree must be checked out in a second worktree'
    end
  end

  def test_the_flat_fixture_builds_its_remote_ref_and_upstream_traps
    with_flat do |repo|
      Fixtures::BranchRepo::PUSHED_THEN_DELETED.each do |branch|
        assert_empty repo.git('ls-remote', '--heads', 'origin', branch).strip,
                     "#{branch} must have had its remote ref deleted"
      end

      Fixtures::BranchRepo::PUSHED_AND_KEPT.each do |branch|
        refute_empty repo.git('ls-remote', '--heads', 'origin', branch).strip,
                     "#{branch} must keep its remote ref, so a forge can answer for it"
      end

      upstream = repo.git('config', '--default', '', '--get',
                          'branch.l-tracks-deleted-local.merge').strip
      assert_equal 'refs/heads/throwaway', upstream,
                   'l-tracks-deleted-local must track a LOCAL branch, not a remote one'
      refute repo.git_succeeds?('rev-parse', '--verify', '-q', 'refs/heads/throwaway'),
             'the branch l-tracks-deleted-local tracks must be gone'
    end
  end

  # A deleted remote ref is not the same as work no remote ever saw: the
  # ref can be gone while the objects remain, which is the ordinary shape
  # of a merged branch the forge tidied up. d-unpushed is the fixture's
  # only branch carrying the stronger property, and it holds only because
  # its last commit is made after every push. Asserting the branch tip is
  # absent from origin's object store is the difference between building
  # that property and merely naming it.
  def test_the_flat_fixture_builds_a_branch_no_remote_ever_received
    with_flat do |repo|
      tip = repo.git('rev-parse', 'refs/heads/d-unpushed').strip

      refute repo.git_succeeds?('cat-file', '-e', "#{tip}^{commit}", dir: repo.origin),
             'd-unpushed carries work a remote already has, so no row tests unpushed work'
    end
  end

  def test_the_flat_fixture_builds_the_tag_that_shadows_a_branch
    with_flat { |repo| assert_tag_shadows(repo, Fixtures::BranchRepo::TAG_SHADOWED) }
  end

  def test_the_gitflow_fixture_stands_on_no_branch_at_all
    with_gitflow do |repo|
      refute repo.git_succeeds?('symbolic-ref', '-q', '--short', 'HEAD'),
             'the gitflow build must end with HEAD detached'
      assert_empty repo.git('branch', '--show-current').strip
    end
  end

  # The premise of the whole fixture: the default branch is develop, and
  # it is discoverable without reading a local cache of the remote's HEAD.
  def test_the_gitflow_fixture_names_its_default_branch_on_the_remote
    with_gitflow do |repo|
      symref = repo.git('ls-remote', '--symref', 'origin', 'HEAD')
      assert_includes symref, "ref: refs/heads/#{Fixtures::GitflowRepo::DEFAULT_BRANCH}\tHEAD"

      refute repo.git_succeeds?('rev-parse', '--verify', '-q', 'refs/remotes/origin/HEAD'),
             'origin/HEAD must stay absent: the sweep asks the remote, not a local cache of it'
    end
  end

  def test_the_gitflow_fixture_keeps_main_off_the_default_branch
    with_gitflow do |repo|
      default = Fixtures::GitflowRepo::DEFAULT_BRANCH
      refute ancestor?(repo, 'main', default),
             'main must hold work develop does not, or its keep is decided by the evidence'
      [Fixtures::GitflowRepo::RELEASE, Fixtures::GitflowRepo::ANCESTOR].each do |branch|
        assert ancestor?(repo, branch, default),
               "#{branch} must be an ancestor of #{default}"
      end
      assert_tag_shadows(repo, Fixtures::GitflowRepo::TAG_SHADOWED)
    end
  end

  private

  # A bare name that resolves to something other than the branch of that
  # name is the whole trap: a sweep asking git about `amb` is answered
  # about the tag, which points at the default branch and so reports the
  # branch as holding nothing.
  def assert_tag_shadows(repo, name)
    bare = repo.git('rev-parse', name).strip
    branch = repo.git('rev-parse', "refs/heads/#{name}").strip
    tag = repo.git('rev-parse', "refs/tags/#{name}").strip

    assert_equal tag, bare, "the bare name #{name} must resolve to the tag"
    refute_equal branch, bare, "the tag shadowing #{name} must point somewhere else"
  end

  def assert_evidence_matches(builder, table, default, label)
    rows = Fixtures::Oracle.load(table).select { |row| EVIDENCE_REASONS.include?(row.reason) }
    refute_empty rows, "#{label}: no row states evidence at all"

    with_fixture(builder, label) do |repo|
      default_tree = repo.git('rev-parse', "refs/heads/#{default}^{tree}").strip
      rows.each do |row|
        assert_equal row.reason, evidence_for(repo, row.branch, default, default_tree),
                     "#{label}: the table says #{row.branch} is #{row.reason}, git disagrees"
      end
    end
  end

  # Reimplements the header's documented evidence procedure, in its
  # documented order, against the built repository -- so the table is
  # graded on what git actually reports rather than on what a row claims.
  def evidence_for(repo, branch, default, default_tree)
    ref = "refs/heads/#{branch}"
    return 'pass1:ancestor' if ancestor?(repo, branch, default)

    tree, merged = merge_tree(repo, default, ref)
    return 'proof-a:conflict' unless merged

    tree == default_tree ? 'proof-a:content-landed' : 'kept:not-landed'
  end

  # Returns the merged tree and whether the merge succeeded. A conflict is
  # a non-zero exit, not a message, which is why the status is what the
  # caller branches on.
  def merge_tree(repo, default, ref)
    stdout, _stderr, status = Open3.capture3(repo.env, 'git', '-C', repo.work,
                                             'merge-tree', '--write-tree',
                                             "refs/heads/#{default}", ref)
    [stdout.lines.first.to_s.strip, status.success?]
  end

  def ancestor?(repo, branch, other)
    repo.git_succeeds?('merge-base', '--is-ancestor', "refs/heads/#{branch}",
                       "refs/heads/#{other}")
  end

  def with_flat(&block)
    with_fixture(Fixtures::BranchRepo, 'flat', &block)
  end

  def with_gitflow(&block)
    with_fixture(Fixtures::GitflowRepo, 'gitflow', &block)
  end

  def with_fixture(builder, label)
    Dir.mktmpdir("stale-branches-#{label}") do |dir|
      yield builder.new(File.join(dir, label)).build
    end
  end
end

# The loader is the grader. Every assertion the sweep is ever graded by
# arrives through it, so a guard that stops firing does not produce a
# wrong answer -- it produces a table that quietly specifies less than it
# appears to, while every test that reads it stays green. Each guard gets
# a test for that reason, and each test writes the smallest table that
# should be refused.
class OracleLoaderTest < Minitest::Test
  def test_a_missing_table_is_an_error_rather_than_an_empty_pass
    error = assert_raises(Fixtures::Oracle::Error) { Fixtures::Oracle.load(table_path('absent.txt')) }
    assert_match(/not found/, error.message)
  end

  def test_a_table_with_no_rows_is_an_error_rather_than_an_empty_pass
    error = assert_raises(Fixtures::Oracle::Error) { load_table("# nothing but a comment\n\n") }
    assert_match(/no rows/, error.message)
  end

  def test_a_row_missing_its_reason_is_refused
    error = assert_raises(Fixtures::Oracle::Error) { load_table("main KEEP\n") }
    assert_match(/malformed/, error.message)
  end

  def test_a_row_naming_an_unknown_verdict_is_refused
    error = assert_raises(Fixtures::Oracle::Error) { load_table("main PROBABLY protected:default why\n") }
    assert_match(/unknown verdict/, error.message)
  end

  # The reason is the contract the sweep's report is matched against, so
  # a typo in a key would otherwise ship as the specification and the
  # implementation would be written to satisfy the typo.
  def test_a_row_naming_an_unknown_reason_is_refused
    error = assert_raises(Fixtures::Oracle::Error) { load_table("main KEEP protected:defualt why\n") }
    assert_match(/unknown reason/, error.message)
  end

  def test_a_well_formed_row_survives_every_guard
    rows = load_table("main KEEP protected:default the default branch\n")

    assert_equal 1, rows.length
    assert_equal 'main', rows.first.branch
    assert_equal 'KEEP', rows.first.verdict
    assert_equal 'protected:default', rows.first.reason
    assert_equal 'the default branch', rows.first.why
  end

  # git permits a branch name beginning with '#', so an indented row must
  # not be mistaken for a comment: dropping it would remove that branch
  # from the specification without a word.
  def test_only_a_marker_in_the_first_column_starts_a_comment
    rows = load_table("  #odd KEEP kept:not-landed a branch named oddly\n")

    assert_equal ['#odd'], rows.map(&:branch)
  end

  private

  def load_table(contents)
    Dir.mktmpdir('stale-branches-oracle') do |dir|
      path = File.join(dir, 'table.txt')
      File.write(path, contents)
      return Fixtures::Oracle.load(path)
    end
  end

  def table_path(name)
    File.join(Dir.tmpdir, "stale-branches-#{name}")
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

  # The harness that proves containment is itself a git caller, and the
  # weakest link decides the answer: a redirected sentinel builder both
  # writes into the repository an ambient GIT_DIR names and reads its
  # comparison back from there, so the suite reports success while doing
  # exactly the damage it is testing for. This test sets the ambient
  # variable around the SENTINEL construction rather than around a
  # fixture build, which is the case the other tests here cannot see.
  def test_building_a_sentinel_cannot_be_redirected_either
    Dir.mktmpdir('stale-branches-containment') do |dir|
      victim = build_sentinel(File.join(dir, 'victim'))
      before = sentinel_state(victim)

      # GIT_DIR alone, with no GIT_WORK_TREE: git then takes the working
      # tree from the directory it was pointed at, so commands read the
      # files in front of them and write the result into the repository
      # the variable names. That is the combination that actually
      # escapes, and the one the real incident had; setting GIT_WORK_TREE
      # too would send the reads back to the victim and mask it as an
      # empty commit.
      with_env('GIT_DIR' => File.join(victim, '.git')) do
        build_sentinel(File.join(dir, 'other'))
      end

      assert_equal before, sentinel_state(victim),
                   'the sentinel builder wrote into the repository an ambient GIT_DIR named'
      assert_path_exists File.join(dir, 'other', '.git'),
                         'the second sentinel must be a repository of its own'
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

  # Two defenses against the same variable, and each covers what the
  # other cannot. RepoBuilder unsets these per git invocation, which
  # reaches only the commands it makes itself; CliTestCase deletes them
  # for the whole test body, which reaches the CLI's own git calls -- and
  # those carry no env hash, because in real use an ambient GIT_DIR is
  # the developer saying where their repository is. So the two lists must
  # not drift: a location variable learned about here and not there is
  # one a sweep would still inherit.
  def test_every_location_key_the_fixtures_unset_is_also_scrubbed_suite_wide
    missing = Fixtures::RepoBuilder::LOCATION_KEYS - CliTestCase::BASE_SCRUBBED_ENV_KEYS
    assert_empty missing,
                 'RepoBuilder unsets these per command, but no CLI test body is free of them'
  end

  private

  # A repository no fixture names, standing in for the developer's own
  # clone: if a build escapes its root, this is what it escapes onto.
  def build_sentinel(dir)
    FileUtils.mkdir_p(dir)
    run_git(dir, 'init', '-q', '-b', 'sentinel-main')
    # Content differs per sentinel. Two sentinels holding identical bytes
    # would let a redirected build stage nothing and fail on an empty
    # commit, which reads as a broken test rather than as the escape it
    # is -- the escape only becomes visible when the redirected commit
    # can actually succeed.
    File.write(File.join(dir, 'kept.txt'), "kept by #{File.basename(dir)}\n")
    run_git(dir, 'add', 'kept.txt')
    # Identity is passed explicitly rather than left to the neutralized
    # env. It is what the env would have supplied anyway, and carrying it
    # here means a sentinel built WITHOUT that env still commits -- so a
    # missing scrub shows up as the escape it is, rather than as a commit
    # that failed for want of a name on a machine that has one.
    run_git(dir, '-c', 'user.name=Sentinel', '-c', 'user.email=sentinel@example.com',
            'commit', '-qm', 'sentinel')
    dir
  end

  def sentinel_state(dir)
    run_git(dir, 'for-each-ref', '--format=%(refname) %(objectname)')
  end

  # Runs under the same neutralization the fixtures use. The sentinel is
  # the thing an escape is measured against, so a sentinel built through
  # an ambient GIT_DIR would be built INSIDE the repository it is
  # supposed to be protecting -- and read back from there too, leaving
  # every assertion comparing that repository to itself.
  def run_git(dir, *args)
    env = Fixtures::RepoBuilder.neutralized_env(sentinel_config)
    stdout, stderr, status = Open3.capture3(env, 'git', '-C', dir, *args)
    unless status.success?
      # stdout as well as stderr, for the same reason RepoBuilder#git
      # reports both: git commit announces its failures on stdout, and
      # "nothing to commit" is exactly the failure this helper hits.
      raise "sentinel git #{args.join(' ')} failed\nstdout: #{stdout.strip}\nstderr: #{stderr.strip}"
    end

    stdout
  end

  def sentinel_config
    @sentinel_config ||= begin
      path = File.join(Dir.mktmpdir('stale-branches-sentinel-config'), 'gitconfig-empty')
      File.write(path, '')
      path
    end
  end

  def with_env(pairs)
    saved = pairs.keys.to_h { |key| [key, ENV[key]] }
    pairs.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end

# The sweep itself, graded against the tables above. Everything from here
# down needs bin/stale-branches; until it exists these tests are red, and
# that is the point -- the specification lands before the code satisfying
# it, and the CLI is written until these turn green.
#
# The CLI is driven IN-PROCESS rather than as a subprocess, for three
# reasons that each bite differently. CI's coverage guard passes on a
# merely-loaded file, so a subprocess sweep would report zero coverage
# while CI stayed green. Minitest's capture_io redirects Ruby's $stdout
# object rather than file descriptor 1, so a child's output escapes it
# entirely. And `ruby` itself fails when invoked from inside a fixture
# directory under a version manager.
CLI_PATH = File.expand_path('../bin/stale-branches', __dir__)
load CLI_PATH if File.exist?(CLI_PATH)

# Turns the sweep's report back into rows the oracle can be compared with.
module SweepRun
  Result = Struct.new(:rows, :stdout, :stderr)

  # The reason column carries a stable key, optionally followed by a
  # parenthesized detail (a pull-request number, say). Only the key is
  # matched, so the legend's wording stays free to change without
  # breaking a test.
  REPORT_LINE = /\A(?<branch>\S+)\s{2,}(?<outcome>DELETE|keep)\s{2,}(?<reason>[a-z0-9:-]+)/

  # A sweep that hands a full refname to `git branch -d` deletes nothing
  # while reporting success. The only evidence it went wrong is the noise
  # git made on the way past, so every run asserts there was none.
  GIT_COMPLAINT = /^(error|fatal):/

  def self.parse(stdout)
    stdout.lines.filter_map do |line|
      match = REPORT_LINE.match(line)
      next unless match

      Fixtures::Oracle::Row.new(match[:branch],
                                match[:outcome] == 'DELETE' ? 'DELETE' : 'KEEP',
                                match[:reason], nil)
    end
  end
end

# Shared driving and assertions. Each fixture gets its own subclass so a
# failure names the repository shape it came from.
class OracleTestCase < CliTestCase
  # PR 2's sweep is the offline half and must never reach a forge. Naming
  # gh here shadows it with a PATH shim that records the attempt and
  # fails, so any code path that calls it flunks the test rather than
  # silently succeeding on a developer's authenticated machine.
  def shimmed_commands
    ['gh']
  end

  # This sweep deletes branches, so the directory it is aimed at is not
  # a detail that degrades gracefully -- and the two targets that would
  # do the damage are the ones nobody writes deliberately: this
  # repository named outright, and the working directory a forgotten -C
  # falls back to. During a test run both are the developer's own clone.
  # The target is read from argv rather than from the fixture, so a test
  # building its own argv is covered by the same refusal.
  def guard_cli_invocation(argv)
    index = argv.index('-C')
    target = index ? argv[index + 1] : Dir.pwd
    return if target && Fixtures::RepoBuilder.under_tmpdir?(File.expand_path(target))

    flunk "refusing to sweep #{target.inspect}: outside #{Dir.tmpdir}"
  end

  def dispatch_cli(argv)
    raise "#{CLI_PATH} does not exist yet" unless File.exist?(CLI_PATH)

    StaleBranches::CLI.run(argv)
  end

  # The CLI shells out to git, so it runs under the same neutralized
  # environment the fixture was built with: a developer's commit.gpgsign
  # or merge.ff must not be able to change a verdict, and an ambient
  # GIT_DIR must not be able to redirect the sweep at their own clone.
  # A nil value means "unset", which is how RepoBuilder deletes the keys
  # that would redirect git.
  def sweep(repo, *extra)
    saved = repo.env.keys.to_h { |key| [key, ENV[key]] }
    repo.env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    out, err = capture_io { run_cli(['-C', repo.work, *extra]) }
    SweepRun::Result.new(SweepRun.parse(out), out, err)
  ensure
    saved&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  # Collects every disagreement before failing rather than stopping at the
  # first. A half-built sweep gets most of the table wrong at once, and a
  # grader that names one row per run turns that into one round trip per
  # row. `overrides` lets a test that moved HEAD say which rows it expects
  # to differ from the table, so the rest still assert.
  def assert_matches_oracle(expected, result, overrides = {})
    actual = result.rows.to_h { |row| [row.branch, row] }

    mismatches = expected.filter_map do |row|
      want_verdict, want_reason = overrides.fetch(row.branch, [row.verdict, row.reason])
      got = actual[row.branch]
      if got.nil?
        "#{row.branch}: missing from the report -- #{row.why}"
      elsif got.verdict != want_verdict || got.reason != want_reason
        "#{row.branch}: expected #{want_verdict}/#{want_reason}, " \
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

  def with_flat_fixture(label)
    Dir.mktmpdir("stale-branches-#{label}") do |dir|
      yield Fixtures::BranchRepo.new(File.join(dir, 'flat')).build
    end
  end
end

# Drives the guard rather than a fixture: its target is whatever the
# contract test sets, including the two a sweep must never be pointed
# at. Unset means the body does nothing, so autorun's own pass over
# this class stays green.
class SweepTargetProbeCase < OracleTestCase
  class << self
    attr_accessor :target
  end

  def test_sweep_the_configured_target
    return unless self.class.target

    run_cli(self.class.target)
  end
end

# The sweep deletes branches, so where it is aimed is not a detail that
# degrades gracefully. Every other defense here is about what the sweep
# READS -- an ambient GIT_DIR, a stale tracking ref -- while this one is
# about what it is asked to write to, and the two most dangerous targets
# are the ones no test would think to write: this very repository, named
# outright, and the working directory a missing -C falls back to. Both
# are the developer's clone during a test run.
class SweepTargetTest < Minitest::Test
  def test_a_target_outside_the_temp_directory_is_refused
    assert_match(/outside/i, refusal(['-C', Dir.pwd]),
                 'a sweep aimed at a working clone was allowed to run')
  end

  def test_no_target_at_all_is_refused_rather_than_falling_back_to_the_working_directory
    assert_match(/outside/i, refusal([]),
                 'a sweep with no -C ran against whatever directory the suite started in')
  end

  # The guard has to let a throwaway through, or it would refuse the
  # whole suite and every oracle test would pass by never running.
  # Asserted as "not refused" rather than as a clean run, so this keeps
  # its meaning once the CLI exists and the probe reaches a real sweep.
  def test_a_target_inside_the_temp_directory_is_allowed
    Dir.mktmpdir('stale-branches-guard') do |dir|
      refute_match(/outside/i, run_probe(['-C', dir]).failure&.message.to_s,
                   'the guard refused a throwaway repository')
    end
  end

  private

  def refusal(target)
    result = run_probe(target)
    refute result.passed?, "the guard allowed #{target.inspect}"
    result.failure.message
  end

  def run_probe(target)
    SweepTargetProbeCase.target = target
    SweepTargetProbeCase.new('test_sweep_the_configured_target').run
  ensure
    SweepTargetProbeCase.target = nil
  end
end

class FlatFixtureOracleTest < OracleTestCase
  ORACLE = File.expand_path('fixtures/expected-degraded.txt', __dir__)

  def test_report_matches_the_oracle_with_no_forge_available
    with_flat_fixture('flat') do |repo|
      result = sweep(repo)
      assert_matches_oracle(Fixtures::Oracle.load(ORACLE), result)
      refute_git_complaints(result)
    end
  end

  # Standing on a branch protects it whatever the evidence says, and
  # moving off one un-protects it. Asserting both halves is what tells
  # current-branch protection from a rule that merely happens to keep the
  # branch the fixture left HEAD on: a-squash-clean is DELETE in the table
  # on its content alone, and o-current is KEEP only because HEAD is
  # there, so checking out the first must flip both rows.
  def test_the_checked_out_branch_is_protected_and_the_one_left_behind_is_not
    with_flat_fixture('head') do |repo|
      repo.checkout('a-squash-clean')
      result = sweep(repo)

      assert_matches_oracle(
        Fixtures::Oracle.load(ORACLE), result,
        'a-squash-clean' => %w[KEEP protected:current],
        'o-current' => %w[DELETE pass1:ancestor]
      )
      refute_git_complaints(result)
    end
  end

  # With HEAD detached there is no current branch to protect. The sweep
  # must not mistake the empty answer for a branch named HEAD -- which is
  # what `rev-parse --abbrev-ref HEAD` hands back where `symbolic-ref -q
  # --short HEAD` fails -- and o-current, protected by nothing else, must
  # lose its protection.
  def test_a_detached_head_protects_no_branch_at_all
    with_flat_fixture('detached') do |repo|
      repo.detach_head
      result = sweep(repo)

      refute_includes result.rows.map(&:branch), 'HEAD',
                      'a detached HEAD was reported as a branch'
      assert_matches_oracle(Fixtures::Oracle.load(ORACLE), result,
                            'o-current' => %w[DELETE pass1:ancestor])
      refute_git_complaints(result)
    end
  end
end

class GitflowOracleTest < OracleTestCase
  ORACLE = File.expand_path('fixtures/gitflow-expected-degraded.txt', __dir__)

  # A repository whose default branch is develop, with a non-default main
  # beside it. Every row here fails when the sweep assumes main. This
  # fixture also ends with HEAD detached, so the whole table is graded
  # from a detached HEAD as a matter of course.
  def test_report_matches_the_oracle_with_no_forge_available
    Dir.mktmpdir('stale-branches-gitflow') do |dir|
      repo = Fixtures::GitflowRepo.new(File.join(dir, 'gf')).build
      result = sweep(repo)
      assert_matches_oracle(Fixtures::Oracle.load(ORACLE), result)
      refute_git_complaints(result)
    end
  end

  # The reason a forge was not consulted belongs in a warning, once, not
  # in a per-branch reason. Reporting "no pull request" for a lookup that
  # never happened states an absence nobody checked.
  def test_no_row_claims_a_pull_request_was_absent
    Dir.mktmpdir('stale-branches-gitflow-reasons') do |dir|
      repo = Fixtures::GitflowRepo.new(File.join(dir, 'gf')).build
      offenders = sweep(repo).rows.select { |row| row.reason.include?('no-pull-request') }
      assert_empty offenders.map(&:branch),
                   'a reason claimed a pull request was absent without checking'
    end
  end
end
