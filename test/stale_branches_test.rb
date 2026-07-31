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

# The flags, parsed as a pure function. Nothing here touches a
# repository, so nothing here needs one -- and the traps below are
# OptionParser's rather than git's, each having cost this repo a defect
# in some CLI already.
class ArgumentParsingTest < CliTestCase
  def test_the_defaults_name_the_working_directory_and_origin
    options = parse

    assert_equal '.', options.dir
    assert_equal 'origin', options.remote
    refute options.delete?
  end

  def test_dash_c_names_the_repository_to_sweep
    assert_equal '/tmp/elsewhere', parse('-C', '/tmp/elsewhere').dir
  end

  def test_remote_names_the_ancestry_to_measure_against
    assert_equal 'upstream', parse('--remote', 'upstream').remote
  end

  def test_delete_is_off_until_it_is_asked_for
    assert parse('--delete').delete?
  end

  def test_help_asks_for_usage_rather_than_a_sweep
    assert parse('--help').help?
    assert parse('-h').help?
  end

  def test_an_unknown_option_is_refused_by_name
    assert_equal 'invalid option: --bogus', refusal('--bogus')
  end

  def test_a_value_option_with_no_value_says_which_one
    assert_equal 'missing argument: --remote', refusal('--remote')
  end

  # This CLI takes no positionals at all, so one is not a stray detail
  # but a misreading of what the command does: `stale-branches
  # some-branch --delete`, typed by someone who believes it names the
  # branch to remove, would act on every branch in the repository.
  def test_a_positional_is_refused_rather_than_ignored
    assert_equal 'unexpected extra arguments: "some-branch"', refusal('some-branch', '--delete')
  end

  # A mandatory-argument option swallows a following flag as its value.
  # Unguarded, `-C --delete` parses as a directory named --delete with
  # no delete flag set, and the sweep acts on the command it misread.
  def test_a_value_option_will_not_swallow_a_following_flag
    assert_match(/--delete/, refusal('-C', '--delete'))
    assert_match(/--delete/, refusal('--remote', '--delete'))
  end

  # Last-wins would silently discard the first value, which for -C means
  # sweeping a repository the caller also named and did not get.
  def test_a_repeated_value_option_is_refused_rather_than_last_winning
    assert_equal 'duplicate -C', refusal('-C', '/tmp/a', '-C', '/tmp/b')
    assert_equal 'duplicate --remote', refusal('--remote', 'a', '--remote', 'b')
  end

  # Accepted where a repeated value option is refused, and the
  # difference is not inconsistency: a repeated boolean discards no
  # input and leaves the sweep acting on exactly what was typed.
  def test_a_repeated_delete_flag_is_accepted
    assert parse('--delete', '--delete').delete?
  end

  # OptionParser#parse permutes positionals past flags only while
  # POSIXLY_CORRECT is unset; with it set, parsing stops at the first
  # positional and every flag after it leaks into the leftovers. So the
  # same argv means two things on two machines, and the machine that
  # differs is the one whose sweep silently loses --delete or gains a
  # complaint about a flag the caller spelled correctly.
  def test_the_environment_cannot_change_what_an_argv_means
    argv = ['oops', '--delete']
    scrubbed = refusal(*argv)
    ENV['POSIXLY_CORRECT'] = '1'

    assert_equal scrubbed, refusal(*argv)
    assert_equal 'unexpected extra arguments: "oops"', scrubbed
  end

  private

  def parse(*argv)
    StaleBranches.parse_options(argv)
  end

  def refusal(*argv)
    assert_raises(StaleBranches::Error) { parse(*argv) }.message
  end
end

# `ls-remote --symref <remote> HEAD` is the one authoritative answer to
# what the default branch is: it asks the remote, needs no forge, and
# writes nothing -- where `remote set-head --auto` answers the same
# question by writing a local ref that is then wrong until the next time
# someone remembers to run it. Parsing its two lines is pure, so it is
# tested without a repository.
class RemoteHeadParsingTest < Minitest::Test
  REAL_OUTPUT = "ref: refs/heads/develop\tHEAD\n55a8fc0a4f21946df49bb9900352cd09e2ef2fc2\tHEAD\n"

  def test_the_symref_line_names_the_branch_and_the_second_line_its_tip
    head = StaleBranches.parse_remote_head(REAL_OUTPUT)

    assert_equal 'develop', head.name
    assert_equal '55a8fc0a4f21946df49bb9900352cd09e2ef2fc2', head.sha
    assert_predicate head, :from_remote?
  end

  # Branch names carry slashes, and release/1.x is a name both fixtures
  # build. A pattern stopping at the slash would answer "release".
  def test_a_slashed_branch_name_survives_intact
    head = StaleBranches.parse_remote_head("ref: refs/heads/release/1.x\tHEAD\ndeadbee\tHEAD\n")

    assert_equal 'release/1.x', head.name
  end

  # An empty remote answers with the symref alone: HEAD names a branch
  # that has no commits yet, so there is no tip line. The name is still
  # the answer to the question that was asked.
  def test_a_symref_with_no_tip_still_names_the_branch
    head = StaleBranches.parse_remote_head("ref: refs/heads/main\tHEAD\n")

    assert_equal 'main', head.name
    assert_nil head.sha
  end

  def test_output_with_no_symref_line_answers_nothing
    assert_nil StaleBranches.parse_remote_head("55a8fc0\tHEAD\n")
    assert_nil StaleBranches.parse_remote_head('')
  end
end

# Which branches the sweep refuses to consider at all, decided from the
# name and three facts about the repository. Pure, so the whole decision
# table is exercised here without a repository; the fixtures then check
# that the facts fed in are the ones git reports.
class ProtectionTest < Minitest::Test
  FACTS = { default: 'main', current: 'feature', worktrees: %w[parked] }.freeze

  def test_the_default_branch_is_protected_as_the_default
    assert_equal 'protected:default', protection('main')
  end

  # Order is the assertion, not the verdict. main is on the long-lived
  # list too, so both rules keep it and only the reason says which one
  # ran -- and the same is true of develop in a repository that ships
  # from it, where a sweep answering "long-lived" has not proved it
  # knows which branch is the default at all.
  def test_a_default_branch_that_is_also_long_lived_is_decided_as_the_default
    assert_equal 'protected:default', protection('develop', default: 'develop')
  end

  def test_the_checked_out_branch_is_protected_as_the_current_one
    assert_equal 'protected:current', protection('feature')
  end

  def test_a_branch_checked_out_in_another_worktree_is_protected_as_such
    assert_equal 'protected:worktree', protection('parked')
  end

  # Nothing is standing anywhere, so nothing is protected for standing
  # there. A sweep taking the empty answer for a branch name would
  # protect a branch called "" or "HEAD", and `rev-parse --abbrev-ref
  # HEAD` hands back exactly "HEAD" where `symbolic-ref` reports
  # nothing.
  def test_a_detached_head_protects_no_branch
    assert_nil protection('feature', current: nil)
    assert_nil protection('HEAD', current: nil)
  end

  def test_every_long_lived_name_is_protected_by_its_name
    %w[master develop staging production gh-pages].each do |name|
      assert_equal 'protected:long-lived', protection(name), "#{name} was not protected"
    end
  end

  # A prefix rather than a name: teams cut release/1.x, release/2026-07
  # and so on, and each is long-lived for as long as it is supported.
  def test_a_release_branch_is_protected_by_its_prefix
    assert_equal 'protected:long-lived', protection('release/1.x')
    assert_equal 'protected:long-lived', protection('release/2026-07')
  end

  # A near-miss must not inherit the protection: releases-ui is somebody
  # feature branch, and a rule matching it would keep it forever.
  def test_a_name_merely_starting_with_release_is_not_protected
    assert_nil protection('releases-ui')
    assert_nil protection('release-notes')
  end

  def test_a_backup_suffix_is_protected_as_a_backup
    assert_equal 'protected:backup', protection('r-spike-backup')
  end

  def test_an_ordinary_branch_is_protected_by_nothing
    assert_nil protection('some-work')
    assert_nil protection('backup-of-something')
  end

  private

  def protection(branch, **overrides)
    StaleBranches.protection_for(branch, **FACTS.merge(overrides))
  end
end


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

  def sweep(repo, *extra)
    with_repo_env(repo) do
      out, err = capture_io { run_cli(['-C', repo.work, *extra]) }
      SweepRun::Result.new(SweepRun.parse(out), out, err)
    end
  end

  # The command layer, driven directly for the questions a report cannot
  # be asked yet. It goes through the same refusal run_cli gets, so a
  # test reaching past the argv cannot reach past the guard with it.
  def git_for(repo, remote: 'origin', dir: repo.work)
    guard_cli_invocation(['-C', repo.work])
    StaleBranches::Git.new(dir: dir, remote: remote)
  end

  # The CLI shells out to git, so it runs under the same neutralized
  # environment the fixture was built with: a developer's commit.gpgsign
  # or merge.ff must not be able to change a verdict, and an ambient
  # GIT_DIR must not be able to redirect the sweep at their own clone.
  # A nil value means "unset", which is how RepoBuilder deletes the keys
  # that would redirect git.
  def with_repo_env(repo)
    saved = repo.env.keys.to_h { |key| [key, ENV[key]] }
    repo.env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
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

  def with_gitflow_fixture(label)
    Dir.mktmpdir("stale-branches-gitflow-#{label}") do |dir|
      yield Fixtures::GitflowRepo.new(File.join(dir, 'gf')).build
    end
  end
end

# Which branch the verdicts are measured against, asked of a real
# repository. Everything the sweep decides rests on this answer, and the
# way it goes wrong is not an error but a plausible wrong branch: the
# sweep runs, reports confidently, and clears work that never reached
# the branch the team ships.
class DefaultBranchTest < OracleTestCase
  def test_the_remote_is_asked_rather_than_main_assumed
    with_flat_fixture('default') do |repo|
      assert_equal 'main', resolve(repo).name
    end
  end

  def test_a_repository_whose_default_is_not_main_answers_with_its_own
    with_gitflow_fixture('default') do |repo|
      default = resolve(repo)

      assert_equal 'develop', default.name
      assert_predicate default, :from_remote?
    end
  end

  # The bug this design makes structurally impossible rather than
  # guarded. refs/remotes/<remote>/HEAD is a local cache written once at
  # clone time and never updated, so in a repository whose default
  # branch has changed since, it names the old one -- and here it names
  # main, a branch that really exists and really is pushed, so nothing
  # about reading it fails or looks wrong. Every verdict would then be
  # measured against main, which is exactly what the gitflow fixture is
  # built to catch.
  def test_a_stale_local_head_ref_is_not_consulted
    with_gitflow_fixture('stale-head') do |repo|
      repo.git('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main')

      assert_equal 'develop', resolve(repo).name
    end
  end

  # --remote selects which repository's ancestry the verdicts are
  # measured against, so it has to reach the answer rather than the
  # default one: the second remote here says main where origin says
  # develop.
  def test_the_named_remote_is_the_one_asked
    with_gitflow_fixture('remotes') do |repo|
      add_second_remote(repo, 'upstream', 'main')

      assert_equal 'develop', resolve(repo, remote: 'origin').name
      assert_equal 'main', resolve(repo, remote: 'upstream').name
    end
  end

  # A misspelled remote must not degrade into a guess. The fallback
  # below is for a remote that exists and cannot be reached; a remote
  # that was never configured is the caller's mistake, and continuing
  # would measure every verdict against a branch nobody named.
  def test_a_remote_that_was_never_configured_is_refused_by_name
    with_gitflow_fixture('no-remote') do |repo|
      message = assert_raises(StaleBranches::Error) { resolve(repo, remote: 'upstrem') }.message

      assert_match(/upstrem/, message)
      assert_match(/origin/, message, 'the refusal did not say which remotes exist')
    end
  end

  # Configured but unreachable -- offline, or a remote whose repository
  # is gone. The sweep still has local evidence worth reporting, so it
  # falls back rather than stopping, and says which branch it fell back
  # to so a wrong answer is visible rather than silent.
  def test_an_unreachable_remote_falls_back_and_says_to_what
    with_flat_fixture('offline') do |repo|
      repo.git('remote', 'add', 'gone', File.join(repo.root, 'no-such-repo.git'))
      default = resolve(repo, remote: 'gone')

      assert_equal 'main', default.name
      refute_predicate default, :from_remote?
    end
  end

  # With nothing local worth falling back to, a guess would be invented
  # rather than degraded. The gitflow repository is one `branch -D` away
  # from that state, and its HEAD is already detached, so main can go.
  def test_an_unreachable_remote_with_nothing_to_fall_back_to_is_refused
    with_gitflow_fixture('offline-empty') do |repo|
      repo.git('branch', '-D', 'main')
      repo.git('remote', 'add', 'gone', File.join(repo.root, 'no-such-repo.git'))

      message = assert_raises(StaleBranches::Error) { resolve(repo, remote: 'gone') }.message

      assert_match(/main/, message, 'the refusal did not say what it looked for')
    end
  end

  # The warning is what makes the fallback survivable: a report measured
  # against a guessed branch that says so can be re-run against the real
  # one, and the same report without it is a confident wrong answer.
  def test_the_fallback_warns_through_the_cli_naming_both_branches
    with_flat_fixture('offline-warning') do |repo|
      repo.git('remote', 'add', 'gone', File.join(repo.root, 'no-such-repo.git'))
      result = sweep(repo, '--remote', 'gone')

      assert_match(/gone/, result.stderr, 'the warning did not say which remote went unanswered')
      assert_match(/main/, result.stderr, 'the warning did not name the branch it fell back to')
    end
  end

  private

  def resolve(repo, remote: 'origin')
    with_repo_env(repo) { git_for(repo, remote: remote).default_branch }
  end

  # A second remote whose own HEAD names a different branch. Built from
  # the fixture's own commits so the two remotes disagree about the
  # default and about nothing else.
  def add_second_remote(repo, name, default_branch)
    path = File.join(repo.root, "#{name}.git")
    repo.git('init', '-q', '-b', default_branch, '--bare', "#{name}.git", dir: repo.root)
    repo.git('remote', 'add', name, path)
    repo.git('push', '-q', name, "#{default_branch}:#{default_branch}")
  end
end

# Which ref the verdicts are actually measured against, once the branch
# NAME is known. The two candidates carry the same name and answer
# differently, and neither fixture can tell them apart -- both build a
# local default branch and its remote-tracking ref at the same commit --
# so these arms make them disagree on purpose.
class MeasuredRefTest < OracleTestCase
  def test_the_remote_tracking_ref_is_what_verdicts_are_measured_against
    with_flat_fixture('measured') do |repo|
      assert_equal 'refs/remotes/origin/main', measure(repo).measured_ref
    end
  end

  # The remote-tracking ref is the remote's own state as of the last
  # fetch, while the local branch is whatever this developer happens to
  # have checked out and advanced. Measuring against a local branch
  # carrying unpushed commits would clear branches whose work reached
  # nobody, which is the one mistake this sweep must never make.
  def test_an_unpushed_commit_on_the_local_default_does_not_move_the_measurement
    with_flat_fixture('unpushed-default') do |repo|
      repo.checkout('main')
      tracking = sha(repo, 'refs/remotes/origin/main')
      repo.git('commit', '-q', '--allow-empty', '-m', 'local-only work on main')

      refute_equal tracking, sha(repo, 'refs/heads/main'), 'the arm did not move the local branch'
      assert_equal tracking, sha(repo, measure(repo).measured_ref)
    end
  end

  # Nothing local mirrors the remote's default branch -- a repository
  # cloned with a single-branch fetch, or one whose refs were pruned.
  # The local branch is the only thing left to measure against.
  def test_with_no_remote_tracking_ref_the_local_branch_is_measured_against
    with_flat_fixture('no-tracking') do |repo|
      repo.git('update-ref', '-d', 'refs/remotes/origin/main')

      assert_equal 'refs/heads/main', measure(repo).measured_ref
    end
  end

  # Behind the remote because nobody fetched. The verdicts stay
  # trustworthy in the direction that matters -- an older tip clears
  # fewer branches, so the sweep keeps more than it needs to -- but a
  # keep the caller reads as "this work never landed" may only mean
  # "this work landed after your last fetch".
  def test_a_tracking_ref_the_remote_has_moved_past_is_reported
    with_flat_fixture('stale-tracking') do |repo|
      rewind_tracking_ref(repo)

      assert_match(/fetch/, warnings(repo), 'the warning did not name the repair')
      assert_match(%r{origin/main}, warnings(repo), 'the warning did not name the stale ref')
    end
  end

  def test_a_current_tracking_ref_is_reported_as_nothing_at_all
    with_flat_fixture('current-tracking') do |repo|
      assert_empty measure(repo).warnings
    end
  end

  # The sweep is immune to this ref by construction, and the caller's
  # other tools are not: every `git branch -vv`, every `origin/HEAD`
  # shorthand, reads the branch it names. Knowing the truth is a
  # by-product of having asked the remote, so it costs nothing to say.
  def test_a_stale_head_ref_is_reported_with_the_command_that_repairs_it
    with_gitflow_fixture('stale-head-warning') do |repo|
      repo.git('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main')
      warning = warnings(repo)

      assert_match(/set-head/, warning, 'the warning did not name the repair')
      assert_match(/develop/, warning, 'the warning did not name the real default branch')
    end
  end

  def test_no_head_ref_at_all_is_reported_as_nothing
    with_gitflow_fixture('no-head-ref') do |repo|
      refute_match(/set-head/, warnings(repo))
    end
  end

  private

  def measure(repo, remote: 'origin')
    with_repo_env(repo) { StaleBranches::Sweep.new(git_for(repo, remote: remote)).run }
  end

  def warnings(repo)
    measure(repo).warnings.join("\n")
  end

  def sha(repo, ref)
    repo.git('rev-parse', ref).strip
  end

  # Pushes a commit and then rewinds the local record of it, which is
  # the state a repository is in whenever someone else pushed and this
  # clone has not fetched since.
  def rewind_tracking_ref(repo)
    behind = sha(repo, 'refs/remotes/origin/main')
    repo.checkout('main')
    repo.git('commit', '-q', '--allow-empty', '-m', 'work someone else pushed')
    repo.git('push', '-q', 'origin', 'main')
    repo.git('update-ref', 'refs/remotes/origin/main', behind)
  end
end

# What the sweep considers, and what it refuses to consider, against
# real repositories. The decision table itself is graded above; these
# arms check that the facts fed into it are the ones git reports.
class EnumerationTest < OracleTestCase
  FLAT_ORACLE = File.expand_path('fixtures/expected-degraded.txt', __dir__)
  GITFLOW_ORACLE = File.expand_path('fixtures/gitflow-expected-degraded.txt', __dir__)

  def test_every_local_branch_is_accounted_for
    with_flat_fixture('enumeration') do |repo|
      expected = repo.local_refs.map { |ref| ref.delete_prefix('refs/heads/') }

      assert_equal expected.sort, measure(repo).branches.sort
    end
  end

  # Enumeration reads full refnames because the short form is the
  # ambiguous one: `amb` and `s-tag-shadow` are each both a branch and a
  # tag in these fixtures, and a lookup by bare name is answered about
  # the tag.
  def test_a_branch_shadowed_by_a_tag_is_still_enumerated
    with_flat_fixture('shadowed') do |repo|
      assert_includes measure(repo).branches, 's-tag-shadow'
    end
  end

  # git refuses to CREATE a branch whose name looks like a flag --
  # `git branch -- -D` and `git checkout -b -D` both decline -- but that
  # is porcelain's own guard, not a rule about refs:
  # `check-ref-format refs/heads/-D` calls it valid and `update-ref`
  # makes one without complaint. So a repository can hold one, and
  # for-each-ref lists it, which is what puts it in front of this sweep.
  def test_a_branch_named_like_a_flag_is_enumerated_rather_than_skipped
    with_flat_fixture('flag-shaped') do |repo|
      plant_flag_shaped_branch(repo)

      assert_includes measure(repo).branches, '-D'
    end
  end

  def test_the_flat_fixtures_protections_are_the_ones_its_table_demands
    with_flat_fixture('protections') do |repo|
      assert_protections_match(FLAT_ORACLE, repo)
    end
  end

  # Graded from a detached HEAD, where the current-branch rule has
  # nothing to protect and every other protection must still fire.
  def test_the_gitflow_fixtures_protections_are_the_ones_its_table_demands
    with_gitflow_fixture('protections') do |repo|
      assert_protections_match(GITFLOW_ORACLE, repo)
    end
  end

  # Standing on a branch protects it, and the protection is released
  # when HEAD moves away. Asserting only the first half passes a sweep
  # that protects the branch it started on forever.
  def test_moving_head_moves_the_protection
    with_flat_fixture('head-moves') do |repo|
      repo.checkout('a-squash-clean')
      protections = protections_of(repo)

      assert_equal 'protected:current', protections['a-squash-clean']
      refute_includes protections.keys, 'o-current'
    end
  end

  # The invocation with no -C at all, which resolves the repository from
  # the working directory. Every other arm here names one explicitly, so
  # without this the ordinary way a person runs the tool goes untested.
  def test_a_relative_target_resolves_from_the_working_directory
    with_flat_fixture('relative') do |repo|
      Dir.chdir(repo.work) do
        sweep = with_repo_env(repo) { StaleBranches::Sweep.new(git_for(repo, dir: '.')).run }

        assert_includes sweep.branches, 'main'
      end
    end
  end

  private

  def assert_protections_match(oracle, repo)
    expected = Fixtures::Oracle.load(oracle)
                              .select { |row| row.reason.start_with?('protected:') }
                              .to_h { |row| [row.branch, row.reason] }

    assert_equal expected, protections_of(repo)
  end

  def protections_of(repo)
    rows = measure(repo).rows.select { |row| row.reason.start_with?('protected:') }
    assert_equal %w[KEEP], rows.map(&:verdict).uniq, 'a protected branch was not kept'
    rows.to_h { |row| [row.branch, row.reason] }
  end

  def measure(repo)
    with_repo_env(repo) { StaleBranches::Sweep.new(git_for(repo)).run }
  end

  # `git branch` will not make one of these, so the ref is written
  # directly. The sweep has to survive one existing, because the way it
  # goes wrong is silent: `git branch -d -D` exits saying a branch name
  # is required, having deleted nothing, while the caller reads success.
  def plant_flag_shaped_branch(repo)
    repo.git('update-ref', 'refs/heads/-D', repo.git('rev-parse', 'main').strip)
  end
end

# The cheap first pass: a branch whose tip the default branch already
# contains adds nothing to it, and git answers that by walking commits
# rather than comparing content. Everything it clears is clear beyond
# argument, which is why it runs before the expensive checks.
class Pass1Test < OracleTestCase
  def test_the_flat_tables_ancestor_row_is_the_one_ancestry_clears
    with_flat_fixture('pass1') do |repo|
      assert_stage_matches(EnumerationTest::FLAT_ORACLE, repo, 'pass1:ancestor')
    end
  end

  # Ancestry of DEVELOP. Every branch here is an ancestor of something,
  # and measuring against main would clear the wrong ones.
  def test_the_gitflow_tables_ancestor_row_is_measured_against_its_own_default
    with_gitflow_fixture('pass1') do |repo|
      assert_stage_matches(EnumerationTest::GITFLOW_ORACLE, repo, 'pass1:ancestor')
    end
  end

  # The trap both fixtures build, and the reason enumeration keeps full
  # refnames. Asked about a bare name, git resolves refs/tags before
  # refs/heads -- so `merge-base --is-ancestor s-tag-shadow main` is
  # answered about the tag, which points AT the default branch, and the
  # branch is cleared for holding nothing while its own work has never
  # landed. That is a wrongful deletion, not a wrongful keep.
  def test_a_tag_at_the_default_branch_does_not_clear_the_branch_it_shadows
    with_flat_fixture('tag-trap') do |repo|
      sweep = measure(repo)

      refute_includes stage_of(sweep, 'pass1:ancestor').keys, 's-tag-shadow'
      assert_includes sweep.candidates, 's-tag-shadow',
                      'the shadowed branch was decided by something, having no evidence yet'
    end
  end

  def test_a_tag_at_the_default_branch_does_not_clear_it_in_the_gitflow_repository_either
    with_gitflow_fixture('tag-trap') do |repo|
      refute_includes stage_of(measure(repo), 'pass1:ancestor').keys, 'amb'
    end
  end

  # Ancestry is asked of the remote-tracking ref, so a local default
  # branch carrying commits nobody else has cannot clear anything: the
  # branch below is an ancestor of the local main and of nothing the
  # remote knows about.
  def test_ancestry_of_an_unpushed_local_default_clears_nothing
    with_flat_fixture('pass1-unpushed') do |repo|
      repo.checkout('main')
      repo.git('merge', '-q', '--no-ff', 'g-open', '-m', 'merge g-open locally only')

      refute_includes stage_of(measure(repo), 'pass1:ancestor').keys, 'g-open'
    end
  end

  private

  def assert_stage_matches(oracle_path, repo, stage)
    expected = Fixtures::Oracle.load(oracle_path)
                               .select { |row| row.reason == stage }
                               .to_h { |row| [row.branch, row.verdict] }
    refute_empty expected, "the table demands nothing of #{stage}"

    assert_equal expected, stage_of(measure(repo), stage)
  end

  def stage_of(sweep, stage)
    sweep.rows.select { |row| row.reason == stage }.to_h { |row| [row.branch, row.verdict] }
  end

  def measure(repo)
    with_repo_env(repo) { StaleBranches::Sweep.new(git_for(repo)).run }
  end
end

# The wiring between the pure parser and the process. A refusal has to
# reach stderr under the tool's own name and exit non-zero, or a
# scripted caller reads a sweep that never ran as one that found
# nothing.
class CliRefusalTest < OracleTestCase
  def setup
    @dir = Dir.mktmpdir('stale-branches-argv')
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_a_refused_argv_exits_non_zero_naming_the_tool
    result = abort_result(['-C', @dir, '--bogus'])

    assert_equal 1, result.status
    assert_equal 'stale-branches: invalid option: --bogus', result.message
  end

  # The target is an empty directory rather than a repository, so a
  # usage request that fell through to the sweep would fail loudly here
  # rather than printing and returning.
  def test_help_prints_usage_and_sweeps_nothing
    assert_includes cli_stdout(['-C', @dir, '--help']), 'Usage: stale-branches'
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

    capture_io do
      run_cli(self.class.target)
    rescue SystemExit
      # Whether the guard refused is all this probe reports on. What the
      # CLI then makes of a target it was allowed to reach belongs to
      # another test, and an abort here would otherwise end the process:
      # SystemExit is not a StandardError, so minitest lets it through.
      nil
    end
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
    with_gitflow_fixture('oracle') do |repo|
      result = sweep(repo)
      assert_matches_oracle(Fixtures::Oracle.load(ORACLE), result)
      refute_git_complaints(result)
    end
  end

  # The reason a forge was not consulted belongs in a warning, once, not
  # in a per-branch reason. Reporting "no pull request" for a lookup that
  # never happened states an absence nobody checked.
  def test_no_row_claims_a_pull_request_was_absent
    with_gitflow_fixture('reasons') do |repo|
      rows = sweep(repo).rows
      # A report with no rows satisfies every claim about what its rows
      # may not say, which is the empty pass the oracle loader refuses
      # for the same reason.
      refute_empty rows, 'the sweep reported nothing, so this test asserted nothing'

      offenders = rows.select { |row| row.reason.include?('no-pull-request') }
      assert_empty offenders.map(&:branch),
                   'a reason claimed a pull request was absent without checking'
    end
  end
end
