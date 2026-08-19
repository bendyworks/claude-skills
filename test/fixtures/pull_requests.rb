# frozen_string_literal: true

require 'json'

require_relative 'forge_stub'

module Fixtures
  # The canned pull-request records the stub GitHub CLI serves for
  # BranchRepo, written against the repository after it is built so
  # every head SHA is a real one. A hand-written SHA would compare equal
  # to nothing and turn every rule that reads it into a rule that always
  # rejects, which no verdict would reveal: the branches it decides are
  # KEEP either way.
  #
  # This is the other half of the flat fixture's specification. The
  # repository supplies what git can see, and these records supply what
  # the forge says; expected.txt grades the sweep against both at once.
  #
  # Most records are the only subject some rule of proof (b) has, and
  # dropping one leaves that rule with nothing to decide. Three are not:
  # a-squash-clean, c-merged-main-back and e-stacked-child are settled
  # before proof (b) runs, and deleting them leaves the suite green.
  # They stay because open-pull-request protection queries those
  # branches too, and a project whose pull requests stopped at the
  # interesting branches is not one gh could describe.
  module PullRequests
    # What the stub answers for when the sweep passes no --repo, which
    # is the ordinary case: gh resolves the repository from its own
    # working directory, and the sweep leaves that resolution to it.
    CWD = ForgeStub::CWD

    # A head SHA belonging to no object in the fixture. The second of
    # j-two-merged's two merged pull requests carries it, so the sweep
    # has to clear that branch on the OLDER of the two rather than on
    # whichever it happens to read last.
    UNKNOWN_SHA = ('0' * 40).freeze

    # Stands for the project a fork's pull requests actually live in.
    # A fork's own repository is where gh looks by default and is
    # exactly where they are not.
    UPSTREAM = 'github.com/fixture/upstream'

    Record = Struct.new(:number, :state, :branch, :head, :base, :cross_repo)

    # One record per row of expected.txt that needs the forge to decide
    # it, plus the branches the content check settles first -- those are
    # here because open-pull-request protection runs ahead of the content
    # check and therefore queries them too, and a repository whose data
    # stopped at the interesting branches would not be one gh could
    # produce.
    #
    # h-no-pr is the deliberate absence: no record names it, which is
    # the only way to test what the sweep says when a branch has no pull
    # request at all.
    RECORDS = [
      Record.new(101, 'MERGED', 'a-squash-clean', 'a-squash-clean', 'main', false),
      Record.new(102, 'MERGED', 'b-main-edited', 'b-main-edited', 'main', false),
      Record.new(103, 'MERGED', 'c-merged-main-back', 'c-merged-main-back~1', 'main', false),
      Record.new(104, 'MERGED', 'd-unpushed', 'd-unpushed~1', 'main', false),
      Record.new(105, 'MERGED', 'e-stacked-child', 'e-stacked-child', 'e-parent', false),
      Record.new(106, 'CLOSED', 'f-closed', 'f-closed', 'main', false),
      Record.new(107, 'OPEN', 'g-open', 'g-open', 'main', false),
      Record.new(108, 'MERGED', 'i-cross-fork', 'i-cross-fork', 'main', true),
      Record.new(109, 'MERGED', 'j-two-merged', 'j-two-merged', 'main', false),
      Record.new(110, 'MERGED', 'j-two-merged', UNKNOWN_SHA, 'main', false),
      Record.new(111, 'MERGED', 'k-merged-and-open', 'k-merged-and-open', 'main', false),
      # A third record on the same branch, ahead of the open one, so a
      # limit that truncates drops the OPEN record rather than a merged
      # one -- which is the direction that costs a keep the sweep
      # promises. Nothing else here has more than two.
      Record.new(116, 'MERGED', 'k-merged-and-open', 'k-merged-and-open', 'main', false),
      Record.new(112, 'OPEN', 'k-merged-and-open', 'k-merged-and-open', 'main', false),
      Record.new(113, 'OPEN', 'q-open-but-landed', 'q-open-but-landed', 'main', false),
      Record.new(114, 'MERGED', 't-merged-to-release', 't-merged-to-release', 'release/2.0', false),
      Record.new(115, 'OPEN', 'v-open-from-fork', 'v-open-from-fork', 'main', true)
    ].freeze

    # The gitflow repository's records, and the reason it has any. Both
    # of its conflicting branches carry a merged pull request, and the
    # two differ only in the branch they were based on: one on develop,
    # which is that repository's default, and one on main, which exists
    # there and is not.
    #
    # A sweep comparing a base against a hardcoded main gets both wrong
    # in opposite directions, and nothing in the flat fixture can catch
    # it -- there the default branch IS main. Hardcoding it passed the
    # whole suite before these two rows existed.
    GITFLOW_RECORDS = [
      Record.new(201, 'MERGED', 'gf-landed-on-develop', 'gf-landed-on-develop',
                 'develop', false),
      Record.new(202, 'MERGED', 'gf-landed-on-main', 'gf-landed-on-main', 'main', false)
    ].freeze

    # The same pull requests as a clone of a fork actually sees them.
    # Every one of your own goes from your fork to the upstream project,
    # so GitHub reports all of them cross-repository -- which is the
    # whole reason --repo has to stand the fork clause down, and the
    # reason reusing RECORDS here graded the fork arm against records no
    # fork clone can produce.
    FORK_RECORDS = RECORDS.map do |record|
      Record.new(record.number, record.state, record.branch, record.head,
                 record.base, true)
    end.freeze

    # A rev already spelled as a full object name is taken as written;
    # anything else is resolved through refs/heads, never as a bare
    # name, because a bare name resolves through refs/tags first and the
    # fixture builds a tag that shadows a branch.
    OBJECT_NAME = /\A[0-9a-f]{40}\z/

    module_function

    def data(repo, key: CWD, records: RECORDS)
      { key => records.map { |record| serialize(repo, record) } }
    end

    def write(repo, path, records: RECORDS)
      File.write(path, JSON.pretty_generate(data(repo, records: records)))
      path
    end

    # A clone of a fork: gh resolves the fork from the working
    # directory, and the fork has no pull requests, because they were
    # all opened against the upstream project. Both keys are present
    # and only one of them holds anything, which is the shape that
    # makes asking the wrong one an answer rather than an error --
    # and an answer of [] is what a sweep reads as "no pull request".
    def fork_data(repo)
      { CWD => [] }.merge(data(repo, key: UPSTREAM, records: FORK_RECORDS))
    end

    def write_fork(repo, path)
      File.write(path, JSON.pretty_generate(fork_data(repo)))
      path
    end

    def serialize(repo, record)
      { 'number' => record.number,
        'state' => record.state,
        'headRefName' => record.branch,
        'headRefOid' => resolve(repo, record.head),
        'baseRefName' => record.base,
        'isCrossRepository' => record.cross_repo }
    end

    def resolve(repo, rev)
      return rev if rev.match?(OBJECT_NAME)

      repo.git('rev-parse', "refs/heads/#{rev}").strip
    end
  end
end
