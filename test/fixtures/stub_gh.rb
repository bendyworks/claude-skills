#!/usr/bin/env ruby
# frozen_string_literal: true

# Stand-in for the GitHub CLI, serving canned pull-request data to the
# sweep's forge tests. Installed onto PATH under the name `gh` by
# CliTestCase's serving-stub seam, which also names the two logs it
# reports through.
#
# This file lives under test/fixtures/ rather than test/ so CI's
# test/*_test.rb glob does not run it as a suite of its own. Its own
# tests live in test/stub_gh_test.rb, and they run it the way the sweep
# does -- as a program on PATH -- rather than by loading it.
#
# It mimics the real CLI where the difference would change a verdict:
#
#   --head matches on branch NAME alone, because gh offers no way to
#   scope it to an owner. A fork's pull request therefore comes back
#   from a query about your own branch, which is why the sweep has to
#   read isCrossRepository rather than trusting the filter.
#
#   --state defaults to open, so a sweep that forgets --state all sees
#   no merged pull request at all and keeps everything.
#
#   --limit defaults to 30 and truncates in silence.
#
#   A query that matches nothing is an empty array and exit 0. A
#   failure is a message on stderr and exit 1 -- the shape the sweep
#   degrades on, and never confusable with an empty result.
#
#   STUB_GH_FAIL and STUB_GH_GARBAGE inject the two ways an answer can
#   be useless: a non-zero exit, and a clean exit carrying something
#   that is not JSON. Both are served, never refused, because the sweep
#   is required to degrade on each.
#
#   With no --repo, the real client answers for the repository it
#   resolves from its own working directory, which is the resolution the
#   sweep leaves to it. The data file's @cwd key stands for that.
#
# Everything else fails closed. An unserved subcommand, absent data, a
# repo the data does not describe, a --json field a record does not
# carry: each is recorded as a refusal, which fails the test that
# caused it. The alternative is answering a question this stub does not
# actually know, and a plausible empty answer is exactly what a sweep
# reads as "no pull request" -- the one conclusion these fixtures exist
# to keep it from reaching without evidence.

require 'json'

module StubGh
  # gh's own defaults, reproduced because a sweep that omits either
  # flag must see what it would really see.
  DEFAULT_STATE = 'open'
  DEFAULT_LIMIT = 30

  module_function

  # Variables that would make a real gh answer about something other
  # than what the sweep asked. Refused rather than honoured, because
  # honouring one produces a plausible answer -- [] with exit 0, or a
  # colour-escaped body -- and a plausible answer is what this whole
  # stub exists to keep out of a verdict. The sweep is required to
  # neutralize them for its children; this is what notices when it
  # stops.
  REDIRECTING_ENV_KEYS = %w[GH_REPO CLICOLOR_FORCE GH_FORCE_TTY].freeze

  def main(argv)
    log_invocation(argv)
    refuse_redirecting_environment
    fail_as_configured
    garble_as_configured
    mis_shape_as_configured
    command = argv.take(2).join(' ')
    refuse("unserved command: #{command.empty? ? '(none)' : command}") unless command == 'pr list'
    list_pull_requests(parse(argv.drop(2)))
  end

  # Every invocation, whether it goes on to be served or refused. A
  # call log that recorded only the successes could not tell a sweep
  # that never asked from one whose question was thrown out.
  def log_invocation(argv)
    log = ENV.fetch('CLI_STUB_LOG', nil)
    abort 'stub gh: CLI_STUB_LOG is unset; nothing would record this call' if log.nil?

    # The working directory goes on the line too. It is how the sweep
    # tells gh which project to answer about when no --repo is given,
    # and nothing else here can see it: a sweep that stopped passing
    # chdir would read the pull requests of whatever directory it
    # happened to be started from, and every verdict would still look
    # right.
    File.open(log, 'a') { |file| file.puts("#{['gh', *argv].join(' ')} @#{Dir.pwd}") }
  end

  def refuse_redirecting_environment
    leaked = REDIRECTING_ENV_KEYS.select { |key| ENV[key] }
    return if leaked.empty?

    refuse("#{leaked.join(', ')} reached me; a real gh would answer somewhere else")
  end

  # The unauthenticated / offline / not-a-GitHub-remote case. It is a
  # served answer rather than a refusal: the sweep is required to
  # degrade on it, so a test asking for it is exercising the CLI, not
  # missing a stub.
  # STUB_GH_FAIL=1 fails with a message; =2 fails saying nothing at all,
  # which a caller quoting gh's stderr has to have something to say
  # about.
  def fail_as_configured
    mode = ENV.fetch('STUB_GH_FAIL', nil)
    return unless %w[1 2].include?(mode)

    warn 'error connecting to api.github.com' if mode == '1'
    exit 1
  end

  # An answer that is not the JSON the caller asked for, with a clean
  # exit: a proxy serving an error page, a wrapper printing a notice on
  # stdout. Like the failure above it is served rather than refused,
  # because the sweep is required to degrade on it -- and it is a
  # different code path from a non-zero exit, reached by a parse error
  # rather than by a status.
  def garble_as_configured
    return unless ENV['STUB_GH_GARBAGE'] == '1'

    puts '<html><body>gateway timeout</body></html>'
    exit 0
  end

  # Valid JSON of the wrong shape, with a clean exit: the envelope a
  # wrapper or a proxy answers with. It parses, so the parse rescue
  # never fires, and a sweep that took it at face value would read every
  # branch as having no pull request.
  # =1 is an envelope object; =2 is a list holding something that is not
  # a pull request. Both parse, and the second is the one a caller that
  # checked only for an Array would walk straight into.
  def mis_shape_as_configured
    case ENV.fetch('STUB_GH_SHAPE', nil)
    when '1' then puts JSON.generate('message' => 'Not Found')
    when '2' then puts JSON.generate(['not a pull request'])
    else return
    end
    exit 0
  end

  # Refusals go to their own log and take the test down with them. A
  # refusal cannot be reported through the exit status alone, because
  # the sweep treats a failing gh as a repository-wide degradation and
  # carries on -- so a stub that could only exit 1 would be
  # indistinguishable from the case above, and a test meaning to serve
  # data would quietly pass having served none.
  def refuse(message)
    warn "stub gh: #{message}"
    refusals = ENV.fetch('CLI_STUB_REFUSALS', nil)
    abort 'stub gh: CLI_STUB_REFUSALS is unset; a refusal would go unreported' if refusals.nil?

    File.open(refusals, 'a') { |file| file.puts("stub gh: #{message}") }
    exit 1
  end

  # Flags gh takes as `--flag value`, never `--flag=value` in what the
  # sweep sends. A flag this stub does not know is refused rather than
  # skipped: skipping it would silently widen a query the test believes
  # it narrowed.
  VALUE_FLAGS = {
    '--repo' => :repo, '-R' => :repo,
    '--head' => :head, '-H' => :head,
    '--state' => :state,
    '--limit' => :limit,
    '--json' => :json
  }.freeze

  def parse(argv)
    options = { state: DEFAULT_STATE, limit: DEFAULT_LIMIT }
    until argv.empty?
      flag = argv.shift
      key = VALUE_FLAGS[flag]
      refuse("unserved flag: #{flag}") if key.nil?

      value = argv.shift
      refuse("#{flag} given no value") if value.nil?
      options[key] = value
    end
    options
  end

  def list_pull_requests(options)
    fields = requested_fields(options)
    records = records_for(options[:repo])
    matched = records.select { |record| matches?(record, options) }
    puts JSON.generate(matched.first(limit_of(options)).map { |record| project(record, fields) })
  end

  # The sweep reads JSON, so a run without --json would hand it gh's
  # human table. Refused rather than served, because the sweep parsing
  # that table is a bug no verdict would reveal.
  def requested_fields(options)
    raw = options[:json]
    refuse('pr list without --json') if raw.nil?

    fields = raw.split(',').map(&:strip).reject(&:empty?)
    refuse("--json given no fields: #{raw.inspect}") if fields.empty?

    fields
  end

  # What the real client answers for when no --repo is given: the
  # repository it resolves from its own working directory. The sweep
  # leaves that resolution to gh rather than deriving it, so the stub
  # needs a key standing for it -- named so it cannot be mistaken for a
  # repository, since a query naming a repository the data does not
  # describe is a refusal and this one must not be.
  CWD_KEY = '@cwd'

  # A query naming a repository the data does not describe is refused
  # rather than answered empty. Serving [] there would let a sweep that
  # asks the wrong repository -- a fork's own, rather than the upstream
  # its pull requests live in -- come back empty and read that as "no
  # pull request".
  def records_for(repo)
    path = ENV.fetch('STUB_GH_PRS', nil)
    refuse('STUB_GH_PRS is unset; there is no data to serve') if path.nil?
    refuse("STUB_GH_PRS names no such file: #{path}") unless File.exist?(path)

    data = JSON.parse(File.read(path))
    key = repo || CWD_KEY
    unless data.key?(key)
      refuse("no data for #{key}; served keys are #{data.keys.join(', ')}")
    end

    data.fetch(key)
  end

  # --head compares branch names and nothing else, which is gh's own
  # behavior and the reason a fork's pull request is returned by a
  # query about your branch.
  def matches?(record, options)
    return false if options[:head] && record['headRefName'] != options[:head]

    options[:state] == 'all' || record['state'].to_s.downcase == options[:state]
  end

  def limit_of(options)
    limit = Integer(options[:limit], exception: false)
    refuse("--limit is not a positive number: #{options[:limit].inspect}") if limit.nil? || limit < 1

    limit
  end

  # A field the record does not carry would reach the sweep as null,
  # and a null read as "not merged" or "not a fork" is a verdict
  # reached on a typo. gh refuses an unknown field name; so does this.
  def project(record, fields)
    missing = fields.reject { |field| record.key?(field) }
    refuse("unknown --json field(s) for pull request ##{record['number']}: #{missing.join(', ')}") if missing.any?

    fields.to_h { |field| [field, record[field]] }
  end
end

StubGh.main(ARGV.dup) if $PROGRAM_NAME == __FILE__
