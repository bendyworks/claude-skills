#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for the parallel-checkouts skill's boot guard template, which a
# prepared project copies to config/initializers/. The template is
# evaluated in a fresh binding against a stand-in Rails module, after
# replacing the PRJ placeholder prefix the way the skill does. Each
# checkout in these tests is a real git repository, because the guard
# finds a checkout's marker file through its git directory. Coverage
# records nothing here: the project measures only bin/*.
# Run: ruby test/parallel_checkout_guard_test.rb

require_relative 'cli_test_case'
require 'open3'
require 'pathname'

class ParallelCheckoutGuardTest < Minitest::Test
  TEMPLATE = File.expand_path(
    '../skills/parallel-checkouts/templates/parallel_checkout_guard.rb', __dir__
  )
  PREFIX = 'ZZGUARDTEST_'
  ENV_KEYS = %w[CHECKOUT_ROOT CHECKOUT_SUFFIX].map { |key| "#{PREFIX}#{key}" }.freeze
  GIT_ENV = {
    'GIT_CONFIG_GLOBAL' => File::NULL, 'GIT_CONFIG_SYSTEM' => File::NULL,
    'GIT_AUTHOR_NAME' => 'Test', 'GIT_AUTHOR_EMAIL' => 'test@example.com',
    'GIT_COMMITTER_NAME' => 'Test', 'GIT_COMMITTER_EMAIL' => 'test@example.com'
  }.freeze

  StubEnv = Struct.new(:name) do
    def development? = name == 'development'
    def test? = name == 'test'
  end

  def setup
    @scratch = File.realpath(Dir.mktmpdir('guard'))
    @primary = git_checkout('primary')
    @other = git_checkout('other')
    @saved_env = ENV_KEYS.to_h { |key| [key, ENV.fetch(key, nil)] }
  end

  def teardown
    FileUtils.rm_rf(@scratch)
    @saved_env.each { |key, value| ENV[key] = value }
  end

  def git(*args)
    _out, err, status = Open3.capture3(GIT_ENV, 'git', *args)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?
  end

  def git_checkout(name)
    root = File.join(@scratch, name)
    git('init', '-q', root)
    git('-C', root, 'commit', '-q', '--allow-empty', '-m', 'init')
    root
  end

  def add_worktree(checkout, path)
    git('-C', checkout, 'worktree', 'add', '-q', '--detach', path)
    path
  end

  def mark_as_checkout(root, suffix)
    File.write(File.join(root, '.git', 'parallel-checkout'), "#{suffix}\n")
  end

  # Evaluates the guard as a Rails boot would, returning its value (nil
  # when it lets the boot through) or raising what it raises.
  def boot(env:, root:, claimed:, suffix: nil)
    ENV["#{PREFIX}CHECKOUT_ROOT"] = claimed
    ENV["#{PREFIX}CHECKOUT_SUFFIX"] = suffix
    stub = Module.new
    stub.define_singleton_method(:env) { StubEnv.new(env) }
    stub.define_singleton_method(:root) { Pathname.new(root) }
    with_rails(stub) do
      eval(File.read(TEMPLATE).gsub('PRJ_', PREFIX), Object.new.instance_eval { binding }, TEMPLATE)
    end
  end

  def with_rails(stub)
    original = Object.send(:remove_const, :Rails) if Object.const_defined?(:Rails, false)
    Object.const_set(:Rails, stub)
    yield
  ensure
    Object.send(:remove_const, :Rails)
    Object.const_set(:Rails, original) if original
  end

  def assert_refuses(expected_text, **)
    error = assert_raises(RuntimeError) { boot(**) }
    assert_includes error.message, expected_text
    error
  end

  def test_every_variable_the_template_reads_carries_the_placeholder_prefix
    names = File.read(TEMPLATE).scan(/ENV\.fetch\(["']([^"']+)["']/).flatten
    refute_empty names
    assert(names.all? { |name| name.start_with?('PRJ_') }, "unprefixed: #{names}")
  end

  def test_boots_when_no_identity_is_set
    assert_nil boot(env: 'test', root: @primary, claimed: nil)
  end

  def test_boots_when_the_identity_names_this_checkout
    assert_nil boot(env: 'development', root: @primary, claimed: @primary)
  end

  def test_refuses_in_development_when_the_identity_names_another_checkout
    error = assert_refuses('carries the parallel-checkout identity', env: 'development', root: @primary,
                                                                      claimed: @other)
    assert_includes error.message, @other
    assert_includes error.message, @primary
  end

  def test_refuses_in_test_when_the_identity_names_another_checkout
    assert_refuses('carries the parallel-checkout identity', env: 'test', root: @primary, claimed: @other)
  end

  def test_treats_a_symlinked_path_to_this_checkout_as_this_checkout
    link = File.join(@scratch, 'link-to-primary')
    File.symlink(@primary, link)
    assert_nil boot(env: 'test', root: @primary, claimed: link)
  end

  def test_treats_a_symlinked_rails_root_as_this_checkout
    link = File.join(@scratch, 'link-to-primary')
    File.symlink(@primary, link)
    assert_nil boot(env: 'test', root: link, claimed: @primary)
  end

  def test_refuses_when_the_claimed_directory_no_longer_exists
    missing = File.join(@scratch, 'gone')
    assert_refuses(missing, env: 'test', root: @primary, claimed: missing)
  end

  def test_refuses_a_relative_claimed_root
    Dir.chdir(@primary) do
      assert_refuses('not an absolute path', env: 'test', root: @primary, claimed: '.')
    end
  end

  def test_refuses_in_development_a_marked_checkout_whose_identity_is_not_loaded
    mark_as_checkout(@other, '2')
    error = assert_refuses('suffix 2', env: 'development', root: @other, claimed: nil)
    assert_includes error.message, @other
  end

  def test_refuses_a_marked_checkout_carrying_another_checkouts_suffix
    mark_as_checkout(@other, '2')
    assert_refuses('suffix 2', env: 'test', root: @other, claimed: @other, suffix: '3')
  end

  def test_boots_a_marked_checkout_whose_identity_is_loaded
    mark_as_checkout(@other, '2')
    assert_nil boot(env: 'test', root: @other, claimed: @other, suffix: '2')
  end

  def test_refuses_a_marked_checkout_whose_marker_is_empty
    mark_as_checkout(@other, '')
    assert_refuses('is empty', env: 'test', root: @other, claimed: nil)
  end

  def test_boots_a_worktree_nested_in_a_checkout_under_that_checkouts_identity
    mark_as_checkout(@other, '2')
    nested = add_worktree(@other, File.join(@other, '.claude', 'worktrees', 'task'))
    assert_nil boot(env: 'test', root: nested, claimed: @other, suffix: '2')
  end

  def test_refuses_a_worktree_of_a_marked_checkout_run_with_no_identity
    mark_as_checkout(@other, '2')
    outside = add_worktree(@other, File.join(@scratch, 'outside-worktree'))
    assert_refuses('suffix 2', env: 'test', root: outside, claimed: nil)
  end

  def test_refuses_a_worktree_run_under_another_checkouts_identity
    nested = add_worktree(@primary, File.join(@primary, '.claude', 'worktrees', 'task'))
    assert_refuses('carries the parallel-checkout identity', env: 'test', root: nested, claimed: @other)
  end

  def test_refuses_an_app_in_a_repository_subdirectory_whose_identity_is_not_loaded
    mark_as_checkout(@other, '2')
    app = File.join(@other, 'web')
    FileUtils.mkdir_p(app)
    assert_refuses('suffix 2', env: 'test', root: app, claimed: nil)
  end

  def test_boots_an_app_in_a_repository_subdirectory_under_its_repositorys_identity
    mark_as_checkout(@other, '2')
    app = File.join(@other, 'web')
    FileUtils.mkdir_p(app)
    assert_nil boot(env: 'test', root: app, claimed: @other, suffix: '2')
  end

  def test_reads_a_gitdir_line_with_a_windows_line_ending
    mark_as_checkout(@other, '2')
    outside = add_worktree(@other, File.join(@scratch, 'crlf-worktree'))
    dot_git = File.join(outside, '.git')
    File.write(dot_git, File.read(dot_git).sub(/\n\z/, "\r\n"))
    assert_refuses('suffix 2', env: 'test', root: outside, claimed: nil)
  end

  def test_explains_a_worktree_whose_git_directory_is_gone
    outside = add_worktree(@other, File.join(@scratch, 'pruned-worktree'))
    File.write(File.join(outside, '.git'), "gitdir: #{File.join(@scratch, 'missing')}\n")
    assert_refuses('cannot find', env: 'test', root: outside, claimed: nil)
  end

  def test_never_checks_in_production
    mark_as_checkout(@other, '2')
    assert_nil boot(env: 'production', root: @primary, claimed: @other)
  end
end
