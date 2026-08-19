# frozen_string_literal: true

require_relative 'repo_builder'

module Fixtures
  # A throwaway repository whose default branch is develop, with a
  # non-default main alongside it. Every branch named here belongs to that
  # throwaway repository; see repo_builder.rb for what that means and for
  # the properties its setup deliberately preserves.
  #
  # This shape exists because the flat fixture holds the default branch
  # constant at main, and so cannot fail when a sweep assumes main is the
  # answer. Here that assumption is wrong twice over: main is not the
  # default, and it carries work develop does not have, so measuring
  # against it clears a branch whose changes never reached the branch the
  # team actually ships.
  #
  # It also carries the two verdicts the earlier version of this fixture
  # could not produce. Every branch in it used to be a keeper, which meant
  # a sweep that kept everything unconditionally scored full marks; the
  # ancestor and the squash-merged branch below are what make a verdict of
  # DELETE something the fixture can demand.
  #
  # The build ends with HEAD detached, where there is no current branch to
  # protect at all. No row changes, and that is the assertion: every
  # verdict here survives the sweep running from a detached HEAD, and no
  # branch is wrongly saved by a current-branch rule that found nothing to
  # protect.
  #
  # This arm deliberately does NOT grade `symbolic-ref -q --short HEAD`
  # against `rev-parse --abbrev-ref HEAD`, which differ here -- the first
  # fails, the second prints the string "HEAD". No fixture can grade that
  # difference, because a sweep taking "HEAD" for a branch name protects a
  # branch that cannot exist: git refuses to create one ("fatal: 'HEAD' is
  # not a valid branch name"), so no row's verdict can turn on it.
  class GitflowRepo < RepoBuilder
    DEFAULT_BRANCH = 'develop'

    # Merged into develop and therefore deletable on the evidence alone.
    # Its name is the only thing that saves it, which is what makes the
    # release/* rule load-bearing rather than decorative.
    RELEASE = 'release/1.x'

    # Merged into develop with no protection of any kind: the row that
    # fails when a sweep keeps everything.
    ANCESTOR = 'gf-ancestor'
    SQUASHED = 'gf-squashed'

    # Merged into main only. A sweep measuring against main clears it,
    # while its changes have never reached develop.
    MAIN_ONLY = 'merged-to-main-only'

    # Shares its name with a tag pointing at develop, so a bare-name
    # lookup reports the branch as holding nothing while its own work has
    # not landed.
    TAG_SHADOWED = 'amb'

    # The pair that makes the default branch's NAME load-bearing in
    # proof (b). Both conflict against develop, so both reach the forge,
    # and their merged pull requests differ only in which branch they
    # were based on: one on develop, which is this repository's default,
    # and one on main, which exists here and is not.
    #
    # A sweep comparing a pull request's base against a hardcoded main
    # gets both wrong, in opposite directions -- it keeps the branch
    # that landed and deletes the branch that did not. Nothing in the
    # flat fixture can catch that, because there the default branch IS
    # main, and the flat table's t-merged-to-release only shows that
    # SOME other base is rejected, not that the right one is accepted.
    LANDED_ON_DEFAULT = 'gf-landed-on-develop'
    LANDED_ON_MAIN = 'gf-landed-on-main'

    def build
      prepare_root
      init_remote_and_clone(DEFAULT_BRANCH)
      build_develop
      build_non_default_main
      build_merged_to_main_only
      build_squashed_into_develop
      build_deletable_and_protected_ancestors
      build_tag_shadowed_branch
      build_conflicting_pair
      git('checkout', '-q', DEFAULT_BRANCH)
      git('fetch', '-q', '--prune', 'origin')
      detach_head
      self
    end

    private

    def build_develop
      commit('base.txt', 'base', 'base')
      git('push', '-q', 'origin', "#{DEFAULT_BRANCH}:#{DEFAULT_BRANCH}")
      git('branch', '-q', "--set-upstream-to=origin/#{DEFAULT_BRANCH}", DEFAULT_BRANCH)
    end

    # Carries work develop does not have, so it is not an ancestor of the
    # default branch and its keep is decided by the protected set rather
    # than by the evidence. The oracle asserts the reason, not just the
    # verdict, which is what makes that distinction testable.
    def build_non_default_main
      git('checkout', '-qb', 'main')
      commit('release.txt', 'release', 'release-only work')
      git('push', '-q', 'origin', 'main:main')
      git('branch', '-q', '--set-upstream-to=origin/main', 'main')
    end

    def build_merged_to_main_only
      git('checkout', '-qb', MAIN_ONLY, DEFAULT_BRANCH)
      commit('f.txt', 'f', 'feature work')
      squash_into('main', MAIN_ONLY, 'squash feature into main')
      git('push', '-q', 'origin', 'main:main')
    end

    def build_squashed_into_develop
      git('checkout', '-qb', SQUASHED, DEFAULT_BRANCH)
      commit('g.txt', 'g', 'work that landed on develop')
      squash_into(DEFAULT_BRANCH, SQUASHED, 'squash into develop')
      git('push', '-q', 'origin', "#{DEFAULT_BRANCH}:#{DEFAULT_BRANCH}")
    end

    # Two branches at develop's tip, identical in every respect the
    # evidence can see. Only the name tells them apart, so the pair
    # isolates the protected-name rule from everything else the sweep does.
    def build_deletable_and_protected_ancestors
      git('checkout', '-q', DEFAULT_BRANCH)
      git('branch', '-q', ANCESTOR)
      git('branch', '-q', RELEASE)
    end

    def build_tag_shadowed_branch
      git('checkout', '-qb', TAG_SHADOWED, DEFAULT_BRANCH)
      commit('amb.txt', 'a', 'amb work that never landed')
      git('checkout', '-q', DEFAULT_BRANCH)
      git('tag', TAG_SHADOWED)
    end

    # Each is squash-merged into a different branch, and then the lines
    # it touched are edited again on develop -- which is what makes
    # merging it back into develop conflict, and a conflict is the only
    # route to the forge. Without that second edit the content check
    # answers both of them and neither ever reaches proof (b).
    # Both branches this leaves behind are measured against what the
    # remote has, so the commits it adds to develop and main are pushed:
    # the second edit is what produces the conflict, and a remote that
    # never received it describes a repository where neither branch
    # reaches the forge at all.
    def build_conflicting_pair
      conflict_after_squashing_into(DEFAULT_BRANCH, LANDED_ON_DEFAULT, 'gfd.txt')
      conflict_after_squashing_into('main', LANDED_ON_MAIN, 'gfm.txt')
      git('push', '-q', 'origin', "#{DEFAULT_BRANCH}:#{DEFAULT_BRANCH}", 'main:main')
    end

    def conflict_after_squashing_into(target, branch, path)
      git('checkout', '-q', DEFAULT_BRANCH)
      write_lines(path, %w[one two three])
      git('add', path)
      git('commit', '-qm', "#{path} on #{DEFAULT_BRANCH}")

      git('checkout', '-qb', branch, DEFAULT_BRANCH)
      write_lines(path, %w[one BRANCH-EDIT three])
      git('commit', '-qam', "#{branch} edits #{path}")
      squash_into(target, branch, "squash #{branch} into #{target}")

      git('checkout', '-q', DEFAULT_BRANCH)
      write_lines(path, %w[one DEVELOP-EDITED-LATER three])
      git('commit', '-qam', "#{DEFAULT_BRANCH} edits #{path} again")
    end
  end
end
