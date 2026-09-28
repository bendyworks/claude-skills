#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for the parallel-checkouts skill's bin/check-parallel-dev template,
# which a containerized project runs to confirm its stack scripts act on
# its own checkout and refuse a shell claiming another one. Each test
# copies the stack templates into a throwaway project, replacing the PRJ
# placeholder prefix the way the skill does, and runs the checker against a
# scriptable fake `docker`: whether the daemon answers, what `compose
# config` prints, and whether the app container is running. Coverage
# records nothing here: the project measures only bin/*.
# Run: ruby test/parallel_checkout_checker_test.rb

require_relative 'cli_test_case'
require 'open3'

class ParallelCheckoutCheckerTest < Minitest::Test
  TEMPLATES = File.expand_path('../skills/parallel-checkouts/templates', __dir__)
  SCRIPTS = %w[compose-project dexec check-parallel-dev].freeze
  PREFIX = 'ZZCHECK_'
  SYSTEM_BASH = '/bin/bash'
  BASH3 = File.executable?(SYSTEM_BASH) && `#{SYSTEM_BASH} -c 'echo $BASH_VERSINFO'`.strip == '3'
  # Each call is logged; the answers come from FAKE_* variables.
  FAKE_DOCKER = <<~'SH'
    #!/bin/sh
    printf '%s\n' "$*" >> "$FAKE_DOCKER_LOG"
    case "$1" in
      info) exit "${FAKE_INFO_EXIT:-1}" ;;
    esac
    case "$*" in
      *" config -q"*) exit "${FAKE_CONFIG_EXIT:-0}" ;;
      *" config"*) [ "${FAKE_CONFIG_EXIT:-0}" = 0 ] && printf 'name: %s\nservices: {}\n' "${FAKE_CONFIG_NAME:-stack2}"; exit "${FAKE_CONFIG_EXIT:-0}" ;;
      *" ps "*) printf '%s' "${FAKE_PS_OUTPUT:-}"; exit 0 ;;
      *" exec "*) exit 0 ;;
    esac
    exit 0
  SH
  IDENTITY = <<~ENV
    COMPOSE_PROJECT_NAME=stack2
    #{PREFIX}CHECKOUT_SUFFIX=2
    #{PREFIX}APP_PORT=3200
  ENV

  def setup
    @scratch = File.realpath(Dir.mktmpdir('checker'))
    @root = File.join(@scratch, 'app2')
    @fakebin = File.join(@scratch, 'fakebin')
    FileUtils.mkdir_p([File.join(@root, 'bin'), File.join(@root, '.devcontainer'), @fakebin])
    SCRIPTS.each { |name| install(name, File.read(File.join(TEMPLATES, name))) }
    File.write(File.join(@root, '.devcontainer', 'docker-compose.yml'), "services:\n  app:\n    image: busybox\n")
    File.write(File.join(@root, '.devcontainer', '.env'), IDENTITY)
    File.write(File.join(@fakebin, 'docker'), FAKE_DOCKER)
    File.chmod(0o755, File.join(@fakebin, 'docker'))
    File.symlink(SYSTEM_BASH, File.join(@fakebin, 'bash')) if BASH3
  end

  def teardown
    FileUtils.rm_rf(@scratch)
  end

  def install(name, source)
    path = File.join(@root, 'bin', name)
    File.write(path, source.gsub('PRJ_', PREFIX))
    File.chmod(0o755, path)
  end

  def docker_log
    path = File.join(@scratch, 'docker.log')
    File.exist?(path) ? File.read(path) : ''
  end

  def check(env = {})
    keep = %w[HOME PATH LANG TMPDIR].to_h { |key| [key, ENV.fetch(key, nil)] }
    keep['PATH'] = "#{@fakebin}:#{keep['PATH']}"
    keep['FAKE_DOCKER_LOG'] = File.join(@scratch, 'docker.log')
    Open3.capture3(keep.merge(env), File.join(@root, 'bin', 'check-parallel-dev'),
                   chdir: @scratch, unsetenv_others: true)
  end

  def summary(out) = out[/(\d+) passed, (\d+) failed, (\d+) skipped/]&.then { $~.captures.map(&:to_i) }

  def test_passes_the_refusal_checks_and_skips_the_container_checks_without_a_daemon
    out, err, status = check
    assert status.success?, out + err
    passed, failed, skipped = summary(out)
    assert_operator passed, :>=, 3
    assert_equal 0, failed
    assert_operator skipped, :>=, 1
    assert_includes out, 'Docker is not running'
  end

  def test_passes_every_check_against_a_running_stack
    out, err, status = check('FAKE_INFO_EXIT' => '0', 'FAKE_PS_OUTPUT' => "abc123\n")
    assert status.success?, out + err
    _passed, failed, skipped = summary(out)
    assert_equal [0, 0], [failed, skipped]
    assert_includes docker_log, 'exec -T app true'
  end

  def test_skips_the_container_check_when_the_stack_is_stopped
    out, err, status = check('FAKE_INFO_EXIT' => '0', 'FAKE_PS_OUTPUT' => '')
    assert status.success?, out + err
    assert_includes out, 'not running'
    refute_includes docker_log, 'exec'
  end

  def test_fails_when_the_compose_project_does_not_load
    out, _err, status = check('FAKE_INFO_EXIT' => '0', 'FAKE_CONFIG_EXIT' => '1')
    refute status.success?
    assert_includes out, 'does not load'
  end

  def test_fails_when_compose_reads_another_project_name_from_the_file
    out, _err, status = check('FAKE_INFO_EXIT' => '0', 'FAKE_CONFIG_NAME' => 'other')
    refute status.success?
    assert_includes out, 'other'
  end

  def test_fails_every_refusal_check_when_the_resolver_compares_nothing
    install('compose-project', <<~'SH')
      #!/usr/bin/env bash
      export COMPOSE_PROJECT_NAME=stack2
      compose() { docker compose -f "$(dirname "${BASH_SOURCE[0]}")/../.devcontainer/docker-compose.yml" "$@"; }
    SH
    out, _err, status = check
    refute status.success?
    _passed, failed, _skipped = summary(out)
    assert_operator failed, :>=, 3
  end

  def test_refuses_to_run_from_a_shell_that_disagrees_with_the_checkout
    out, err, status = check('COMPOSE_PROJECT_NAME' => 'stack')
    assert_equal 1, status.exitstatus
    assert_includes out + err, 'COMPOSE_PROJECT_NAME=stack'
    assert_includes out + err, "this checkout's own shell"
  end

  def test_refusal_checks_never_reach_docker
    check
    refute_includes docker_log, 'exec'
  end
end
