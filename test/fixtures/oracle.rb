# frozen_string_literal: true

# Loader for the verdict tables under test/fixtures/, which are the
# specification bin/stale-branches is built against: one row per local
# branch, naming the verdict the sweep must reach and the reason key its
# report must carry.
#
# This file lives under test/fixtures/ rather than test/ so CI's
# test/*_test.rb glob does not run it as a suite of its own; it defines
# no tests. Its own tests live in test/stale_branches_test.rb.
#
# The reason is half the specification, and the more load-bearing half.
# Grading on the verdict alone cannot tell a branch the sweep protected
# from one git refused to delete by itself, and cannot tell a branch kept
# because the evidence says its work is unlanded from one kept because
# the evidence could not answer. REASONS is the closed vocabulary that
# makes those distinctions assertable, and the tables' own headers
# document it in the same terms.

module Fixtures
  module Oracle
    Error = Class.new(StandardError)

    # One expected row: the branch, the verdict the sweep must reach, the
    # reason key its report must carry, and prose saying why the row
    # exists.
    Row = Struct.new(:branch, :verdict, :reason, :why)

    VERDICTS = %w[KEEP DELETE].freeze

    # Every reason a row may name, in the order the sweep decides them.
    # A key absent from this list is a typo; a key present in it and
    # claimed by no row in any table is an untested rule, which is the
    # more dangerous of the two because nothing goes red.
    REASONS = %w[
      protected:default
      protected:current
      protected:worktree
      protected:long-lived
      protected:backup
      protected:open-pr
      pass1:ancestor
      proof-a:content-landed
      proof-a:tip-only
      proof-a:conflict
      proof-b:pr-merged
      proof-b:pr-tip-differs
      proof-b:pr-closed
      proof-b:pr-from-fork
      proof-b:pr-other-base
      proof-b:no-pr
      kept:not-landed
    ].freeze

    # The prefix before the colon names the stage that reached the
    # verdict. A table that demands deletions from only one stage is
    # satisfied by a sweep that implements only that stage.
    #
    # protected: is the one prefix that names a kind of answer rather
    # than a cost. Every other protection is decided from a name or from
    # where HEAD is standing and costs nothing, while protected:open-pr
    # costs a forge query per candidate -- but what it has in common with
    # the rest is that it refuses deletion whatever the content says,
    # which is why it sits ahead of proof (a) rather than beside it.
    def self.stage(reason)
      reason.split(':').first
    end

    # A missing or empty table is a hard error, never an empty pass. A
    # grader that silently asserts nothing is indistinguishable from a
    # passing suite, which is the failure these tables exist to prevent.
    def self.load(path)
      raise Error, "oracle table not found: #{path}" unless File.exist?(path)

      rows = File.readlines(path).filter_map { |line| parse(line, path) }
      raise Error, "oracle table has no rows: #{path}" if rows.empty?

      rows
    end

    # The comment marker is anchored to column 0: git permits a branch
    # name beginning with '#', and treating an indented one as a comment
    # would drop that row from the table without a word.
    #
    # The split is capped at four fields so the trailing prose stays one
    # column no matter how much whitespace it contains. A branch name
    # cannot contain whitespace -- git refuses to create one -- so the
    # first three fields are unambiguous. The line is stripped before
    # splitting because a capped split preserves trailing whitespace as a
    # final empty field, which would reach the reason guard as "" rather
    # than nil and be reported as an unknown reason rather than a short
    # row. The comment test above deliberately reads the UNstripped line,
    # so that a marker only starts a comment in column 0.
    def self.parse(line, path)
      return if line.strip.empty? || line.start_with?('#')

      branch, verdict, reason, why = line.strip.split(' ', 4)
      raise Error, "malformed oracle row in #{path}: #{line.inspect}" if reason.nil?
      raise Error, "unknown verdict #{verdict.inspect} in #{path}" unless VERDICTS.include?(verdict)
      raise Error, "unknown reason #{reason.inspect} in #{path}" unless REASONS.include?(reason)

      Row.new(branch, verdict, reason, why.to_s.strip)
    end
    private_class_method :parse
  end
end
