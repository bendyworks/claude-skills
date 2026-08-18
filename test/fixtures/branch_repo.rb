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
      e-stacked-child f-closed i-cross-fork j-two-merged
      t-merged-to-release v-open-from-fork
    ].freeze

    # Pushed to the throwaway repo's remote and left in place, matching the
    # canned forge data that gives each a still-open pull request. There is
    # no real pull request anywhere; the sweep's forge lookups are answered
    # by a stub -- but deleting a same-repo head branch on GitHub closes
    # its open pull request, so a branch the stub calls open must keep its
    # remote ref or the stub describes a repository the forge cannot
    # produce. i-cross-fork is exempt and stays deleted above: a fork's
    # head branch lives in the fork, not here.
    PUSHED_AND_KEPT = %w[q-open-but-landed g-open k-merged-and-open].freeze

    # Carries content that never reached the default branch, so proof (a)
    # answers it alone: the merge runs cleanly and produces a different
    # tree, a positive local fact no forge lookup can improve on. It has an
    # open pull request in the stub data, and open-pull-request protection
    # is specified to fire ahead of proof (a), so it never reaches the
    # forge-deciding path below either. e-parent, e-stacked-child,
    # l-tracks-deleted-local, m-gone-in-subject and s-tag-shadow are the
    # rest of this family, each built by its own method for its own trap.
    CONTENT_NEVER_LANDED = %w[g-open].freeze

    # Branches squash-merged into the default branch, which then edited the
    # same lines. proof (a) CONFLICTS on each, so it cannot answer either
    # way and only the forge can decide -- which is the whole point: proof
    # (b) runs solely on branches proof (a) could not clear, so a rejection
    # clause with no conflicting branch behind it has no subject to reject
    # and can be dropped from the sweep entirely with nothing going red.
    #
    # One branch per clause of proof (b), each rejected for a different
    # reason once the stub answers for it:
    #
    #   f-closed            its only pull request is closed, not merged
    #   h-no-pr             no pull request at all
    #   i-cross-fork        the merged pull request came from a fork
    #   k-merged-and-open   a merged pull request, but another is open
    #   t-merged-to-release the merged pull request's base is not default
    #   d-unpushed          the merged pull request's head SHA is not the
    #                       local tip (see #commit_after_the_last_push)
    #
    # All six are KEEP in both tables. They differ from the branches above
    # in what ANSWERS them, which is why the reason is asserted: here the
    # keep is an unanswered question offline and a forge rejection online,
    # never the positive fact that the work is unlanded.
    FORCES_THE_FORGE = %w[
      f-closed h-no-pr i-cross-fork k-merged-and-open t-merged-to-release
    ].freeze

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

    # Adds a file and then removes it, so its net diff against the
    # default branch is empty while its history holds content no other
    # branch ever received. The tip check clears it and the branch is
    # not deletable: deleting it takes the reflog too, and that content
    # is then reachable from nothing.
    ADDED_THEN_REMOVED = 'u-added-then-removed'

    # Content already in the default branch, with an OPEN pull request
    # that came from a fork. --head matches on branch name alone, so a
    # fork's pull request is returned by a query about this branch, and
    # nothing in the reply says whose branch it describes.
    #
    # Proof (b) refuses to let cross-repository evidence CLEAR a branch,
    # and open-pull-request protection deliberately does not apply that
    # filter: protection errs toward keeping, and the cost of being
    # wrong here is one branch kept that could have gone, against
    # deleting a branch somebody still has a pull request open on. This
    # row is what pins that asymmetry -- adding the fork filter to the
    # protection would flip it to DELETE while q-open-but-landed, whose
    # open pull request is from this repository, stayed green.
    OPEN_FROM_FORK = 'v-open-from-fork'

    # Shares its name with a tag pointing at the default branch, and is
    # decided by proof (b) on whether its tip matches a merged pull
    # request's head -- so it is the row that grades the last bare-name
    # lookup the sweep could still have.
    FORGE_TAG_SHADOWED = 'b-main-edited'

    # Where HEAD is left standing, and deletable on the evidence alone.
    CURRENT = 'o-current'

    # Returns self so a caller can build and use in one expression.
    def build
      prepare_root
      init_remote_and_clone('main')
      build_default_branch
      build_ancestor_branch
      build_squash_merged_branches
      build_stacked_pair
      build_unlanded_branches
      build_forge_deciding_branches
      build_two_merged_branch
      build_open_but_landed
      build_open_from_fork
      build_protected_lookalikes
      build_tag_shadowed_branch
      build_added_then_removed
      publish_and_delete_remote_branches
      build_forge_tag_collision
      commit_after_the_last_push
      build_gone_lookalikes
      build_worktree_branch
      git('checkout', '-q', 'main')
      git('fetch', '-q', '--prune', 'origin')
      stand_on_a_non_default_branch
      self
    end

    private

    # HEAD ends on a branch that is neither the default one nor otherwise
    # protected. o-current sits at the default branch's tip, so the cheap
    # first pass lists it and nothing but current-branch protection stands
    # between it and deletion.
    #
    # Leaving HEAD on the default branch instead -- as this fixture once
    # did -- makes the current-branch rule untestable, because the
    # default-branch rule decides that row first. A sweep with no
    # current-branch protection at all then scores full marks on every row
    # of both tables. It also leaves the default-branch rule itself only
    # half-graded, since the two rules were covering for each other.
    #
    # Created after the closing fetch so it has no upstream and was never
    # pushed, which keeps it out of every remote-ref row above.
    def stand_on_a_non_default_branch
      git('checkout', '-qb', CURRENT)
    end

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
      squash_merged_branch_with_work_to_come
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

    # Squash-merged. The commit that puts its content at risk is made
    # later, by #commit_after_the_last_push, once this branch has been
    # pushed and its remote ref deleted.
    def squash_merged_branch_with_work_to_come
      git('checkout', '-q', 'main')
      git('checkout', '-qb', 'd-unpushed')
      write_lines('d.txt', %w[l1 l2 l3])
      git('add', 'd.txt')
      git('commit', '-qm', 'd work')
      squash_into('main', 'd-unpushed', 'squash d')
      write_lines('d.txt', ['l1', 'EDITED-LATER', 'l3'])
      git('commit', '-qam', "main edits d's lines")
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

    # The conflicting shape, built once per branch that has to reach
    # proof (b): squash-merge into the default branch, then edit the same
    # lines there. The merge then conflicts, so the content check can say
    # nothing either way and the pull-request record is the only evidence
    # left. Multi-line files are what make this work -- a one-line file
    # edited on both sides can merge cleanly.
    def build_forge_deciding_branches
      FORCES_THE_FORGE.each do |branch|
        git('checkout', '-q', 'main')
        git('checkout', '-qb', branch)
        write_lines("#{branch}.txt", %w[l1 l2 l3])
        git('add', "#{branch}.txt")
        git('commit', '-qm', "#{branch} work")
        squash_into('main', branch, "squash #{branch}")
        write_lines("#{branch}.txt", ['l1', 'EDITED-LATER', 'l3'])
        git('commit', '-qam', "main edits #{branch}'s lines")
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

    # The same shape as the branch above, and the difference is entirely
    # in who the open pull request belongs to. Built as its twin on
    # purpose: the two rows differ in one field of the forge's reply, so
    # a protection that reads that field wrongly separates them and one
    # goes red while the other does not.
    def build_open_from_fork
      git('checkout', '-q', 'main')
      git('checkout', '-qb', OPEN_FROM_FORK)
      commit('v.txt', 'v', 'v work')
      squash_into('main', OPEN_FROM_FORK, 'squash v via another pull request')
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
      git('tag', TAG_SHADOWED)
    end

    # A second collision, on a branch the forge decides. The first one
    # grades the cheap passes, which resolve a bare name and so read the
    # tag; this grades proof (b), whose tip comparison is the last place
    # a bare name could still be resolved. Pointed at the default
    # branch, so a sweep reading the tag would compare the wrong object
    # to the pull request's head and keep a branch it should delete.
    #
    # Made after the pushes, because `git push origin <name>` refuses a
    # name that matches both a branch and a tag.
    def build_forge_tag_collision
      git('tag', FORGE_TAG_SHADOWED, 'main')
    end

    def build_added_then_removed
      git('checkout', '-q', 'main')
      git('checkout', '-qb', ADDED_THEN_REMOVED)
      commit('u-research.txt', 'THE ONLY COPY OF THIS RESEARCH', 'research worth keeping')
      git('rm', '-q', 'u-research.txt')
      git('commit', '-qm', 'drop the research file')
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

    # The commit that makes d-unpushed dangerous, made after every push
    # has happened so no remote ever receives it. Ordering is the entire
    # point: made any earlier, this commit rides along in the bulk push
    # above and the branch's tip reaches origin's object store, leaving
    # the fixture with no branch that carries work a remote has never
    # seen -- while the branch name, this method, and the table's own
    # prose all still promise one.
    def commit_after_the_last_push
      git('checkout', '-q', 'd-unpushed')
      commit('d-danger.txt', 'REAL UNPUSHED WORK', 'after last push')
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
      git('branch', '-q', '--set-upstream-to=throwaway', 'l-tracks-deleted-local')
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
