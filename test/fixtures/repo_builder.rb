# frozen_string_literal: true

# Shared machinery for the fixture repositories the stale-branch sweep is
# graded against. Subclasses define #build and the branches they need.
#
# Every repository built here is a throwaway, created under a temporary
# directory and deleted when the test ends. No branch name any fixture
# mentions is a branch of the repository this file is checked into, and
# nothing here reads or writes it.
#
# This file lives under test/fixtures/ rather than test/ so CI's
# test/*_test.rb glob does not run it as a suite of its own; it defines
# no tests.
#
# Three properties are load-bearing, and each exists because its absence
# once hid a real defect or would hide one now:
#
# 1. Setup reproduces the world; it does not repair it. Nothing here runs
#    `git remote set-head`. An earlier generation of these fixtures did,
#    which quietly corrected a stale refs/remotes/<remote>/HEAD before the
#    code under test ever saw it -- and so hid a default-branch bug
#    through two rounds of review. A closing `fetch --prune` is fine and
#    each fixture ends with one, because the sweep's own caller is
#    specified to have fetched first.
#
# 2. Ambient git configuration is neutralized. The initial branch name is
#    passed explicitly rather than inherited from init.defaultBranch, and
#    GIT_CONFIG_GLOBAL/GIT_CONFIG_SYSTEM point at an empty file, so a
#    developer's commit.gpgsign, core.hooksPath, merge.ff, or
#    core.autocrlf cannot change a verdict. Without the explicit initial
#    branch a fixture does not merely drift, it collapses: on a machine
#    defaulting to `master` the bare repo's HEAD names a branch that is
#    never created and the first push fails outright.
#
# 3. A built fixture is used where it was built, never copied or moved.
#    `git worktree add` records absolute paths, so a copied fixture's
#    worktree entry still points at the original, and the row that depends
#    on it would pass because the gitdir file is prunable rather than
#    because the branch is in use.

require 'fileutils'
require 'open3'

module Fixtures
  class RepoBuilder
    Error = Class.new(StandardError)

    # A reserved TLD, assembled rather than written literally so the
    # address never appears in source as a contiguous token.
    IDENTITY_HOST = 'example.test'

    attr_reader :root, :work, :origin

    def initialize(root)
      @root = root
      @origin = File.join(root, 'origin.git')
      @work = File.join(root, 'work')
    end

    # Full refnames, the form the sweep is specified to enumerate: a tag
    # sharing a branch's name makes the short form ambiguous.
    def local_refs
      git('for-each-ref', '--format=%(refname)', 'refs/heads/').lines.map(&:strip)
    end

    # Moves HEAD, for the arms that ask what the sweep does when the
    # developer is standing somewhere other than the default branch.
    def checkout(branch)
      git('checkout', '-q', branch)
    end

    # Detaches HEAD, where the current branch is the empty string rather
    # than a name. `git symbolic-ref -q --short HEAD` exits non-zero here
    # while `rev-parse --abbrev-ref HEAD` cheerfully prints "HEAD".
    def detach_head
      git('checkout', '-q', '--detach')
    end

    def git(*args, dir: work)
      stdout, stderr, status = Open3.capture3(env, 'git', '-C', dir, *args)
      raise Error, "git #{args.join(' ')} failed in #{dir}: #{stderr.strip}" unless status.success?

      stdout
    end

    # The environment every fixture git command runs under. Exposed so a
    # test driving the CLI against a fixture can run it under the same
    # neutralized configuration.
    def env
      @env ||= {
        'GIT_CONFIG_GLOBAL' => empty_config,
        'GIT_CONFIG_SYSTEM' => empty_config,
        'GIT_CONFIG_NOSYSTEM' => '1',
        'GIT_TERMINAL_PROMPT' => '0',
        'GIT_AUTHOR_NAME' => 'Fixture',
        'GIT_COMMITTER_NAME' => 'Fixture',
        'GIT_AUTHOR_EMAIL' => "fixture@#{IDENTITY_HOST}",
        'GIT_COMMITTER_EMAIL' => "fixture@#{IDENTITY_HOST}"
      }
    end

    private

    def empty_config
      @empty_config ||= File.join(root, 'gitconfig-empty')
    end

    def prepare_root
      FileUtils.mkdir_p(root)
      File.write(empty_config, '')
    end

    def init_remote_and_clone(default_branch)
      git('init', '-q', '-b', default_branch, '--bare', 'origin.git', dir: root)
      git('clone', '-q', 'origin.git', 'work', dir: root)
      git('config', 'advice.detachedHead', 'false')
    end

    # Writes a file and commits it, the one-liner most of every table needs.
    def commit(path, contents, message)
      File.write(File.join(work, path), "#{contents}\n")
      git('add', path)
      git('commit', '-qm', message)
    end

    def write_lines(path, lines)
      File.write(File.join(work, path), lines.map { |line| "#{line}\n" }.join)
    end

    def squash_into(target, branch, message)
      git('checkout', '-q', target)
      git('merge', '-q', '--squash', branch)
      git('commit', '-qm', message)
    end
  end
end
