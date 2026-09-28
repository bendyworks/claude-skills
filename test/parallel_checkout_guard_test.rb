#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for the parallel-checkouts skill's boot guard template, which a
# prepared project copies to config/initializers/. The template is
# evaluated against a stand-in Rails module after replacing the PRJ
# placeholder prefix, the same substitution the skill makes.
# Run: ruby test/parallel_checkout_guard_test.rb

require_relative 'cli_test_case'

class ParallelCheckoutGuardTest < Minitest::Test
  TEMPLATE = File.expand_path(
    '../skills/parallel-checkouts/templates/parallel_checkout_guard.rb', __dir__
  )

  StubEnv = Struct.new(:name) do
    def development? = name == 'development'
    def test? = name == 'test'
  end

  def setup
    @primary = File.realpath(Dir.mktmpdir('primary'))
    @other = File.realpath(Dir.mktmpdir('other'))
    @saved_root = ENV.fetch('APP_CHECKOUT_ROOT', nil)
    @saved_suffix = ENV.fetch('APP_CHECKOUT_SUFFIX', nil)
  end

  def teardown
    FileUtils.rm_rf([@primary, @other])
    ENV['APP_CHECKOUT_ROOT'] = @saved_root
    ENV['APP_CHECKOUT_SUFFIX'] = @saved_suffix
  end

  def boot(env:, root:, claimed:, suffix: nil)
    ENV['APP_CHECKOUT_ROOT'] = claimed
    ENV['APP_CHECKOUT_SUFFIX'] = suffix
    rails = Module.new
    rails.define_singleton_method(:env) { StubEnv.new(env) }
    rails.define_singleton_method(:root) { Pathname.new(root) }
    source = File.read(TEMPLATE).gsub('PRJ_', 'APP_')
    Object.const_set(:Rails, rails)
    eval(source, binding, TEMPLATE)
  ensure
    Object.send(:remove_const, :Rails) if Object.const_defined?(:Rails)
  end

  def test_boots_when_no_identity_is_set
    boot(env: 'test', root: @primary, claimed: nil)
  end

  def test_boots_when_the_identity_names_this_checkout
    boot(env: 'development', root: @primary, claimed: @primary)
  end

  def test_refuses_when_the_identity_names_another_checkout
    error = assert_raises(RuntimeError) { boot(env: 'test', root: @primary, claimed: @other) }
    assert_includes error.message, @other
    assert_includes error.message, @primary
  end

  def test_treats_a_symlinked_path_to_this_checkout_as_this_checkout
    link = File.join(@other, 'link')
    File.symlink(@primary, link)
    boot(env: 'test', root: @primary, claimed: link)
  end

  def test_refuses_when_the_claimed_directory_no_longer_exists
    missing = File.join(@other, 'gone')
    assert_raises(RuntimeError) { boot(env: 'test', root: @primary, claimed: missing) }
  end

  def mark_as_checkout(root, suffix)
    File.write(File.join(root, '.parallel-checkout'), "#{suffix}\n")
  end

  def test_refuses_a_marked_checkout_whose_identity_is_not_loaded
    mark_as_checkout(@other, '2')
    error = assert_raises(RuntimeError) { boot(env: 'test', root: @other, claimed: nil) }
    assert_includes error.message, @other
  end

  def test_refuses_a_marked_checkout_carrying_another_checkouts_suffix
    mark_as_checkout(@other, '2')
    assert_raises(RuntimeError) { boot(env: 'test', root: @other, claimed: @other, suffix: '3') }
  end

  def test_boots_a_marked_checkout_whose_identity_is_loaded
    mark_as_checkout(@other, '2')
    boot(env: 'test', root: @other, claimed: @other, suffix: '2')
  end

  def test_never_checks_in_production
    boot(env: 'production', root: @primary, claimed: @other)
  end
end
