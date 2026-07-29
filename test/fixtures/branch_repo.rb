# frozen_string_literal: true

require_relative 'repo_builder'

module Fixtures
  # A throwaway repository holding one local branch per row of the
  # stale-branch decision table, so the sweep's verdicts can be graded
  # against a known oracle rather than against reasoning about git. Every
  # branch named here belongs to that throwaway repository; see
  # repo_builder.rb for what that means and for the properties its setup
  # deliberately preserves.
  #
  # The default branch is main throughout, which is the common case and
  # the one this fixture is for. GitflowRepo covers the repository where
  # that assumption is wrong.
  class BranchRepo < RepoBuilder
    # Branches pushed to the remote and then deleted there, leaving a
    # local branch whose upstream is gone -- the shape a working
    # repository accumulates after pull requests merge and the forge
    # deletes their head branches.
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

    # Returns self so a caller can build and use in one expression.
    def build
      prepare_root
      init_remote_and_clone('main')
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

    private

    def worktree_path
      File.join(root, 'wt')
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
      squash_into('main', 'a-squash-clean', 'squash a')
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
      squash_into('main', 'b-main-edited', 'squash b')
      write_lines('b.txt', ['l1', 'EDITED-LATER', 'l3'])
      git('commit', '-qam', "main edits b's lines")
    end

    # Squash-merged, then the developer merged main back in -- a tip that
    # is not an ancestor of main yet adds nothing to it.
    def main_merged_back_in
      git('checkout', '-qb', 'c-merged-main-back')
      commit('c.txt', 'c', 'c work')
      squash_into('main', 'c-merged-main-back', 'squash c')
      git('checkout', '-q', 'c-merged-main-back')
      git('merge', '-q', 'main', '-m', 'merge main into c')
    end

    # Squash-merged, then a real commit made after the last push. The
    # content is at risk, so no signal may clear this branch.
    def unpushed_commit_after_squash
      git('checkout', '-q', 'main')
      git('checkout', '-qb', 'd-unpushed')
      commit('d.txt', 'd', 'd work')
      squash_into('main', 'd-unpushed', 'squash d')
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
      squash_into('e-parent', 'e-stacked-child', 'squash child into parent')
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
      squash_into('main', 'j-two-merged', 'squash j')
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
      squash_into('main', 'q-open-but-landed', 'squash q via another pull request')
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
      git('worktree', 'add', '-q', worktree_path, 'n-worktree')
    end
  end
end
