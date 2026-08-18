# frozen_string_literal: true

# Checks the oracle tables under test/fixtures/ against the fixture
# repositories they describe, and both against the vocabulary they share.
#
# The tables are the specification bin/stale-branches is built against:
# one row per branch, naming the verdict the sweep must reach and the
# reason key its report must carry. The sweep is graded against them
# further down; the table half above carries more weight than it first
# appears, because each of these can go wrong while every other test
# stays green:
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
require_relative 'fixtures/forge_stub'
require_relative 'fixtures/oracle'
require_relative 'fixtures/pull_requests'

require 'open3'
require 'tmpdir'

# The verdict tables, named once. Four separate expansions of these
# paths had already forced tests to reach into a sibling class they had
# nothing else to do with.
#
# Two of the three describe the same flat fixture and differ only in
# whether the forge answered, which is what makes the pair a statement
# of what consulting a forge is worth. The forge table is the full
# specification and the one whose header documents the vocabulary; the
# degraded tables are what the same fixtures must report when no pull
# request can be reached.
FLAT_FORGE_ORACLE = File.expand_path('fixtures/expected.txt', __dir__)
FLAT_DEGRADED_ORACLE = File.expand_path('fixtures/expected-degraded.txt', __dir__)
GITFLOW_ORACLE = File.expand_path('fixtures/gitflow-expected-degraded.txt', __dir__)
GITFLOW_FORGE_ORACLE = File.expand_path('fixtures/gitflow-expected.txt', __dir__)

class OracleTableTest < Minitest::Test
  FLAT = FLAT_DEGRADED_ORACLE
  FLAT_FORGE = FLAT_FORGE_ORACLE
  GITFLOW = GITFLOW_ORACLE
  GITFLOW_FORGE = GITFLOW_FORGE_ORACLE

  # Every table, for the guarantees that hold of all of them.
  ALL = [FLAT_FORGE, FLAT, GITFLOW_FORGE, GITFLOW].freeze

  def test_the_flat_table_lists_exactly_the_branches_its_fixture_builds
    assert_tables_agree(Fixtures::BranchRepo, FLAT, 'flat')
  end

  # The two flat tables describe one repository, so a branch added to
  # the fixture has to reach both. One of them silently omitting it
  # would leave the sweep ungraded on that branch in exactly one mode.
  def test_the_flat_forge_table_lists_exactly_the_branches_its_fixture_builds
    assert_tables_agree(Fixtures::BranchRepo, FLAT_FORGE, 'flat')
  end

  def test_the_gitflow_table_lists_exactly_the_branches_its_fixture_builds
    assert_tables_agree(Fixtures::GitflowRepo, GITFLOW, 'gitflow')
  end

  def test_the_gitflow_forge_table_lists_exactly_the_branches_its_fixture_builds
    assert_tables_agree(Fixtures::GitflowRepo, GITFLOW_FORGE, 'gitflow')
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

  # Each table is held to the stages it actually exercises. A degraded
  # table cannot demand a proof-b deletion -- reaching no forge is what
  # makes it degraded -- so requiring every stage of every table would
  # be a demand no correct table could meet. What each one must do is
  # reach a deletion through every deciding stage it names at all, which
  # is the same guarantee for the table it is asked of.
  def test_every_table_demands_a_deletion_from_every_stage_it_exercises
    ALL.each do |path|
      rows = Fixtures::Oracle.load(path)
      table = File.basename(path)
      named = rows.map { |row| Fixtures::Oracle.stage(row.reason) }.uniq

      (self.class.deleting_stages & named).each do |stage|
        deletions = rows.count do |row|
          row.verdict == 'DELETE' && Fixtures::Oracle.stage(row.reason) == stage
        end
        assert_operator deletions, :>, 0, "#{table} asks for no deletion decided by #{stage}"
      end

      assert_operator rows.count { |row| row.verdict == 'KEEP' }, :>, 0,
                      "#{table} asks for no keeps at all"
    end
  end

  # And across the tables together, every deciding stage must reach a
  # deletion somewhere. Without this, a stage added to REASONS and named
  # by no row at all would satisfy the per-table test vacuously -- it
  # only asks about stages a table names.
  def test_every_deciding_stage_reaches_a_deletion_in_some_table
    deleting = ALL.flat_map { |path| Fixtures::Oracle.load(path) }
                  .select { |row| row.verdict == 'DELETE' }
                  .map { |row| Fixtures::Oracle.stage(row.reason) }.uniq

    assert_empty self.class.deleting_stages - deleting,
                 'these stages can decide a deletion and no table asks for one'
  end

  # Every reason the vocabulary documents must be demanded by some row in
  # some table. A key nothing claims is a rule the sweep can omit
  # entirely with nothing going red -- which is not a hypothetical: the
  # current-branch protection was documented, implemented nowhere, and
  # graded by nothing, and a classifier with that protection deleted
  # outright scored full marks on both tables.
  def test_every_documented_reason_is_demanded_by_some_row
    claimed = ALL.flat_map { |path| Fixtures::Oracle.load(path).map(&:reason) }.uniq
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
    ALL.each do |path|
      Fixtures::Oracle.load(path).each do |row|
        refute_empty row.why, "#{File.basename(path)} row #{row.branch} says nothing about why"
      end
    end
  end

  def test_the_table_header_documents_exactly_the_enforced_vocabulary
    documented = File.readlines(FLAT_FORGE).filter_map do |line|
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
  FLAT = FLAT_DEGRADED_ORACLE
  FLAT_FORGE = FLAT_FORGE_ORACLE
  GITFLOW = GITFLOW_ORACLE

  # The reasons decided by looking at the repository rather than at a
  # name. Each is a falsifiable claim about git's own answer, so each can
  # be checked here without a sweep existing.
  EVIDENCE_REASONS = %w[
    pass1:ancestor proof-a:content-landed proof-a:tip-only proof-a:conflict
    kept:not-landed
  ].freeze

  # The reasons decided by what the forge says rather than by the
  # repository. protected:open-pr is here rather than with its own
  # family: every other protection is decided by a name and costs
  # nothing, and this one is a claim about the canned records, so
  # assuming it is name-decided would leave it graded by nothing.
  FORGE_REASONS = %w[
    protected:open-pr proof-b:pr-merged proof-b:pr-tip-differs
    proof-b:pr-closed proof-b:pr-from-fork proof-b:pr-other-base proof-b:no-pr
  ].freeze

  # The rows that say "protected" are graded elsewhere; these are the ones
  # that say what git will report, and they are the rows a wrong fixture
  # would silently invalidate. proof-a:conflict matters most: it is the
  # only route to the forge, so a row claiming it that does not actually
  # conflict removes a pull-request rule's only subject, and the rule
  # could then be dropped from the sweep with nothing going red.
  # Everything the vocabulary documents is either decided by looking at
  # the repository (graded here) or decided by a name (graded by the
  # protection tests). A key that is neither is one this file quietly
  # stopped grading -- which is what happens the moment PR 3 adds its
  # proof-b keys, unless this list moves with it.
  def test_every_reason_is_either_graded_here_or_decided_by_a_name
    name_decided = Fixtures::Oracle::REASONS
                   .select { |reason| Fixtures::Oracle.stage(reason) == 'protected' } - FORGE_REASONS
    ungraded = Fixtures::Oracle::REASONS - name_decided - EVIDENCE_REASONS - FORGE_REASONS

    assert_empty ungraded, 'these reasons are checked against git or the records by nothing'
  end

  # The same guarantee the evidence rows get, for the half of the
  # specification git cannot see. A record that stopped describing what
  # its row claims -- a state changed, a base renamed, the fork flag
  # dropped -- would leave the sweep graded against a rule with no
  # subject, and every test here would stay green while it happened.
  def test_the_forge_tables_forge_reasons_are_what_the_canned_records_say
    assert_forge_reasons_match(Fixtures::BranchRepo, FLAT_FORGE, 'main',
                               Fixtures::PullRequests::RECORDS, 'flat')
  end

  def test_the_gitflow_forge_tables_forge_reasons_are_what_the_canned_records_say
    assert_forge_reasons_match(Fixtures::GitflowRepo, GITFLOW_FORGE_ORACLE,
                               Fixtures::GitflowRepo::DEFAULT_BRANCH,
                               Fixtures::PullRequests::GITFLOW_RECORDS, 'gitflow')
  end

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
    end
  end

  def test_the_flat_fixture_builds_a_second_worktree
    with_flat do |repo|
      assert_includes repo.git('worktree', 'list', '--porcelain'),
                      'branch refs/heads/n-worktree',
                      'n-worktree must be checked out in a second worktree'
    end
  end

  def test_the_flat_fixture_builds_its_remote_ref_traps
    with_flat do |repo|
      Fixtures::BranchRepo::PUSHED_THEN_DELETED.each do |branch|
        assert_empty repo.git('ls-remote', '--heads', 'origin', branch).strip,
                     "#{branch} must have had its remote ref deleted"
      end

      Fixtures::BranchRepo::PUSHED_AND_KEPT.each do |branch|
        refute_empty repo.git('ls-remote', '--heads', 'origin', branch).strip,
                     "#{branch} must keep its remote ref, so a forge can answer for it"
      end
    end
  end

  def test_the_flat_fixture_builds_a_branch_tracking_a_deleted_local_one
    with_flat do |repo|
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
      refute ancestor?(repo, 'main', Fixtures::GitflowRepo::DEFAULT_BRANCH),
             'main must hold work develop does not, or its keep is decided by the evidence'
    end
  end

  def test_the_gitflow_fixtures_protected_branches_would_otherwise_be_deletable
    with_gitflow do |repo|
      default = Fixtures::GitflowRepo::DEFAULT_BRANCH
      [Fixtures::GitflowRepo::RELEASE, Fixtures::GitflowRepo::ANCESTOR].each do |branch|
        assert ancestor?(repo, branch, default), "#{branch} must be an ancestor of #{default}"
      end
    end
  end

  def test_the_gitflow_fixture_builds_the_tag_that_shadows_a_branch
    with_gitflow { |repo| assert_tag_shadows(repo, Fixtures::GitflowRepo::TAG_SHADOWED) }
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
    return 'kept:not-landed' unless tree == default_tree

    history_landed?(repo, default, ref, default_tree) ? 'proof-a:content-landed' : 'proof-a:tip-only'
  end

  # Reimplements the forge half of the header's documented procedure
  # against the canned records, in its documented order. Only asked
  # about branches whose row names a forge reason, which are exactly the
  # branches that reach the forge at all.
  def assert_forge_reasons_match(builder, table, default, record_set, label)
    rows = Fixtures::Oracle.load(table).select { |row| FORGE_REASONS.include?(row.reason) }
    refute_empty rows, "#{label}: no row states a forge reason at all"

    with_fixture(builder, label) do |repo|
      records = Fixtures::PullRequests.data(repo, records: record_set)
                                      .fetch(Fixtures::PullRequests::CWD)
      rows.each do |row|
        assert_equal row.reason, forge_reason_for(repo, records, row.branch, default),
                     "#{label}: the table says #{row.branch} is #{row.reason}, " \
                     'the records disagree'
      end
    end
  end

  def forge_reason_for(repo, records, branch, default = 'main')
    mine = records.select { |record| record['headRefName'] == branch }
    return 'protected:open-pr' if mine.any? { |record| record['state'] == 'OPEN' }
    return 'proof-b:no-pr' if mine.empty?

    merged = mine.select { |record| record['state'] == 'MERGED' }
    return 'proof-b:pr-closed' if merged.empty?

    same_repo = merged.reject { |record| record['isCrossRepository'] }
    return 'proof-b:pr-from-fork' if same_repo.empty?

    on_default = same_repo.select { |record| record['baseRefName'] == default }
    return 'proof-b:pr-other-base' if on_default.empty?

    tip = repo.git('rev-parse', "refs/heads/#{branch}").strip
    on_default.any? { |record| record['headRefOid'] == tip } ? 'proof-b:pr-merged' : 'proof-b:pr-tip-differs'
  end

  # Every commit the branch does not share with the default branch,
  # asked the question its tip was asked. A tip that adds nothing says
  # nothing about what the history discarded on the way there.
  def history_landed?(repo, default, ref, default_tree)
    commits = repo.git('rev-list', "refs/heads/#{default}..#{ref}").lines(chomp: true)
    commits.all? do |commit|
      tree, merged = merge_tree(repo, default, commit)
      merged && tree == default_tree
    end
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
    assert_empty Fixtures::RepoBuilder::LOCATION_KEYS - CliTestCase::GIT_LOCATION_ENV_KEYS,
                 'RepoBuilder unsets these per command, but no CLI test body is free of them'
    assert_empty CliTestCase::GIT_LOCATION_ENV_KEYS - Fixtures::RepoBuilder::LOCATION_KEYS,
                 'CliTestCase scrubs these, but a fixture build still inherits them'
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

# The sweep itself, graded against the tables above.
#
# The CLI is driven IN-PROCESS rather than as a subprocess, for three
# reasons that each bite differently. CI's coverage guard passes on a
# merely-loaded file, so a subprocess sweep would report zero coverage
# while CI stayed green. Minitest's capture_io redirects Ruby's $stdout
# object rather than file descriptor 1, so a child's output escapes it
# entirely. And `ruby` itself fails when invoked from inside a fixture
# directory under a version manager.
CLI_PATH = File.expand_path('../bin/stale-branches', __dir__)
load CLI_PATH

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

  # A different knob from --remote, and the difference is the whole
  # reason both exist: --remote selects which git ancestry is measured
  # against, --repo selects which GitHub repository is asked about pull
  # requests. On a fork they name different places.
  def test_repo_names_the_forge_project_to_ask_about
    assert_equal 'octo/upstream', parse('--repo', 'octo/upstream').repo
  end

  def test_no_repo_is_named_until_one_is_asked_for
    assert_nil parse.repo, 'naming a repository by default would guess at one'
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
    assert_equal 'missing argument: --repo', refusal('--repo')
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
    assert_match(/--delete/, refusal('--repo', '--delete'))
  end

  # Last-wins would silently discard the first value, which for -C means
  # sweeping a repository the caller also named and did not get.
  def test_a_repeated_value_option_is_refused_rather_than_last_winning
    assert_equal 'duplicate -C', refusal('-C', '/tmp/a', '-C', '/tmp/b')
    assert_equal 'duplicate --remote', refusal('--remote', 'a', '--remote', 'b')
    assert_equal 'duplicate --repo', refusal('--repo', 'a/b', '--repo', 'c/d')
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

  # `worktree list` always lists the branch HEAD is on, so these two
  # rules overlap on every real repository and only their order decides
  # which reason is reported. The table above kept them artificially
  # apart, which is the one shape a repository never has.
  def test_the_current_branch_is_current_rather_than_a_worktree_of_its_own
    assert_equal 'protected:current', protection('feature', worktrees: %w[feature parked])
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

# The report, which is the whole product in the default mode and the
# only thing anyone reads. It is rendered from rows rather than printed
# as they are decided, so the ordering is the reader's rather than the
# sweep's, and it is graded by feeding it back through the same parser
# the oracle uses -- a renderer whose output that parser cannot read
# would leave every table passing against a report no one can check.
# The matcher five tests rest on. Each of those asserts the match set is
# EMPTY, so nothing about them would notice the regex silently ceasing
# to match -- and the defect they exist to catch (a full refname handed
# to `git branch -d`, which deletes nothing while exiting clean) leaves
# no evidence except the noise git makes on the way past.
class GitComplaintMatcherTest < Minitest::Test
  def test_it_matches_what_git_actually_says_when_this_sweep_goes_wrong
    ["error: branch 'refs/heads/x' not found\n",
     "fatal: branch name required\n",
     "error: the branch 'a-squash-clean' is not fully merged\n",
     "fatal: 'nope' does not appear to be a git repository\n"].each do |complaint|
      assert_match SweepRun::GIT_COMPLAINT, complaint, "#{complaint.strip.inspect} went unnoticed"
    end
  end

  # Anchored to the start of a line, so an ordinary report row and a
  # warning that quotes git mid-sentence are not complaints.
  def test_it_does_not_match_the_reports_own_output
    ["main                    keep     protected:default\n",
     "26 branches, 4 marked DELETE\n",
     "stale-branches: could not ask gone (fatal: no such repository); measuring against x\n"]
      .each do |line|
      refute_match SweepRun::GIT_COMPLAINT, line, "#{line.strip.inspect} was read as a complaint"
    end
  end
end

class ReportTest < Minitest::Test
  ROWS = [
    StaleBranches::Row.new('main', 'KEEP', 'protected:default'),
    StaleBranches::Row.new('a-squash-clean', 'DELETE', 'proof-a:content-landed'),
    StaleBranches::Row.new('l-tracks-deleted-local', 'KEEP', 'kept:not-landed')
  ].freeze

  def test_every_row_survives_the_round_trip_through_the_oracles_parser
    parsed = SweepRun.parse(StaleBranches.render_report(ROWS))

    assert_equal ROWS.sort_by(&:branch).map { |row| [row.branch, row.verdict, row.reason] },
                 parsed.map { |row| [row.branch, row.verdict, row.reason] }
  end

  # The ordering is the renderer's own stated reason for existing -- a
  # report is read once now and once against the last run, and a stable
  # order is what makes the difference between them legible. Asserted
  # from rows deliberately supplied out of order, because comparing
  # against the input order (or against a hash, as the oracle does)
  # leaves `rows.reverse` passing every test in this file.
  def test_the_report_is_ordered_by_branch_name_whatever_order_it_was_given
    given = ROWS.sort_by(&:branch).reverse

    assert_equal ROWS.map(&:branch).sort,
                 SweepRun.parse(StaleBranches.render_report(given)).map(&:branch)
  end

  # Only the rows are rows. A header and a summary make the report
  # readable and must not read back as branches, which the parser
  # decides for itself -- so what is asserted here is the count.
  def test_nothing_but_the_rows_reads_back_as_a_row
    assert_equal ROWS.length, SweepRun.parse(StaleBranches.render_report(ROWS)).length
  end

  # DELETE shouts and keep does not. The asymmetry is the point: a
  # reader skimming a long report is looking for what the sweep proposes
  # to destroy.
  def test_a_deletion_is_the_only_verdict_in_capitals
    report = StaleBranches.render_report(ROWS)

    assert_match(/^a-squash-clean\s+DELETE\s+proof-a:content-landed$/, report)
    assert_match(/^main\s+keep\s+protected:default$/, report)
    refute_match(/\bKEEP\b/, report, 'a keep shouted, so DELETE no longer stands out')
  end

  def test_the_columns_line_up_whatever_the_names_are_wide
    lines = StaleBranches.render_report(ROWS).lines.grep(SweepRun::REPORT_LINE)
    columns = lines.map { |line| line.index(/DELETE|keep/) }

    assert_equal 1, columns.uniq.length, "the verdict column moved: #{columns.inspect}"
  end

  # A branch named like a flag has to survive being printed as well as
  # being enumerated, and a report is where a name that starts with a
  # dash would be least expected.
  def test_a_branch_named_like_a_flag_renders_and_reads_back
    rows = [StaleBranches::Row.new('-D', 'DELETE', 'pass1:ancestor')]

    assert_equal ['-D'], SweepRun.parse(StaleBranches.render_report(rows)).map(&:branch)
  end

  def test_the_summary_counts_the_branches_and_the_deletions
    summary = StaleBranches.render_report(ROWS).lines.last

    assert_match(/3 branches/, summary)
    assert_match(/1 marked DELETE/, summary)
  end

  # An empty repository is not an error, and a report with no rows must
  # not claim otherwise.
  def test_a_repository_with_no_branches_reports_none_rather_than_failing
    assert_match(/0 branches/, StaleBranches.render_report([]))
  end
end

# Shared driving and assertions. Each fixture gets its own subclass so a
# failure names the repository shape it came from.
class OracleTestCase < CliTestCase
  # The degraded half: a gh that is present and fails every question,
  # which is what "not authenticated", "offline", and "not a GitHub
  # remote" all look like from here. Served rather than shimmed, because
  # the sweep is REQUIRED to ask and then degrade -- a shim that flunked
  # on contact would make the degraded oracle a test of a sweep that
  # never asks, and the finished tool asks.
  #
  # The stub is what stands between these tests and a developer's own
  # authenticated gh; nothing here can reach the real client.
  def served_commands
    { 'gh' => Fixtures::ForgeStub.program }
  end

  # The stub reads both from the environment, and a machine value for
  # either must not survive into a run.
  def extra_scrubbed_env_keys
    %w[STUB_GH_PRS STUB_GH_FAIL]
  end

  # Set here rather than per test so that every subclass of this one is
  # degraded unless it says otherwise: a suite that forgot would
  # silently be graded against the wrong table.
  def before_setup
    super
    ENV['STUB_GH_FAIL'] = '1'
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
    StaleBranches::CLI.run(argv)
  end

  # An abort inside the sweep is turned into a failure of the test that
  # provoked it. Kernel#abort raises SystemExit, which is not a
  # StandardError, so minitest lets it through and it ends the whole
  # RUN -- every later test silently unreported, and no message saying
  # which one aborted or why. Naming it here costs one rescue and turns
  # that into an ordinary red test.
  def sweep(repo, *extra)
    with_repo_env(repo) do
      failure = nil
      out, err = capture_io do
        run_cli(['-C', repo.work, *extra])
      rescue SystemExit => e
        failure = e
      end
      flunk "the sweep aborted (exit #{failure.status}):\n#{err}" if failure

      SweepRun::Result.new(SweepRun.parse(out), out, err)
    end
  end

  # The command layer, driven directly for the questions a report cannot
  # be asked yet. It goes through the same refusal run_cli gets, so a
  # test reaching past the argv cannot reach past the guard with it.
  # The guard is given the directory the Git will actually use, not the
  # fixture's -- otherwise a test passing dir: outside the temporary
  # directory reaches past exactly the refusal this exists to apply.
  def git_for(repo, remote: 'origin', dir: repo.work)
    guard_cli_invocation(['-C', dir])
    StaleBranches::Git.new(dir: dir, remote: remote)
  end

  # The forge the sweep is given. It runs gh as a child in this
  # directory, so it goes through the same refusal git_for does: a test
  # naming a directory outside the throwaway must not reach past the
  # guard by asking the forge instead.
  def forge_for(dir, repo: nil)
    guard_cli_invocation(['-C', dir])
    StaleBranches::Forge.new(dir: dir, repo: repo)
  end

  # A sweep wired the way the CLI wires one, so a test driving stages
  # directly is driving the same object the report comes from.
  def sweep_for(git, dir: git.dir)
    StaleBranches::Sweep.new(git, forge_for(dir))
  end

  # A machine with no gh installed at all, which is the other half of
  # the degradation and a different code path from a gh that runs and
  # fails. PATH is rebuilt from one directory holding a link to git
  # rather than merely emptied, because the sweep still has to run git
  # -- and rather than merely dropping the stub's directory, because
  # that would expose a developer's own authenticated gh to a test whose
  # whole premise is that there isn't one.
  def with_no_forge_installed
    Dir.mktmpdir('only-git') do |dir|
      File.symlink(resolve_on_path('git'), File.join(dir, 'git'))
      saved = ENV.fetch('PATH')
      ENV['PATH'] = dir
      begin
        yield
      ensure
        ENV['PATH'] = saved
      end
    end
  end

  def resolve_on_path(command)
    found = ENV.fetch('PATH').split(File::PATH_SEPARATOR)
               .map { |dir| File.join(dir, command) }
               .find { |path| File.executable?(path) }
    found || flunk("#{command} is not on PATH, so this test cannot run")
  end

  # Serves this repository's own records for the length of the block,
  # and turns off the failure this class leaves on. A test is in the
  # degraded mode until it says otherwise, so a suite that forgot is
  # graded against the degraded table rather than silently against the
  # wrong one. The file is written outside the repository: the sweep
  # reads nothing from the working tree, but a fixture that quietly
  # gained an untracked file would be one no clone produces.
  def with_forge(repo, key: Fixtures::PullRequests::CWD, failing: false,
                 records: Fixtures::PullRequests::RECORDS)
    Dir.mktmpdir('stale-branches-forge') do |dir|
      path = File.join(dir, 'pull-requests.json')
      ENV['STUB_GH_PRS'] = Fixtures::PullRequests.write(repo, path, key: key, records: records)
      failing ? ENV['STUB_GH_FAIL'] = '1' : ENV.delete('STUB_GH_FAIL')
      yield
    end
  end

  # The same records, served as a clone of a fork would see them: the
  # repository gh resolves from the working directory has none, and the
  # upstream project has them all.
  def with_forked_forge(repo)
    Dir.mktmpdir('stale-branches-fork') do |dir|
      path = File.join(dir, 'pull-requests.json')
      ENV['STUB_GH_PRS'] = Fixtures::PullRequests.write_fork(repo, path)
      ENV.delete('STUB_GH_FAIL')
      yield
    end
  end

  # A second remote, added to a repository already built. It is given
  # the same URL as origin, so what it advertises is identical and the
  # verdicts cannot change: this arm is about which knob the sweep
  # reads, not about two remotes disagreeing.
  def add_upstream_remote(repo, name: 'upstream')
    repo.git('remote', 'add', name, repo.origin)
    repo.git('fetch', '-q', name)
    name
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

  # `git branch` will not make one of these, so the ref is written
  # directly. The sweep has to survive one existing, because the way it
  # goes wrong is silent: `git branch -d -D` exits saying a branch name
  # is required, having deleted nothing, while the caller reads success.
  def plant_flag_shaped_branch(repo)
    repo.git('update-ref', 'refs/heads/-D', repo.git('rev-parse', 'main').strip)
  end

  def with_gitflow_fixture(label)
    Dir.mktmpdir("stale-branches-gitflow-#{label}") do |dir|
      yield Fixtures::GitflowRepo.new(File.join(dir, 'gf')).build
    end
  end

  # Drives a sweep for its verdicts rather than its report, which is
  # what lets a stage be graded before there is anything to print.
  def measure(repo, remote: 'origin')
    with_repo_env(repo) { sweep_for(git_for(repo, remote: remote)).run }
  end

  # Every row a table demands of one stage, against every row the sweep
  # reached by it. Compared as whole sets in both directions, so a stage
  # that reaches the right verdict for an extra branch is a failure too.
  def assert_stage_matches(oracle_path, sweep, stage)
    expected = Fixtures::Oracle.load(oracle_path)
                               .select { |row| row.reason == stage }
                               .to_h { |row| [row.branch, row.verdict] }
    refute_empty expected, "the table demands nothing of #{stage}"

    assert_equal expected, stage_of(sweep, stage), "#{stage} disagrees with the table"
  end

  def stage_of(sweep, stage)
    sweep.rows.select { |row| row.reason == stage }.to_h { |row| [row.branch, row.verdict] }
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
      add_unreachable_remote(repo, 'gone')
      default = resolve(repo, remote: 'gone')

      assert_equal 'main', default.name
      refute_predicate default, :from_remote?
    end
  end

  # The fallback is a remote-tracking ref, never a local branch: it is
  # still a record of what the remote had, just an older one. A remote
  # nobody has ever fetched from leaves nothing to fall back to, however
  # many local branches carry a familiar name.
  def test_the_fallback_is_a_record_of_the_remote_not_a_local_branch
    with_flat_fixture('offline-no-record') do |repo|
      repo.git('remote', 'add', 'never-fetched', File.join(repo.root, 'no-such-repo.git'))

      message = assert_raises(StaleBranches::Error) { resolve(repo, remote: 'never-fetched') }.message

      assert_match(%r{never-fetched/main}, message)
      assert_includes repo.local_refs, 'refs/heads/main',
                      'the arm removed the local branch it is proving is not used'
    end
  end

  # With nothing local worth falling back to, a guess would be invented
  # rather than degraded. The gitflow repository is one `branch -D` away
  # from that state, and its HEAD is already detached, so main can go.
  def test_an_unreachable_remote_with_nothing_to_fall_back_to_is_refused
    with_gitflow_fixture('offline-empty') do |repo|
      repo.git('remote', 'add', 'gone', File.join(repo.root, 'no-such-repo.git'))

      message = assert_raises(StaleBranches::Error) { resolve(repo, remote: 'gone') }.message

      assert_match(/main/, message, 'the refusal did not say what it looked for')
    end
  end

  # git's own first line is carried through, because an unreachable
  # host, a rejected credential and a misconfigured URL are three
  # different problems that otherwise arrive as one sentence -- and
  # this is the branch that routes the run onto a guess.
  def test_the_fallback_says_what_git_said
    with_flat_fixture('offline-detail') do |repo|
      add_unreachable_remote(repo, 'gone')

      assert_match(/repository|not a git/i, resolve(repo, remote: 'gone').detail,
                   "git's own explanation was dropped")
    end
  end

  # The warning is what makes the fallback survivable: a report measured
  # against a guessed branch that says so can be re-run against the real
  # one, and the same report without it is a confident wrong answer.
  def test_the_fallback_warns_through_the_cli_naming_both_branches
    with_flat_fixture('offline-warning') do |repo|
      add_unreachable_remote(repo, 'gone')
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
  # A remote that was fetched from once and cannot be reached now,
  # which is the ordinary offline shape: the URL is gone, but the
  # record of what it last had is still here.
  def add_unreachable_remote(repo, name)
    repo.git('remote', 'add', name, File.join(repo.root, 'no-such-repo.git'))
    repo.git('update-ref', "refs/remotes/#{name}/main",
             repo.git('rev-parse', 'refs/remotes/origin/main').strip)
  end

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
  # cloned with `--single-branch`, or one whose refs were pruned. The
  # local branch of that name is NOT the fallback: it is whatever this
  # developer has advanced, and measuring against unpushed commits on
  # it clears branches whose work reached nobody. So the run is refused,
  # and the refusal says what would fix it.
  def test_with_no_remote_tracking_ref_the_run_is_refused_rather_than_measured_locally
    with_flat_fixture('no-tracking') do |repo|
      repo.git('update-ref', '-d', 'refs/remotes/origin/main')

      message = assert_raises(StaleBranches::Error) { measure(repo) }.message

      assert_match(%r{refs/remotes/origin/main}, message)
      assert_match(/git fetch origin main/, message, 'the refusal did not say what would fix it')
    end
  end

  # The local branch is refused even when it is the obvious answer and
  # carries commits nobody else has -- which is exactly when measuring
  # against it would destroy them.
  def test_an_unpushed_local_default_is_not_used_even_as_a_last_resort
    with_flat_fixture('no-tracking-unpushed') do |repo|
      repo.checkout('main')
      repo.git('merge', '-q', '--no-ff', 'g-open', '-m', 'merge g-open locally only')
      repo.git('update-ref', '-d', 'refs/remotes/origin/main')

      assert_raises(StaleBranches::Error) { measure(repo) }
      assert_includes repo.local_refs, 'refs/heads/g-open', 'the arm deleted its own subject'
    end
  end

  # Neither the remote-tracking ref nor a local branch of that name, in
  # a repository whose remote still reports one. Nothing honest is left
  # to measure against, and a sweep that carried on would be comparing
  # every branch to nothing and clearing all of them.
  def test_with_nothing_local_naming_the_default_branch_the_run_ends
    with_flat_fixture('nothing-to-measure') do |repo|
      repo.git('update-ref', '-d', 'refs/remotes/origin/main')
      repo.git('update-ref', '-d', 'refs/heads/main')

      message = assert_raises(StaleBranches::Error) { measure(repo) }.message

      assert_match(/main/, message, 'the refusal did not name what it looked for')
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

  # Ahead is the hazardous direction: the tracking ref holds commits the
  # remote no longer advertises, so a DELETE can clear work that is on
  # no remote. Reporting it as "behind, run git fetch" reassures the
  # reader in exactly the state that deserves alarm.
  def test_a_tracking_ref_holding_what_the_remote_dropped_is_reported_as_the_hazard_it_is
    with_flat_fixture('ahead-tracking') do |repo|
      behind = sha(repo, 'refs/remotes/origin/main~1')
      repo.git('update-ref', 'refs/heads/main', behind, dir: repo.origin)
      warning = warnings(repo)

      assert_match(/holds commits origin does not/, warning)
      refute_match(/is behind/, warning, 'the dangerous direction was reported as the mild one')
    end
  end

  # Neither contains the other, and this clone does not even have the
  # commit the remote is on -- which is the ordinary shape of a
  # force-push nobody has fetched since.
  # Somebody pushed and this clone has not fetched since, which is the
  # ordinary state and the mild one. The object is not here to compare
  # against, so a check that asks about ancestry first calls every such
  # repository diverged -- the most common state getting the most
  # alarming message, and the fetch advice it needs never printed.
  def test_a_tracking_ref_missing_what_the_remote_is_on_is_told_to_fetch
    with_flat_fixture('behind-tracking') do |repo|
      elsewhere = repo.git('commit-tree', "#{sha(repo, 'refs/heads/main')}^{tree}",
                           '-p', sha(repo, 'refs/heads/main'), '-m', 'somebody else pushed',
                           dir: repo.origin).strip
      repo.git('update-ref', 'refs/heads/main', elsewhere, dir: repo.origin)
      warning = warnings(repo)

      assert_match(/git fetch origin/, warning, 'the advice this state needs was not given')
      refute_match(/diverged/, warning, 'an unfetched clone was reported as diverged')
    end
  end

  # A remote that answered and advertised nothing is not a remote that
  # could not be reached, and saying so saves checking a network that
  # is fine.
  def test_a_remote_with_nothing_to_advertise_is_not_reported_as_unreachable
    with_flat_fixture('empty-remote') do |repo|
      repo.git('init', '-q', '-b', 'main', '--bare', 'empty.git', dir: repo.root)
      repo.git('remote', 'add', 'empty', File.join(repo.root, 'empty.git'))

      message = assert_raises(StaleBranches::Error) { measure(repo, remote: 'empty') }.message

      assert_match(/advertised no default branch/, message)
      refute_match(/no refs/, message,
                   'a remote holding only tags advertises plenty and is not unreachable')
    end
  end

  def test_a_current_tracking_ref_is_reported_as_nothing_at_all
    with_flat_fixture('current-tracking') do |repo|
      assert_empty ref_warnings(repo)
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

  # The common real-world case, and the one no fixture builds: a
  # correctly-configured origin/HEAD. Without this arm the guard that
  # keeps quiet about it can be deleted outright and every properly
  # set-up repository is told its origin/HEAD names the wrong branch,
  # with nothing going red.
  # Offline, refs/remotes/<remote>/HEAD is the remote's own answer --
  # older, but an answer. A hardcoded guess at main is not one, and on
  # a repository shipping from develop it measures every verdict
  # against the wrong branch.
  def test_an_unreachable_remote_falls_back_to_what_the_remote_last_said
    with_gitflow_fixture('offline-remembered') do |repo|
      repo.git('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/develop')
      repo.git('remote', 'set-url', 'origin', File.join(repo.root, 'no-such-repo.git'))

      assert_equal 'develop', measure(repo).default.name
    end
  end

  # Every clause of the stale-HEAD warning is false when the remote was
  # never asked: the name it compares against is the sweep's own guess,
  # so it would claim the remote said something, and advise a repair
  # that needs the same unreachable remote and would overwrite a
  # correct ref with the guess.
  # The remembered answer names a ref this clone no longer has, so the
  # fallback drops through to `main` -- and the two now disagree, which
  # is the state that made the warning fire while the remote had said
  # nothing at all. Every clause of it would be false: the name it
  # quotes is the sweep's own guess, and `set-head --auto` needs the
  # same unreachable remote and would overwrite a correct ref with it.
  def test_a_remote_that_was_never_asked_is_not_quoted_as_disagreeing
    with_gitflow_fixture('offline-no-quote') do |repo|
      repo.git('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/develop')
      repo.git('update-ref', '-d', 'refs/remotes/origin/develop')
      repo.git('remote', 'set-url', 'origin', File.join(repo.root, 'no-such-repo.git'))
      warning = warnings(repo)

      assert_equal 'main', measure(repo).default.name, 'the arm did not reach the disagreeing state'
      refute_match(/set-head|origin says/, warning,
                   'a remote that was never reached was quoted as having answered')
    end
  end

  def test_a_head_ref_that_already_agrees_is_reported_as_nothing
    with_gitflow_fixture('agreeing-head-ref') do |repo|
      repo.git('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/develop')

      assert_empty ref_warnings(repo)
    end
  end

  def test_no_head_ref_at_all_is_reported_as_nothing
    with_gitflow_fixture('no-head-ref') do |repo|
      assert_empty ref_warnings(repo)
      refute_match(/set-head/, warnings(repo))
    end
  end

  # S9 -- a repository with no remote configured at all, which is the
  # other half of the refusal's wording.
  def test_a_repository_with_no_remotes_at_all_says_so
    with_flat_fixture('no-remotes') do |repo|
      repo.git('remote', 'remove', 'origin')

      message = assert_raises(StaleBranches::Error) { measure(repo) }.message

      assert_match(/none/, message, 'the refusal read as though some other remote existed')
    end
  end

  private

  def warnings(repo)
    ref_warnings(repo).join("\n")
  end

  # Every warning except the one about the forge, which every run in
  # this file carries because the forge is deliberately unreachable
  # here. Asserting "no warnings at all" would otherwise mean "the
  # sweep did not degrade", which is not what any of these tests is
  # about.
  def ref_warnings(repo)
    measure(repo).warnings.grep_v(/pull request/)
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
      assert_protections_match(FLAT_DEGRADED_ORACLE, repo)
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
        sweep = with_repo_env(repo) { sweep_for(git_for(repo, dir: '.')).run }

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
end

# The cheap first pass: a branch whose tip the default branch already
# contains adds nothing to it, and git answers that by walking commits
# rather than comparing content. Everything it clears is clear beyond
# argument, which is why it runs before the expensive checks.
class Pass1Test < OracleTestCase
  def test_the_flat_tables_ancestor_row_is_the_one_ancestry_clears
    with_flat_fixture('pass1') do |repo|
      assert_stage_matches(FLAT_DEGRADED_ORACLE, measure(repo), 'pass1:ancestor')
    end
  end

  # Ancestry of DEVELOP. Every branch here is an ancestor of something,
  # and measuring against main would clear the wrong ones.
  def test_the_gitflow_tables_ancestor_row_is_measured_against_its_own_default
    with_gitflow_fixture('pass1') do |repo|
      assert_stage_matches(GITFLOW_ORACLE, measure(repo), 'pass1:ancestor')
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
      assert_equal 'KEEP', sweep.rows.find { |row| row.branch == 's-tag-shadow' }&.verdict,
                   'the branch a tag shadows was swept up by the tag'
    end
  end

  def test_a_tag_at_the_default_branch_does_not_clear_it_in_the_gitflow_repository_either
    with_gitflow_fixture('tag-trap') do |repo|
      sweep = measure(repo)

      refute_includes stage_of(sweep, 'pass1:ancestor').keys, 'amb'
      assert_equal 'KEEP', sweep.rows.find { |row| row.branch == 'amb' }&.verdict,
                   'the branch a tag shadows was swept up by the tag'
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

      sweep = measure(repo)

      refute_includes stage_of(sweep, 'pass1:ancestor').keys, 'g-open'
      assert_equal 'KEEP', sweep.rows.find { |row| row.branch == 'g-open' }&.verdict,
                   'the branch was not cleared, but it was not reported either'
    end
  end
end

# The content check, which answers the question ancestry cannot: a
# branch squash-merged into the default branch is not an ancestor of
# anything, yet merging it back adds nothing. git answers by merging
# into a tree it writes and never checks out, so the working tree is
# untouched and the comparison is of trees rather than of diffs.
#
# Its three outcomes are three different states of knowledge, and the
# report says which. A merged tree equal to the default branch's own
# means the content is already there. A different tree is a positive
# local fact: this branch definitely adds something. A conflict is
# neither -- the check could not run, so nothing offline can clear the
# branch, and it is the only outcome a pull-request lookup could
# improve on.
class ProofATest < OracleTestCase
  # A git from before `merge-tree --write-tree` existed. Reported
  # rather than simulated: the command's absence is what the version
  # check stands in for, and there is no old git to run here.
  class AncientGit < StaleBranches::Git
    def version
      [2, 37]
    end
  end

  # A git whose --version says something this cannot parse. Treated as
  # too old rather than assumed new enough, because the check would
  # otherwise run and answer wrongly for every branch.
  class UnreadableGit < StaleBranches::Git
    def version
      nil
    end
  end

  # The refusal itself, and not only the predicate behind it. A sweep
  # that read the version and carried on anyway would report a
  # repository in which every branch conflicts, which looks like an
  # answer.
  def test_an_old_git_ends_the_run_rather_than_reporting_what_it_never_checked
    with_flat_fixture('old-git') do |repo|
      message = assert_raises(StaleBranches::Error) do
        with_repo_env(repo) { sweep_for(ancient_git(repo)).run }
      end.message

      assert_match(/2\.38/, message, 'the refusal did not say what it needs')
      assert_match(/2\.37/, message, 'the refusal did not say what it found')
    end
  end

  def test_a_git_whose_version_cannot_be_read_is_refused_as_too_old
    with_flat_fixture('unreadable-git') do |repo|
      message = assert_raises(StaleBranches::Error) do
        with_repo_env(repo) { sweep_for(unreadable_git(repo)).run }
      end.message

      assert_match(/2\.38/, message, 'the refusal did not say what it needs')
      assert_match(/no readable version/, message, 'the refusal did not say what it found')
    end
  end

  # Doubles go through the same tmpdir refusal a real Git does, so a
  # test reaching past the argv cannot reach past the guard with it.
  def ancient_git(repo)
    guard_cli_invocation(['-C', repo.work])
    AncientGit.new(dir: repo.work, remote: 'origin')
  end

  def unreadable_git(repo)
    guard_cli_invocation(['-C', repo.work])
    UnreadableGit.new(dir: repo.work, remote: 'origin')
  end

  def test_the_flat_table_agrees_about_what_the_content_check_finds
    with_flat_fixture('proof-a') do |repo|
      sweep = measure(repo)

      %w[proof-a:content-landed proof-a:conflict kept:not-landed].each do |stage|
        assert_stage_matches(FLAT_DEGRADED_ORACLE, sweep, stage)
      end
    end
  end

  def test_the_gitflow_table_agrees_about_what_the_content_check_finds
    with_gitflow_fixture('proof-a') do |repo|
      sweep = measure(repo)

      %w[proof-a:content-landed kept:not-landed].each do |stage|
        assert_stage_matches(GITFLOW_ORACLE, sweep, stage)
      end
    end
  end

  # A conflict is the one outcome that must never clear a branch, and it
  # is reported as its own reason rather than folded into an ordinary
  # keep: those branches are the entire input to every pull-request rule
  # the finished sweep will have, so a stage that loses track of them
  # leaves those rules nothing to decide.
  def test_a_conflicting_branch_is_kept_and_says_the_check_could_not_answer
    with_flat_fixture('conflict') do |repo|
      conflicted = stage_of(measure(repo), 'proof-a:conflict')

      refute_empty conflicted, 'no branch reached the check that only a forge can settle'
      assert_equal %w[KEEP], conflicted.values.uniq
    end
  end

  # Once every stage has run, nothing is left undecided: a branch the
  # report omits is one nobody looked at, which reads as a keep and is
  # not one.
  def test_every_branch_leaves_with_a_verdict
    with_flat_fixture('decided') do |repo|
      sweep = measure(repo)

      assert_empty sweep.candidates
      assert_equal sweep.branches.sort, sweep.rows.map(&:branch).sort
    end
  end
end

# The content check needs git 2.38, where `merge-tree --write-tree`
# arrived. On older git the same command is a different tool with a
# different signature, so it fails -- and a sweep reading that failure
# as it reads any other non-zero exit would call every branch in the
# repository conflicted and report a table of unanswered questions.
# git missing entirely, which is a plain sentence rather than a
# backtrace. Nothing here touches a repository: the point is what
# happens before one could be reached.
class MissingGitTest < Minitest::Test
  def test_git_absent_from_path_is_reported_as_a_sentence
    Dir.mktmpdir('stale-branches-no-git') do |empty|
      saved = ENV.fetch('PATH')
      ENV['PATH'] = empty
      git = StaleBranches::Git.new(dir: Dir.tmpdir, remote: 'origin')

      assert_match(/could not run git/, assert_raises(StaleBranches::Error) do
        git.capture('--version')
      end.message)
    ensure
      ENV['PATH'] = saved
    end
  end
end

# The two readings that used to fold git's failure into a verdict. Both
# now raise, because a broken run reported as a confident answer is the
# shape of defect this whole tool was extracted to stop.
class GitFailureTest < OracleTestCase
  def test_an_ancestry_question_git_cannot_answer_raises
    with_flat_fixture('ancestor-failure') do |repo|
      message = assert_raises(StaleBranches::Error) do
        with_repo_env(repo) { git_for(repo).ancestor?('refs/heads/main', 'refs/heads/nope') }
      end.message

      assert_match(/merge-base/, message)
    end
  end

  # A ref git cannot resolve exits with nothing on stdout, exactly as a
  # conflict does with the tree still there. Reading the first as the
  # second puts `proof-a:conflict` in the report for a conflict nobody
  # observed.
  def test_a_content_check_git_cannot_run_raises_rather_than_reporting_a_conflict
    with_flat_fixture('merge-tree-failure') do |repo|
      message = assert_raises(StaleBranches::Error) do
        with_repo_env(repo) do
          git_for(repo).merge_tree('refs/remotes/origin/main', 'refs/heads/nope')
        end
      end.message

      assert_match(/merge-tree/, message)
    end
  end

  # Asked twice, shelled once -- and an unreadable answer is remembered
  # as unreadable rather than re-asking on the one path where asking
  # has already failed.
  def test_the_git_version_is_asked_for_only_once
    with_flat_fixture('version-memo') do |repo|
      git = git_for(repo)
      with_repo_env(repo) { assert_equal git.version, git.version }
    end
  end
end

# The version gate runs before anything else, so whatever it reports is
# the first thing a caller sees -- and it must not answer a question
# nobody asked. `git -C <nonexistent> --version` exits 128 with empty
# stdout, which read as a git too old for the content check and sent a
# caller who mistyped -C away to upgrade git.
class MistypedTargetTest < CliTestCase
  def dispatch_cli(argv)
    StaleBranches::CLI.run(argv)
  end

  def test_a_directory_that_does_not_exist_is_reported_as_such
    message = abort_result(['-C', File.join(Dir.tmpdir, 'stale-branches-no-such-dir')]).message

    refute_match(/2\.38|version/, message, 'a bad directory was reported as an out-of-date git')
  end
end

class GitVersionTest < Minitest::Test
  def test_the_version_is_read_from_what_git_prints
    assert_equal [2, 50], StaleBranches.parse_git_version('git version 2.50.1 (Apple Git-155)')
    assert_equal [2, 38], StaleBranches.parse_git_version("git version 2.38.0\n")
  end

  def test_output_that_names_no_version_answers_nothing
    assert_nil StaleBranches.parse_git_version('git version unknown')
    assert_nil StaleBranches.parse_git_version('')
  end

  def test_the_content_check_needs_the_version_that_introduced_it
    refute StaleBranches.content_check_available?([2, 37])
    assert StaleBranches.content_check_available?([2, 38])
    assert StaleBranches.content_check_available?([2, 50])
    assert StaleBranches.content_check_available?([3, 0])
  end

  # An unreadable version is not treated as new enough. The check the
  # sweep would then run silently produces the wrong answer for every
  # branch, which is worse than refusing.
  def test_an_unreadable_version_is_not_assumed_to_be_new_enough
    refute StaleBranches.content_check_available?(nil)
  end
end

# Deleting, which is the half that cannot be taken back. Every arm here
# checks the repository afterwards rather than the exit status, because
# the failure this whole tool was extracted to prevent is a deletion
# that reports success and does not happen.
class DeletionTest < OracleTestCase
  # A git that accepts every branch deletion and deletes nothing.
  # Standing in for the real shape of that defect: handed a full
  # refname, `git branch -d refs/heads/x` exits complaining and the
  # sweep carried on; handed a flag-shaped name without a separator, it
  # exits saying a branch name is required. Either way the caller who
  # trusts the command rather than the repository reports a clean
  # sweep of branches that are all still there.
  class PretendingGit < StaleBranches::Git
    def capture(*args)
      args.first == 'branch' ? super('rev-parse', 'HEAD') : super
    end
  end

  # `git branch -d -D` and `git branch -D -D` both exit saying a branch
  # name is required, having deleted nothing -- so the separator is not
  # a nicety here, it is the difference between the deletion happening
  # and the sweep lying about it.
  def test_a_branch_named_like_a_flag_is_deleted_rather_than_refused
    with_flat_fixture('delete-flag') do |repo|
      plant_flag_shaped_branch(repo)
      result = delete_branch(repo, '-D')

      assert_predicate result, :deleted, "git said: #{result.detail}"
      refute_includes repo.local_refs, 'refs/heads/-D'
    end
  end

  # git's own definition of merged is reachability, and a squash-merged
  # branch never satisfies it however plainly its content has landed.
  # -d is asked first anyway, so git gets to refuse on its own terms,
  # and -D then forces what the evidence already settled.
  def test_a_squash_merged_branch_git_will_not_delete_gently_is_forced
    with_flat_fixture('delete-squashed') do |repo|
      assert_predicate delete_branch(repo, 'a-squash-clean'), :deleted
      refute_includes repo.local_refs, 'refs/heads/a-squash-clean'
    end
  end

  def test_a_branch_the_default_branch_contains_is_deleted
    with_flat_fixture('delete-ancestor') do |repo|
      assert_predicate delete_branch(repo, 'p1-ancestor'), :deleted
      refute_includes repo.local_refs, 'refs/heads/p1-ancestor'
    end
  end

  def test_a_deletion_that_did_not_happen_is_not_reported_as_one
    with_flat_fixture('pretending') do |repo|
      git = pretending_git(repo)
      result = with_repo_env(repo) { git.delete_branch('p1-ancestor') }

      refute_predicate result, :deleted, 'a branch still in the repository was called deleted'
      assert_includes repo.local_refs, 'refs/heads/p1-ancestor'
    end
  end

  # A sweep that cannot do what it was told exits non-zero, or the
  # script that called it carries on as though the branches were gone.
  # git's own explanation is passed along, since "permission denied" is
  # the actionable half and the sweep has no better wording for it.
  def test_a_deletion_that_fails_exits_non_zero_and_says_why
    with_flat_fixture('delete-refused') do |repo|
      with_unwritable_refs(repo) do
        result = with_repo_env(repo) { abort_result(['-C', repo.work, '--delete']) }

        refute_equal 0, result.status, 'a sweep that deleted nothing it was told to exited clean'
        assert_match(/p1-ancestor/, result.stderr)
        assert_match(/denied|cannot lock/i, result.stderr, "git's own reason was dropped")
      end
    end
  end

  # The harm the tip-only rule exists to prevent, asserted as harm
  # rather than as a verdict: the branch survives --delete, and so does
  # the only copy of what it added. Before the rule, this branch was
  # deleted with its reflog and the blob was left reachable from
  # nothing -- recoverable by `git fsck` until the next gc, and by
  # nobody who did not know to look.
  def test_a_branch_holding_the_only_copy_of_its_own_work_survives_delete
    with_flat_fixture('tip-only-delete') do |repo|
      branch = Fixtures::BranchRepo::ADDED_THEN_REMOVED
      blob = repo.git('rev-parse', "#{branch}~1:u-research.txt").strip
      sweep(repo, '--delete')

      assert_includes repo.local_refs, "refs/heads/#{branch}",
                      'a branch holding content nothing else has was deleted'
      assert_equal 'THE ONLY COPY OF THIS RESEARCH',
                   repo.git('cat-file', '-p', blob).strip
      refute_includes repo.git('fsck', '--no-reflogs', '--unreachable'), blob,
                      'the only copy of the research is reachable from nothing'
    end
  end

  # The promise the default mode makes: it shows what it would destroy
  # and destroys nothing. A tool that quietly acted would be discovered
  # by its damage rather than by a test.
  def test_the_default_mode_shows_its_deletions_and_performs_none
    with_flat_fixture('preview') do |repo|
      before = repo.local_refs
      result = sweep(repo)

      assert_includes result.rows.map(&:verdict), 'DELETE', 'nothing was marked, so nothing was risked'
      assert_equal before, repo.local_refs, 'a report-only run changed the repository'
      assert_match(/--delete/, result.stdout, 'the report never says how to act on it')
    end
  end

  # The other half of that promise, and the reason the expected state is
  # derived from the report rather than written out: a hardcoded list
  # would agree with a sweep that deleted the right branches for the
  # wrong reasons, or that reported one set and acted on another. What
  # is asserted is that the two are the same set.
  def test_delete_removes_exactly_the_branches_its_own_report_marked
    with_flat_fixture('delete-mode') do |repo|
      before = repo.local_refs
      result = sweep(repo, '--delete')
      marked = result.rows.select { |row| row.verdict == 'DELETE' }.map(&:branch)

      refute_empty marked, 'the run marked nothing, so it proved nothing'
      assert_equal (before - marked.map { |branch| "refs/heads/#{branch}" }).sort,
                   repo.local_refs.sort
      marked.each do |branch|
        assert_match(/^deleted #{Regexp.escape(branch)} \(was [0-9a-f]{7,}\)$/, result.stdout,
                     'a deletion was reported without the object name that could recover it')
      end
    end
  end

  # The offer only makes sense when there is something to accept. A
  # clean repository otherwise ends its report by inviting the reader
  # to delete the 0 branches marked DELETE.
  def test_a_report_with_nothing_marked_makes_no_offer
    with_gitflow_fixture('nothing-marked') do |repo|
      repo.git('branch', '-D', 'gf-ancestor', 'gf-squashed')
      result = sweep(repo)

      refute_includes result.rows.map(&:verdict), 'DELETE', 'the arm left something deletable'
      refute_match(/--delete/, result.stdout, 'a report with nothing to delete offered to delete')
    end
  end

  # A refusal git had no words for. The re-verify is what noticed at
  # all, so the message it produces is the whole of what the caller
  # gets, and "could not delete x:" trailing off is not enough.
  # delete_marked reports each result as it happens for a caller that
  # wants to print them, and returns them all for one that does not.
  def test_deleting_without_a_listener_still_returns_what_it_did
    with_flat_fixture('delete-blockless') do |repo|
      sweep = with_repo_env(repo) { sweep_for(git_for(repo)).run }
      results = with_repo_env(repo) { sweep.delete_marked }

      refute_empty results
      assert(results.all?(&:deleted?), 'a deletion this reported did not happen')
    end
  end

  def test_a_deletion_that_fails_without_a_reason_still_says_something
    with_flat_fixture('silent-failure') do |repo|
      sweep = with_repo_env(repo) { sweep_for(pretending_git(repo)).run }
      out, err = capture_io do
        assert_raises(SystemExit) { StaleBranches::CLI.new.send(:delete_marked, sweep) }
      end

      assert_empty out, 'a deletion that never happened was reported as done'
      assert_match(/still there/, err, 'the refusal said nothing a reader could act on')
    end
  end

  # `git branch -d` refuses a squash-merged branch with an "error:" line
  # of its own, and this mode runs into that deliberately on the way to
  # -D. None of it belongs on the sweep's stderr, where it would read as
  # something having gone wrong.
  def test_deleting_leaks_none_of_gits_complaints
    with_flat_fixture('delete-quiet') do |repo|
      refute_git_complaints(sweep(repo, '--delete'))
    end
  end

  private

  def delete_branch(repo, name)
    with_repo_env(repo) { git_for(repo).delete_branch(name) }
  end

  # Through the same tmpdir refusal a real Git gets.
  def pretending_git(repo)
    guard_cli_invocation(['-C', repo.work])
    PretendingGit.new(dir: repo.work, remote: 'origin')
  end

  # Loose refs live as files, so a directory git cannot write to is a
  # deletion it cannot perform -- a real refusal from git rather than a
  # simulated one. Restored before the block returns, or the temporary
  # directory cannot be cleaned up either.
  def with_unwritable_refs(repo)
    heads = File.join(repo.work, '.git', 'refs', 'heads')
    File.chmod(0o500, heads)
    yield
  ensure
    File.chmod(0o700, heads)
  end
end

# The variable that quietly aims git somewhere else. `git -C DIR` does
# not override an inherited GIT_DIR, so a sweep that passes no
# environment of its own reports on -- and with --delete destroys
# branches in -- a repository the caller never named. Nothing exotic
# sets it: git hooks, `git rebase --exec`, and `git bisect run` all do.
#
# This arm deliberately does NOT go through with_repo_env, because that
# unsets the variable under test. A second fixture stands in for the
# repository an escape would land on, so the assertion is about which
# repository answered rather than about a message.
class AmbientGitDirTest < OracleTestCase
  def test_an_ambient_git_dir_cannot_redirect_the_sweep
    with_flat_fixture('ambient') do |flat|
      with_gitflow_fixture('ambient-elsewhere') do |elsewhere|
        report = with_env('GIT_DIR' => File.join(elsewhere.work, '.git'),
                          'GIT_WORK_TREE' => elsewhere.work) do
          capture_io { run_cli(['-C', flat.work]) }.first
        end

        assert_includes report, 'o-current', 'the sweep did not report on the repository named'
        refute_includes report, 'gf-squashed', 'the sweep reported on the ambient GIT_DIR instead'
      end
    end
  end

  # The same variable, on the path that destroys. A deletion landing in
  # the wrong repository is the version of this with no way back.
  def test_an_ambient_git_dir_cannot_redirect_a_deletion
    with_flat_fixture('ambient-delete') do |flat|
      with_gitflow_fixture('ambient-delete-elsewhere') do |elsewhere|
        before = elsewhere.local_refs

        with_env('GIT_DIR' => File.join(elsewhere.work, '.git'),
                 'GIT_WORK_TREE' => elsewhere.work) do
          capture_io { run_cli(['-C', flat.work, '--delete']) }
        end

        assert_equal before, elsewhere.local_refs,
                     'a sweep deleted branches in the repository an ambient GIT_DIR named'
        refute_includes flat.local_refs, 'refs/heads/p1-ancestor',
                        'the sweep deleted nothing in the repository it was pointed at'
      end
    end
  end

  private

  def with_env(pairs)
    saved = pairs.keys.to_h { |key| [key, ENV[key]] }
    pairs.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
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
      result = run_probe(['-C', dir])
      # Passing outright is the clean case; an empty directory is not a
      # repository, so the CLI's own complaint is acceptable here and
      # the guard's refusal is not.
      next if result.passed?

      refute_match(/outside/i, result.failure.message, 'the guard refused a throwaway repository')
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

# The other half of the same fixture: the sweep with a forge answering,
# graded against expected.txt. Where OracleTestCase shims gh so any call
# flunks, this one serves it -- the same repository, the same argv, and
# the difference between the two tables is exactly what consulting a
# forge is worth.
#
# The records are written after the repository is built, so every head
# SHA is a real one. A hand-written SHA compares equal to nothing, which
# would turn every rule reading it into a rule that always rejects, and
# the branches those rules decide are KEEP either way -- so no verdict
# would reveal it.
class FlatFixtureForgeOracleTest < OracleTestCase
  ORACLE = FLAT_FORGE_ORACLE

  def test_report_matches_the_oracle_with_the_forge_answering
    with_flat_fixture('flat-forge') do |repo|
      with_forge(repo) do
        result = sweep(repo)

        assert_matches_oracle(Fixtures::Oracle.load(ORACLE), result)
        refute_git_complaints(result)
      end
    end
  end
end

# The clause logic of proof (b), driven directly. The oracle grades it
# through a whole sweep against one fixture, which fixes the order the
# clauses are reached in; these fix what each clause decides, including
# the combinations the fixture has no branch for.
class PullRequestVerdictTest < Minitest::Test
  TIP = ('a' * 40).freeze
  OTHER = ('b' * 40).freeze

  def record(state:, head: TIP, base: 'main', fork: false, number: 1)
    { 'number' => number, 'state' => state, 'headRefName' => 'branch',
      'headRefOid' => head, 'baseRefName' => base, 'isCrossRepository' => fork }
  end

  def verdict(*records)
    StaleBranches.pull_request_verdict(records, tip: TIP, default: 'main')
  end

  def test_no_pull_request_at_all_says_so_rather_than_guessing
    assert_equal ['KEEP', 'proof-b:no-pr'], verdict
  end

  def test_a_closed_pull_request_merged_nothing
    assert_equal ['KEEP', 'proof-b:pr-closed'], verdict(record(state: 'CLOSED'))
  end

  def test_a_merged_pull_request_from_a_fork_is_not_evidence_about_this_branch
    assert_equal ['KEEP', 'proof-b:pr-from-fork'],
                 verdict(record(state: 'MERGED', fork: true))
  end

  def test_a_merged_pull_request_based_elsewhere_reached_somewhere_else
    assert_equal ['KEEP', 'proof-b:pr-other-base'],
                 verdict(record(state: 'MERGED', base: 'release/2.0'))
  end

  def test_a_merged_pull_request_whose_head_is_not_this_tip_did_not_merge_what_is_here
    assert_equal ['KEEP', 'proof-b:pr-tip-differs'],
                 verdict(record(state: 'MERGED', head: OTHER))
  end

  def test_every_clause_satisfied_at_once_is_the_one_deletion_proof_b_can_reach
    assert_equal ['DELETE', 'proof-b:pr-merged'], verdict(record(state: 'MERGED'))
  end

  # The clearing pull request may be any of several, and gh returns them
  # newest first. A sweep reading only the first would keep this branch.
  def test_the_clearing_pull_request_need_not_be_the_one_listed_first
    assert_equal ['DELETE', 'proof-b:pr-merged'],
                 verdict(record(state: 'MERGED', head: OTHER, number: 2),
                         record(state: 'MERGED', number: 1))
  end

  # A fork's merged pull request sitting alongside your own must not
  # take yours out of consideration: the clauses reject the records that
  # fail them, never the branch.
  def test_a_forks_merged_pull_request_does_not_discard_your_own
    assert_equal ['DELETE', 'proof-b:pr-merged'],
                 verdict(record(state: 'MERGED', fork: true, number: 2),
                         record(state: 'MERGED', number: 1))
  end

  # gh spells states in capitals and has changed the shape of its
  # output before. Comparing case-insensitively costs nothing, and the
  # failure it avoids is silent: every state unrecognized reads as
  # "closed", which keeps every branch.
  def test_a_state_in_another_case_is_still_that_state
    assert_equal ['DELETE', 'proof-b:pr-merged'], verdict(record(state: 'merged'))
  end

  # The default branch is whatever the repository's is, and on the
  # gitflow fixture that is develop while main is present and is not it.
  # A comparison against a hardcoded main is wrong in both directions at
  # once, which is the shape this pins.
  def test_the_base_is_compared_against_the_default_branch_that_was_passed
    landed = [record(state: 'MERGED', base: 'develop')]
    elsewhere = [record(state: 'MERGED', base: 'main')]

    assert_equal ['DELETE', 'proof-b:pr-merged'],
                 StaleBranches.pull_request_verdict(landed, tip: TIP, default: 'develop')
    assert_equal ['KEEP', 'proof-b:pr-other-base'],
                 StaleBranches.pull_request_verdict(elsewhere, tip: TIP, default: 'develop')
  end

  # Proof (b) never sees an open pull request, because the protection
  # below decides those branches before the content check runs, let
  # alone this. So the clauses above answer only for branches whose
  # pull requests are all finished, and an open one reaching here would
  # be read as closed -- which is why it cannot.
  def test_an_open_pull_request_is_not_this_stages_to_decide
    assert StaleBranches.open_pull_request?([record(state: 'OPEN')])
    refute StaleBranches.open_pull_request?([record(state: 'MERGED'),
                                             record(state: 'CLOSED')])
  end

  def test_an_open_pull_request_alongside_finished_ones_still_counts
    assert StaleBranches.open_pull_request?([record(state: 'MERGED', number: 1),
                                             record(state: 'OPEN', number: 2)])
  end

  def test_an_open_state_in_another_case_is_still_open
    assert StaleBranches.open_pull_request?([record(state: 'open')])
  end

  def test_no_pull_requests_at_all_is_not_an_open_one
    refute StaleBranches.open_pull_request?([])
  end
end

# The only code that runs gh, driven against the stub. What it asks is
# asserted as closely as what it concludes: a sweep that queries a
# branch it should never have reached is wrong even when every verdict
# it prints is right, and one that asks twice for the same branch is
# paying twice for an answer it already has.
class ForgeTest < OracleTestCase
  def test_one_query_per_branch_naming_the_branch_and_every_state
    with_flat_fixture('forge-query') do |repo|
      with_forge(repo) do
        forge_for(repo).pull_requests('g-open')

        assert_equal 1, served_invocations.length
        call = served_invocations.first
        assert_includes call, '--head g-open'
        assert_includes call, '--state all'
        assert_includes call, '--json '
      end
    end
  end

  def test_a_second_question_about_one_branch_is_answered_from_the_first
    with_flat_fixture('forge-cache') do |repo|
      with_forge(repo) do
        forge = forge_for(repo)
        first = forge.pull_requests('k-merged-and-open')
        second = forge.pull_requests('k-merged-and-open')

        assert_equal first, second
        assert_equal 1, served_invocations.length, 'the same branch was queried twice'
      end
    end
  end

  def test_the_records_come_back_as_the_forge_stated_them
    with_flat_fixture('forge-records') do |repo|
      with_forge(repo) do
        records = forge_for(repo).pull_requests('k-merged-and-open')

        assert_equal %w[MERGED OPEN], records.map { |record| record['state'] }.sort
        assert(records.all? { |record| record['headRefName'] == 'k-merged-and-open' })
      end
    end
  end

  def test_a_branch_no_pull_request_names_comes_back_empty_rather_than_missing
    with_flat_fixture('forge-empty') do |repo|
      with_forge(repo) do
        assert_empty forge_for(repo).pull_requests('h-no-pr')
      end
    end
  end

  def test_no_repo_is_passed_unless_the_caller_named_one
    with_flat_fixture('forge-no-repo') do |repo|
      with_forge(repo) do
        forge_for(repo).pull_requests('g-open')

        refute_includes served_invocations.first, '--repo'
      end
    end
  end

  # A failing client is a fact about the repository, not about the
  # branch that happened to be asked first, so the sweep must stop
  # asking rather than pay for one failure per candidate.
  def test_a_failing_client_answers_nothing_and_is_not_asked_again
    with_flat_fixture('forge-failing') do |repo|
      with_forge(repo, failing: true) do
        forge = forge_for(repo)

        assert_nil forge.pull_requests('g-open')
        refute forge.available?, 'a client that failed must not still be considered available'
        assert_nil forge.pull_requests('k-merged-and-open')
        assert_equal 1, served_invocations.length, 'a failed client was asked a second time'
      end
    end
  end

  # gh is not installed at all, which is the ordinary case on a machine
  # that has never needed it. It must read as a degradation rather than
  # arrive as a Ruby backtrace.
  def test_a_client_that_is_not_installed_answers_nothing_rather_than_raising
    with_flat_fixture('forge-absent') do |repo|
      with_forge(repo) do
        forge = forge_for(repo)
        without_gh_on_path do
          assert_nil forge.pull_requests('g-open')
        end
        refute forge.available?
        assert_empty served_invocations, 'the stub was reached after all'
      end
    end
  end

  private

  def forge_for(repo, dir: repo.work, name: nil)
    guard_cli_invocation(['-C', dir])
    StaleBranches::Forge.new(dir: dir, repo: name)
  end

  def without_gh_on_path
    saved = ENV.fetch('PATH')
    Dir.mktmpdir('no-gh') { |dir| ENV['PATH'] = dir and yield }
  ensure
    ENV['PATH'] = saved
  end
end

# What the sweep says when it cannot ask. Both halves of "cannot" are
# here, because they are different code paths: a gh that runs and fails
# comes back as a non-zero exit, and a gh that was never installed comes
# back as a spawn that raised. A tool that handled one and not the other
# would look fully degraded right up to the machine that has no gh.
class DegradationTest < OracleTestCase
  def test_a_forge_that_cannot_be_reached_is_reported_once
    with_flat_fixture('degraded-warning') do |repo|
      warnings = measure(repo).warnings.grep(/pull request/)

      assert_equal 1, warnings.length,
                   "one warning per run, not per branch:\n#{warnings.join("\n")}"
    end
  end

  # The caller has to be able to tell which way the verdicts below are
  # wrong, and they are wrong in both directions at once: a branch whose
  # work landed while its own pull request is open is marked DELETE
  # here, and a branch whose merge conflicts is kept for want of an
  # answer rather than because its work is unlanded.
  def test_the_warning_says_what_went_wrong_and_what_it_costs
    with_flat_fixture('degraded-detail') do |repo|
      warning = measure(repo).warnings.grep(/pull request/).first.to_s

      assert_match(/error connecting/, warning, 'the warning did not say what went wrong')
      assert_match(/DELETE/, warning, 'the warning did not say which verdicts it puts at risk')
    end
  end

  def test_a_forge_that_answers_is_not_reported_as_unreachable
    with_flat_fixture('degraded-none') do |repo|
      with_forge(repo) do
        assert_empty measure(repo).warnings.grep(/pull request/)
      end
    end
  end

  # A gh that was never installed must reach the same verdicts as one
  # that runs and fails, or the degraded table describes only the
  # machine it was written on.
  def test_an_absent_client_reaches_the_same_verdicts_as_a_failing_one
    with_flat_fixture('degraded-absent') do |repo|
      with_no_forge_installed do
        result = sweep(repo)

        assert_matches_oracle(Fixtures::Oracle.load(FLAT_DEGRADED_ORACLE), result)
        refute_git_complaints(result)
      end
    end
  end

  def test_an_absent_client_is_reported_too_and_says_so
    with_flat_fixture('degraded-absent-warning') do |repo|
      with_no_forge_installed do
        warnings = measure(repo).warnings.grep(/pull request/)

        assert_equal 1, warnings.length
        assert_match(/gh/, warnings.first, 'the warning did not name what could not be run')
      end
    end
  end

  # One failure ends the asking. The alternative is one failed
  # invocation per candidate, which on a repository with many branches
  # is a slow sweep whose slowness has no purpose.
  def test_a_failing_client_is_asked_once_for_the_whole_run
    with_flat_fixture('degraded-once') do |repo|
      measure(repo)

      assert_equal 1, served_invocations.length,
                   "the forge was asked again after failing:\n#{served_invocations.join("\n")}"
    end
  end
end

# The fork-with-upstream case, which is the whole reason --repo exists.
# gh resolves a repository from the working directory, and on a clone
# of a fork that repository is the fork -- where none of your pull
# requests are. The failure is not an error but an empty answer, which
# a sweep reads as "no pull request".
# What the sweep asks the forge, as opposed to what it concludes. Every
# verdict in the oracle can be right while the queries behind them are
# wrong in ways no verdict shows: a branch asked about twice costs a
# round trip nobody sees, a branch the protected set already answered
# for costs one it should never have paid, and a listing without --head
# returns other people's branches and is truncated in silence at
# whatever --limit says.
class SweepQueryTest < OracleTestCase
  # The reasons reached without asking anything: the protections decided
  # by a name, and the ancestry pass. Derived from the vocabulary rather
  # than listed, so a protection added later is counted as free without
  # this test being edited -- and protected:open-pr is subtracted by
  # name because it is the one protection that costs a query, which is
  # the distinction this whole test rests on.
  def free_reasons
    named = Fixtures::Oracle::REASONS.select do |reason|
      Fixtures::Oracle.stage(reason) == 'protected'
    end
    named - ['protected:open-pr'] + ['pass1:ancestor']
  end

  # The branches that must reach the forge, read off the table: every
  # row whose verdict was not reached for free.
  def branches_needing_the_forge
    Fixtures::Oracle.load(FLAT_FORGE_ORACLE)
                    .reject { |row| free_reasons.include?(row.reason) }
                    .map(&:branch).sort
  end

  def queried_branches
    served_invocations.filter_map { |call| call[/--head (\S+)/, 1] }
  end

  def test_every_branch_the_protections_did_not_answer_for_is_asked_about_exactly_once
    with_flat_fixture('queries') do |repo|
      with_forge(repo) do
        sweep(repo)

        assert_equal branches_needing_the_forge, queried_branches.sort
      end
    end
  end

  # Set equality above already fails on a repeat, but it fails saying
  # the lists differ, which is a poor description of "asked twice".
  # Both stages that read a pull request read the same answer, and a
  # second query is the bug that would not show anywhere else.
  def test_no_branch_is_asked_about_twice
    with_flat_fixture('queries-once') do |repo|
      with_forge(repo) do
        sweep(repo)
        repeated = queried_branches.tally.select { |_branch, count| count > 1 }

        assert_empty repeated, "asked more than once: #{repeated.inspect}"
      end
    end
  end

  # The branches nothing was spent on, stated from the other side. A
  # sweep that asked about every branch would still print the right
  # verdicts, since the protections decide before the answer is read.
  def test_a_branch_a_protection_or_the_ancestry_pass_answered_for_costs_nothing
    with_flat_fixture('queries-free') do |repo|
      with_forge(repo) do
        sweep(repo)
        free = Fixtures::Oracle.load(FLAT_FORGE_ORACLE)
                               .select { |row| free_reasons.include?(row.reason) }
                               .map(&:branch)

        refute_empty free, 'no row is decided for free, so this asserts nothing'
        assert_empty free & queried_branches,
                     'a branch already decided was still asked about'
      end
    end
  end

  # A listing with no --head is every open pull request in the project,
  # truncated at --limit without a word. The sweep would then read a
  # branch as having none because its pull request fell off the end.
  def test_no_query_goes_out_without_the_branch_it_is_about
    with_flat_fixture('queries-scoped') do |repo|
      with_forge(repo) do
        sweep(repo)

        refute_empty served_invocations
        assert(served_invocations.all? { |call| call.include?('--head ') },
               "a listing went out unscoped:\n#{served_invocations.join("\n")}")
      end
    end
  end
end

class RepoFlagTest < OracleTestCase
  UPSTREAM = Fixtures::PullRequests::UPSTREAM

  def test_the_named_repository_is_what_the_client_is_asked_about
    with_flat_fixture('repo-flag') do |repo|
      with_forked_forge(repo) do
        sweep(repo, '--repo', UPSTREAM)

        refute_empty served_invocations
        assert(served_invocations.all? { |call| call.include?("--repo #{UPSTREAM}") },
               "a query went out without the repository it was told to ask about:\n" \
               "#{served_invocations.join("\n")}")
      end
    end
  end

  # What asking the fork costs, stated as verdicts rather than as
  # advice. The keeps are harmless -- a branch kept for want of a pull
  # request nobody could find -- and the deletion is not: this branch
  # has an open pull request upstream, and asking the fork about it
  # comes back empty, so nothing protects it.
  def test_asking_the_fork_loses_the_protection_the_upstream_would_have_given
    with_flat_fixture('repo-flag-wrong') do |repo|
      with_forked_forge(repo) do
        rows = sweep(repo).rows.to_h { |row| [row.branch, row] }

        assert_equal 'DELETE', rows.fetch('q-open-but-landed').verdict,
                     'this arm is pointless unless asking the fork actually loses the protection'
        assert_equal 'proof-b:no-pr', rows.fetch('h-no-pr').reason
        assert_equal 'proof-b:no-pr', rows.fetch('b-main-edited').reason,
                     'a branch whose pull request merged upstream read as having none'
      end
    end
  end

  def test_naming_the_upstream_project_reaches_the_full_specification
    with_flat_fixture('repo-flag-right') do |repo|
      with_forked_forge(repo) do
        result = sweep(repo, '--repo', UPSTREAM)

        assert_matches_oracle(Fixtures::Oracle.load(FLAT_FORGE_ORACLE), result)
        refute_git_complaints(result)
      end
    end
  end

  # The two flags are separate knobs and this is the arm that says so:
  # one selects the git ancestry, the other the forge project, and a
  # sweep given both must honor each. A CLI that quietly used --remote
  # for both would pass every other test here.
  def test_the_remote_and_the_repository_are_chosen_separately
    with_flat_fixture('repo-flag-both') do |repo|
      remote = add_upstream_remote(repo)
      with_forked_forge(repo) do
        result = sweep(repo, '--remote', remote, '--repo', UPSTREAM)

        assert_matches_oracle(Fixtures::Oracle.load(FLAT_FORGE_ORACLE), result)
        assert(served_invocations.all? { |call| call.include?("--repo #{UPSTREAM}") })
      end
    end
  end
end

class GitflowFixtureForgeOracleTest < OracleTestCase
  ORACLE = GITFLOW_FORGE_ORACLE

  # The arm that makes the default branch's NAME load-bearing in proof
  # (b). Here the default is develop and main is present and is not it,
  # so the two conflicting branches carry merged pull requests based on
  # different branches and must be decided differently. Comparing a base
  # against a hardcoded main gets both wrong at once, and no other table
  # notices.
  def test_report_matches_the_oracle_with_the_forge_answering
    with_gitflow_fixture('gitflow-forge') do |repo|
      with_forge(repo, records: Fixtures::PullRequests::GITFLOW_RECORDS) do
        result = sweep(repo)

        assert_matches_oracle(Fixtures::Oracle.load(ORACLE), result)
        refute_git_complaints(result)
      end
    end
  end
end

class FlatFixtureOracleTest < OracleTestCase
  ORACLE = FLAT_DEGRADED_ORACLE

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
  ORACLE = GITFLOW_ORACLE

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
  # in a per-branch reason. Reporting "no pull request" for a lookup
  # that never happened states an absence nobody checked -- and every
  # proof-b reason is such a statement, not only the one that says so
  # outright: "its pull request was closed" is a claim about pull
  # requests this run never saw.
  def test_no_row_states_a_conclusion_about_pull_requests_that_were_never_read
    with_flat_fixture('reasons') do |repo|
      rows = sweep(repo).rows
      # A report whose branches never reached the forge stage satisfies
      # every claim about what that stage may not say. The flat fixture
      # is used rather than the gitflow one for exactly this: it has
      # eight conflicting branches, and the gitflow repository has none,
      # so the same test there passes without the stage ever running.
      forge_decided = rows.select do |row|
        Fixtures::Oracle.stage(row.reason) == 'proof-b' || row.reason == 'protected:open-pr'
      end
      assert_empty forge_decided.map(&:branch),
                   'a reason stated a conclusion about pull requests nothing asked for'

      reached = rows.count { |row| row.reason == 'proof-a:conflict' }
      assert_operator reached, :>, 0,
                      'no branch reached the stage this is about, so nothing was asserted'
    end
  end
end
