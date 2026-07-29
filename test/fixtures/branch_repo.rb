# frozen_string_literal: true

# Builds a throwaway repo holding one local branch per row of the
# stale-branch decision table, so the sweep's verdicts can be graded
# against a known oracle rather than against reasoning about git.
#
# Every branch name in this file belongs to that throwaway repo, which is
# created under a temporary directory and deleted when the test ends. None
# of them is a branch of the repository this file is checked into, and
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
#    `git remote set-head`. An earlier generation of this fixture did,
#    which quietly corrected a stale refs/remotes/<remote>/HEAD before
#    the code under test ever saw it -- and so hid a default-branch bug
#    through two rounds of review. The closing `fetch --prune` stays,
#    because the sweep's own caller is specified to have fetched first.
#
# 2. Ambient git configuration is neutralized. The initial branch name is
#    passed explicitly rather than inherited from init.defaultBranch, and
#    GIT_CONFIG_GLOBAL/GIT_CONFIG_SYSTEM point at an empty file, so a
#    developer's commit.gpgsign, core.hooksPath, merge.ff, or
#    core.autocrlf cannot change a verdict. Without the explicit initial
#    branch this builder does not merely drift, it collapses: on a machine
#    defaulting to `master` the bare repo's HEAD names a branch that is
#    never created and the first push fails outright.
#
# 3. A built fixture is used where it was built, never copied or moved.
#    `git worktree add` records absolute paths, so a copied fixture's
#    worktree entry still points at the original. The n-worktree row would
#    then pass for the wrong reason: git refuses to delete the branch, but
#    because the gitdir file is prunable rather than because the branch is
#    in use.
#
# Every branch below is a case the sweep must get right; see the oracle
# table for the expected verdict and the reason each one exists.

require 'fileutils'
require 'open3'

module Fixtures
  class BranchRepo
    Error = Class.new(StandardError)

    # A reserved TLD, assembled rather than written literally so the
    # address never appears in source as a contiguous token.
    IDENTITY_HOST = 'example.test'

    # Branches pushed to the remote and then deleted there, leaving a
    # local branch whose upstream is gone -- the shape a real repo
    # accumulates after pull requests merge and the forge deletes their
    # head branches.
    PUSHED_THEN_DELETED = %w[
      a-squash-clean b-main-edited c-merged-main-back d-unpushed
      e-stacked-child f-closed g-open i-cross-fork j-two-merged
      k-merged-and-open
    ].freeze

    # Pushed to the throwaway repo's remote and left in place, matching the
    # canned forge data that gives this branch a still-open pull request.
    # There is no real pull request anywhere; the sweep's forge lookups are
    # answered by a stub.
    PUSHED_AND_KEPT = %w[q-open-but-landed].freeze

    # Branches carrying content that never reached the default branch,
    # distinguished from each other only by their pull-request history.
    CONTENT_NEVER_LANDED = %w[f-closed g-open h-no-pr i-cross-fork k-merged-and-open].freeze

    # Stand-ins for the long-lived branches a team keeps regardless of what
    # any signal says. Each is built as a plain ancestor of the throwaway
    # repo's default branch, so the cheap first pass lists every one of
    # them and only the protected set stands between them and deletion.
    LONG_LIVED = %w[develop staging production gh-pages].freeze

    # Stands in for a manual safety net, protected by its name alone. Also
    # an ancestor, for the same reason as the branches above.
    BACKUP = 'r-spike-backup'

    # A branch sharing its name with a tag that points at the throwaway
    # repo's default branch, so a bare-name lookup resolves to the tag and
    # reports the branch as holding nothing. The branch's own work has not
    # landed, which makes the mistake a wrongful deletion rather than a
    # wrongful keep.
    TAG_SHADOWED = 's-tag-shadow'

    attr_reader :root, :work, :origin

    def initialize(root)
      @root = root
      @origin = File.join(root, 'origin.git')
      @work = File.join(root, 'work')
      @worktree = File.join(root, 'wt')
    end

    # Returns self so a caller can build and use in one expression.
    def build
      FileUtils.mkdir_p(root)
      File.write(empty_config, '')
      init_remote_and_clone
      build_default_branch
      build_ancestor_branch
      build_squash_merged_branches
      build_stacked_pair
      build_unlanded_branches
      build_two_merged_branch
      build_open_but_landed
      build_protected_lookalikes
      build_tag_shadowed_branch
      publish_and_delete_remote_branches
      build_gone_lookalikes
      build_worktree_branch
      git('checkout', '-q', 'main')
      git('fetch', '-q', '--prune', 'origin')
      self
    end

    # Full refnames, the form the sweep is specified to enumerate.
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

    private

    def empty_config
      @empty_config ||= File.join(root, 'gitconfig-empty')
    end

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

    # Writes a file and commits it, the one-liner most of the table needs.
    def commit(path, contents, message)
      File.write(File.join(work, path), "#{contents}\n")
      git('add', path)
      git('commit', '-qm', message)
    end

    def init_remote_and_clone
      git('init', '-q', '-b', 'main', '--bare', 'origin.git', dir: root)
      git('clone', '-q', 'origin.git', 'work', dir: root)
      git('config', 'advice.detachedHead', 'false')
    end

    def build_default_branch
      commit('base.txt', 'base', 'base')
      git('push', '-q', 'origin', 'main')
    end

    # Merged with a real merge commit, so it stays an ancestor of main and
    # the cheap first pass finds it without any content comparison.
    def build_ancestor_branch
      git('checkout', '-qb', 'p1-ancestor')
      commit('p1.txt', 'p1', 'p1 work')
      git('checkout', '-q', 'main')
      git('merge', '-q', '--no-ff', 'p1-ancestor', '-m', 'merge p1-ancestor')
    end

    def build_squash_merged_branches
      squash_clean
      main_edited_after_squash
      main_merged_back_in
      unpushed_commit_after_squash
    end

    # Squash-merged, with main later advancing on an unrelated file: the
    # content comparison still clears it.
    def squash_clean
      git('checkout', '-qb', 'a-squash-clean')
      commit('a.txt', 'a', 'a work')
      squash_into_main('a-squash-clean', 'squash a')
      commit('unrelated.txt', 'u', 'unrelated advance')
    end

    # Squash-merged, then main edits the SAME lines. The content
    # comparison conflicts here, so only the forge can clear it -- which
    # is what makes this row fail when pull-request lookups are
    # unavailable.
    def main_edited_after_squash
      git('checkout', '-qb', 'b-main-edited')
      write_lines('b.txt', %w[l1 l2 l3])
      git('add', 'b.txt')
      git('commit', '-qm', 'b work')
      squash_into_main('b-main-edited', 'squash b')
      write_lines('b.txt', ['l1', 'EDITED-LATER', 'l3'])
      git('commit', '-qam', "main edits b's lines")
    end

    # Squash-merged, then the developer merged main back in -- a tip that
    # is not an ancestor of main yet adds nothing to it.
    def main_merged_back_in
      git('checkout', '-qb', 'c-merged-main-back')
      commit('c.txt', 'c', 'c work')
      squash_into_main('c-merged-main-back', 'squash c')
      git('checkout', '-q', 'c-merged-main-back')
      git('merge', '-q', 'main', '-m', 'merge main into c')
    end

    # Squash-merged, then a real commit made after the last push. The
    # content is at risk, so no signal may clear this branch.
    def unpushed_commit_after_squash
      git('checkout', '-q', 'main')
      git('checkout', '-qb', 'd-unpushed')
      commit('d.txt', 'd', 'd work')
      squash_into_main('d-unpushed', 'squash d')
      git('checkout', '-q', 'd-unpushed')
      commit('d-danger.txt', 'REAL UNPUSHED WORK', 'after last push')
    end

    # A child branch merged into its PARENT, never into the default
    # branch: reaching some other feature branch is not reaching main.
    def build_stacked_pair
      git('checkout', '-q', 'main')
      git('checkout', '-qb', 'e-parent')
      commit('e-parent.txt', 'ep', 'parent work')
      git('checkout', '-qb', 'e-stacked-child')
      commit('e-child.txt', 'ec', 'child work')
      git('checkout', '-q', 'e-parent')
      git('merge', '-q', '--squash', 'e-stacked-child')
      git('commit', '-qm', 'squash child into parent')
    end

    def build_unlanded_branches
      CONTENT_NEVER_LANDED.each do |branch|
        git('checkout', '-q', 'main')
        git('checkout', '-qb', branch)
        commit("#{branch}.txt", branch, "#{branch} work")
      end
    end

    # Two merged pull requests share this head branch and the local tip
    # matches the older one. Main edits the same lines afterwards so the
    # content comparison conflicts and only the forge can clear it --
    # otherwise the row never exercises choosing among pull requests.
    def build_two_merged_branch
      git('checkout', '-q', 'main')
      git('checkout', '-qb', 'j-two-merged')
      write_lines('j.txt', %w[j1 j2 j3])
      git('add', 'j.txt')
      git('commit', '-qm', 'j work')
      squash_into_main('j-two-merged', 'squash j')
      write_lines('j.txt', ['j1', 'J-EDITED-LATER', 'j3'])
      git('commit', '-qam', "main edits j's lines")
    end

    # Content already in the default branch by another route, with its own
    # pull request still open. This is the row that decides whether open
    # pull requests are consulted at all: every other branch carrying an
    # open pull request also fails the content comparison, so a sweep that
    # deletes whatever that comparison clears -- never asking the forge --
    # gets every one of them right by accident, and only this branch
    # catches it.
    def build_open_but_landed
      git('checkout', '-q', 'main')
      git('checkout', '-qb', 'q-open-but-landed')
      commit('q.txt', 'q', 'q work')
      squash_into_main('q-open-but-landed', 'squash q via another pull request')
    end

    # Branches whose only defense is the protected set. Each is a plain
    # ancestor of the default branch and so appears in the first pass's
    # own output, which is what makes the protection load-bearing rather
    # than decorative.
    def build_protected_lookalikes
      git('checkout', '-q', 'main')
      (LONG_LIVED + [BACKUP]).each { |branch| git('branch', '-q', branch) }
    end

    def build_tag_shadowed_branch
      git('checkout', '-q', 'main')
      git('checkout', '-qb', TAG_SHADOWED)
      commit('s.txt', 's', 's work that never landed')
      git('checkout', '-q', 'main')
      git('tag', TAG_SHADOWED, git('rev-parse', 'main').strip)
    end

    def publish_and_delete_remote_branches
      git('checkout', '-q', 'main')
      git('push', '-q', 'origin', 'main')
      (PUSHED_THEN_DELETED + PUSHED_AND_KEPT).each do |branch|
        git('push', '-q', 'origin', "#{branch}:#{branch}")
        git('branch', '-q', "--set-upstream-to=origin/#{branch}", branch)
      end
      PUSHED_THEN_DELETED.each { |branch| git('push', '-q', 'origin', '--delete', branch) }
    end

    # Two branches that a naive "upstream is gone" enumeration would sweep
    # up, and that carry never-pushed work. Both constructions are
    # deliberately odd and must survive intact: normalizing either one
    # deletes the only coverage of its trap.
    def build_gone_lookalikes
      tracks_deleted_local_branch
      marker_text_in_commit_subject
    end

    # Upstream is a deleted LOCAL branch. Nothing was ever pushed, yet
    # `git branch -vv` reports the same ": gone]" a merged branch does.
    def tracks_deleted_local_branch
      git('checkout', '-q', 'main')
      git('checkout', '-qb', 'throwaway')
      git('checkout', '-qb', 'l-tracks-deleted-local')
      commit('l.txt', 'l', 'l work never pushed')
      git('branch', '--set-upstream-to=throwaway', 'l-tracks-deleted-local')
      git('branch', '-q', '-D', 'throwaway')
    end

    # No upstream at all: it is the COMMIT SUBJECT that contains the text
    # a grep-based enumeration keys on.
    def marker_text_in_commit_subject
      git('checkout', '-q', 'main')
      git('checkout', '-qb', 'm-gone-in-subject')
      commit('m.txt', 'm', 'fix [origin/foo: gone] handling in the pruner')
    end

    # Checked out in a second worktree, so it must never become a
    # candidate: git refuses to delete it either way, and a sweep that
    # tries only produces a mid-run error.
    def build_worktree_branch
      git('checkout', '-q', 'main')
      git('branch', '-q', 'n-worktree')
      git('worktree', 'add', '-q', @worktree, 'n-worktree')
    end

    def squash_into_main(branch, message)
      git('checkout', '-q', 'main')
      git('merge', '-q', '--squash', branch)
      git('commit', '-qm', message)
    end

    def write_lines(path, lines)
      File.write(File.join(work, path), lines.map { |line| "#{line}\n" }.join)
    end
  end
end
