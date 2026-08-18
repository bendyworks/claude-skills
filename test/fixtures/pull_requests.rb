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
  # Which is why nothing here is incidental -- each record is the only
  # subject some rule of proof (b) has, and dropping one would leave that
  # rule with nothing to decide.
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
      Record.new(112, 'OPEN', 'k-merged-and-open', 'k-merged-and-open', 'main', false),
      Record.new(113, 'OPEN', 'q-open-but-landed', 'q-open-but-landed', 'main', false),
      Record.new(114, 'MERGED', 't-merged-to-release', 't-merged-to-release', 'release/2.0', false),
      Record.new(115, 'OPEN', 'v-open-from-fork', 'v-open-from-fork', 'main', true)
    ].freeze

    # A rev already spelled as a full object name is taken as written;
    # anything else is resolved through refs/heads, never as a bare
    # name, because a bare name resolves through refs/tags first and the
    # fixture builds a tag that shadows a branch.
    OBJECT_NAME = /\A[0-9a-f]{40}\z/

    module_function

    def data(repo, key: CWD)
      { key => RECORDS.map { |record| serialize(repo, record) } }
    end

    def write(repo, path, key: CWD)
      File.write(path, JSON.pretty_generate(data(repo, key: key)))
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
