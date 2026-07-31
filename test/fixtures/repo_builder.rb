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
#    specified to have fetched first -- but that fetch is pinned with
#    remote.origin.followRemoteHEAD=never. Left unpinned, git 2.48 and
#    newer create refs/remotes/origin/HEAD during that fetch while older
#    git does not, so the fixtures would build differently on the two
#    gits CI might supply, and the newer one would be performing exactly
#    the repair this property forbids. Absence is the deliberate state:
#    the default branch is resolved from `ls-remote --symref`, which asks
#    the remote rather than a local cache of it.
#
# 2. Ambient git configuration is neutralized, and so is ambient git
#    ENVIRONMENT. Pointing GIT_CONFIG_GLOBAL/GIT_CONFIG_SYSTEM at an empty
#    file covers only configuration that arrives through a file: the
#    GIT_CONFIG_COUNT/GIT_CONFIG_KEY_n/GIT_CONFIG_VALUE_n form bypasses
#    both, and core.hooksPath arriving that way is arbitrary script
#    execution during a build. The variables naming a repository are worse
#    still, because `git -C <dir>` does not override an inherited GIT_DIR
#    and Open3.capture3 MERGES its env hash into the parent's rather than
#    replacing it -- so a build inheriting one operates on whatever
#    repository it names, reporting success the whole way. NEUTRALIZED_KEYS
#    is therefore not a tidiness list; it is what keeps a build inside the
#    directory it created. The initial branch name is likewise passed
#    explicitly rather than inherited from init.defaultBranch: without it a
#    fixture does not merely drift, it collapses, because on a machine
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
require 'tmpdir'

module Fixtures
  class RepoBuilder
    Error = Class.new(StandardError)

    # Written out rather than assembled from parts. CONTRIBUTING
    # prescribes example.com for addresses in this repo, and
    # check-identifiers.sh matches a whole address rather than a domain:
    # an address split across an interpolation is one the gate cannot
    # see, so assembling it would buy nothing and would hide a real
    # address if this constant were ever changed to one.
    IDENTITY_EMAIL = 'fixture@example.com'

    # Git environment variables that must not survive into a build,
    # deleted rather than overridden (Open3 unsets a key whose value is
    # nil). Three families, each able to defeat the containment this
    # class promises:
    #
    #   Repository location -- redirects commands to another repository
    #   entirely, `git -C` notwithstanding.
    #   Configuration injection -- reaches git without touching either
    #   config file, so the empty-file pointers below do not cover it.
    #   Transport and credentials -- every remote here is a local path,
    #   so nothing legitimate needs them and a build must never be able
    #   to authenticate to a network host.
    #
    # GIT_EXEC_PATH is deliberately absent: git sets it for its own
    # subprocesses and clearing it can break the invocation itself.
    #
    # The location family is named on its own because a second defense
    # is built against it: unsetting these per git invocation covers the
    # commands this class makes, and nothing else, so CliTestCase deletes
    # the same names for the whole of every CLI test body. A test asserts
    # the two have not drifted.
    LOCATION_KEYS = %w[
      GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE
      GIT_CEILING_DIRECTORIES
    ].freeze

    CONFIG_KEYS = %w[GIT_TEMPLATE_DIR GIT_CONFIG GIT_CONFIG_COUNT].freeze

    TRANSPORT_KEYS = %w[
      GIT_SSH GIT_SSH_COMMAND GIT_ASKPASS GIT_PROXY_COMMAND
      GIT_ALLOW_PROTOCOL
    ].freeze

    NEUTRALIZED_KEYS = (LOCATION_KEYS + CONFIG_KEYS + TRANSPORT_KEYS).freeze

    # The oldest git these fixtures are correct on. 2.32 is where
    # GIT_CONFIG_GLOBAL and GIT_CONFIG_SYSTEM begin to be honored: below
    # it they are ignored outright, the developer's own ~/.gitconfig
    # applies to every fixture command, and nothing says so. Checked once
    # per build so that failure is a sentence rather than a puzzle.
    MINIMUM_GIT = [2, 32].freeze

    attr_reader :root, :work, :origin

    # The root must be a path under the system temporary directory. A
    # fixture builds a repository and then deletes branches in it, so
    # pointing one at a working clone is not a mistake that degrades
    # gracefully -- and the guard has to run before anything is created,
    # which is why it lives here rather than in #build.
    def initialize(root)
      @root = File.expand_path(root)
      unless self.class.under_tmpdir?(@root)
        raise Error, "refusing to build a fixture outside #{Dir.tmpdir}: #{@root}"
      end

      @origin = File.join(@root, 'origin.git')
      @work = File.join(@root, 'work')
    end

    # Both spellings of the temporary directory are accepted because
    # macOS reports two: Dir.tmpdir and Dir.mktmpdir hand back /var/...
    # while the same directory resolves to /private/var/..., and a check
    # against either one alone rejects every real fixture or accepts a
    # path that only looks like one.
    def self.under_tmpdir?(path)
      prefixes = [Dir.tmpdir, (File.realpath(Dir.tmpdir) if File.exist?(Dir.tmpdir))].compact
      resolved = resolve_existing(path)
      prefixes.uniq.any? { |prefix| resolved.start_with?(File.join(prefix, '')) }
    end

    # expand_path resolves `..` and `~` and stops there, so a symlink
    # under the temporary directory pointing at a working clone passes a
    # check made against the unresolved path -- and the fixture then
    # builds, and deletes, inside the clone. The root itself does not
    # exist yet, so the deepest ancestor that does is what can be
    # resolved, with the rest appended.
    def self.resolve_existing(path)
      existing = path
      tail = []
      until File.exist?(existing)
        parent = File.dirname(existing)
        break if parent == existing

        tail.unshift(File.basename(existing))
        existing = parent
      end

      File.join(File.realpath(existing), *tail)
    end

    # Full refnames, the form the sweep is specified to enumerate: a tag
    # sharing a branch's name makes the short form ambiguous, and both
    # fixtures build that collision deliberately.
    #
    # This is the handoff between the two halves of that trap, so it is
    # the place to say that neither form is safe everywhere. Enumeration
    # and for-each-ref need the full refname. `git branch -d` refuses it
    # outright ("error: branch 'refs/heads/amb' not found") and accepts
    # only the short name -- which is the ambiguous one. A sweep has to
    # convert between them knowingly rather than pick one and hope.
    def local_refs
      git('for-each-ref', '--format=%(refname)', 'refs/heads/').lines(chomp: true)
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

    # Failures report stdout as well as stderr: `git merge` and
    # `git commit` announce theirs on stdout, and those are the two
    # commands a fixture is most likely to break as it grows, so a
    # stderr-only message leaves the most common failure with nothing
    # after the colon.
    def git(*args, dir: work)
      stdout, stderr, status = Open3.capture3(env, 'git', '-C', dir, *args)
      unless status.success?
        raise Error, "git #{args.join(' ')} failed in #{dir} (exit #{status.exitstatus})\n" \
                     "stdout: #{stdout.strip}\nstderr: #{stderr.strip}"
      end

      stdout
    end

    # Runs a git command for its exit status alone. Several of the facts
    # a fixture is built to hold are ones git answers by succeeding or
    # failing rather than by printing: whether a commit is an ancestor of
    # another, whether HEAD is on a branch at all.
    def git_succeeds?(*args, dir: work)
      _stdout, _stderr, status = Open3.capture3(env, 'git', '-C', dir, *args)
      status.success?
    end

    # The neutralization as a bare hash, built without an instance.
    #
    # Anything that shells out to git while these tests run needs this,
    # not just the fixtures -- including a test that builds a repository
    # of its own to check the fixtures against. An unneutralized helper
    # of that kind is worse than an unprotected fixture, because it
    # writes into whatever an ambient GIT_DIR names AND reads that same
    # redirected repository back for its comparison, so the check passes
    # while the damage happens. `git -C <dir> init` under an ambient
    # GIT_DIR re-initializes the named repository and warns rather than
    # failing, and the commit that follows lands there.
    def self.neutralized_env(empty_config)
      NEUTRALIZED_KEYS.to_h { |key| [key, nil] }.merge(
        'GIT_CONFIG_GLOBAL' => empty_config,
        'GIT_CONFIG_SYSTEM' => empty_config,
        # Redundant with GIT_CONFIG_SYSTEM above, and kept: NOSYSTEM has
        # been honored for far longer, while GIT_CONFIG_SYSTEM arrived in
        # git 2.32. Either alone covers the supported versions; together
        # they cover a machine below the floor before the version check
        # gets a chance to say so.
        'GIT_CONFIG_NOSYSTEM' => '1',
        'GIT_TERMINAL_PROMPT' => '0',
        'GIT_AUTHOR_NAME' => 'Fixture',
        'GIT_COMMITTER_NAME' => 'Fixture',
        'GIT_AUTHOR_EMAIL' => IDENTITY_EMAIL,
        'GIT_COMMITTER_EMAIL' => IDENTITY_EMAIL
      ).freeze
    end

    # The environment every fixture git command runs under. Exposed so a
    # test driving the CLI against a fixture can run it under the same
    # neutralized configuration.
    def env
      @env ||= self.class.neutralized_env(empty_config)
    end

    private

    def empty_config
      @empty_config ||= File.join(root, 'gitconfig-empty')
    end

    def prepare_root
      require_supported_git
      FileUtils.mkdir_p(root)
      File.write(empty_config, '')
    end

    def require_supported_git
      stdout, stderr, status = Open3.capture3('git', '--version')
      raise Error, "git --version failed: #{stderr.strip}" unless status.success?

      found = stdout[/\d+\.\d+/].to_s.split('.').map(&:to_i)
      return if (found <=> MINIMUM_GIT) >= 0

      raise Error, "these fixtures need git #{MINIMUM_GIT.join('.')} or newer, found #{stdout.strip}"
    end

    # The clone's initial branch is set explicitly rather than left to
    # git. Adopting an empty remote's unborn HEAD name needs git 2.32;
    # older git falls back to init.defaultBranch, which under the empty
    # config above is `master`, and the first push then fails against a
    # bare repo whose HEAD names a branch nothing creates.
    def init_remote_and_clone(default_branch)
      git('init', '-q', '-b', default_branch, '--bare', 'origin.git', dir: root)
      git('clone', '-q', 'origin.git', 'work', dir: root)
      git('symbolic-ref', 'HEAD', "refs/heads/#{default_branch}")
      git('config', 'advice.detachedHead', 'false')
      git('config', 'remote.origin.followRemoteHEAD', 'never')
      verify_origin_url
    end

    # Every later push names the remote `origin` rather than a path, so
    # that remote-tracking refs update and the fixtures keep the shape
    # the oracle tables describe. That makes the name's resolution
    # load-bearing: this asserts once, before any push, that it still
    # points at the throwaway bare repo beside it.
    def verify_origin_url
      url = git('remote', 'get-url', 'origin').strip
      return if File.identical?(url, origin)

      raise Error, "fixture origin resolves to #{url}, expected #{origin}"
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
