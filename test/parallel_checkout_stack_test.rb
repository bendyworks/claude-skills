#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for the parallel-checkouts skill's containerized stack templates:
# bin/compose-project (the sourced resolver that refuses a shell whose
# identity disagrees with its checkout's) and bin/dexec (runs a command
# in the checkout's app container). Each test copies the templates into
# a throwaway project, replaces the PRJ placeholder prefix the way the
# skill does, and runs them against a fake `docker` on PATH that records
# its arguments, its stdin, and whether stdin was a terminal. Coverage
# records nothing here: the project measures only bin/*.
# Run: ruby test/parallel_checkout_stack_test.rb

require_relative 'cli_test_case'
require 'open3'
require 'pty'

class ParallelCheckoutStackTest < Minitest::Test
  TEMPLATES = File.expand_path('../skills/parallel-checkouts/templates', __dir__)
  PREFIX = 'ZZSTACK_'
  FAKE_DOCKER = <<~SH
    #!/bin/sh
    printf '%s\\n' "$@" > "$FAKE_DOCKER_ARGS"
    if [ -t 0 ]; then echo yes > "$FAKE_DOCKER_TTY"; else echo no > "$FAKE_DOCKER_TTY"; cat > "$FAKE_DOCKER_STDIN"; fi
    exit "${FAKE_DOCKER_EXIT:-0}"
  SH
  IDENTITY = <<~ENV
    COMPOSE_PROJECT_NAME=app2
    #{PREFIX}APP_PORT=3200
    #{PREFIX}DB_PORT=5632
    OTHER_SETTING=kept-out-of-the-comparison
  ENV

  def setup
    @scratch = File.realpath(Dir.mktmpdir('stack'))
    @root = File.join(@scratch, 'app2')
    FileUtils.mkdir_p([File.join(@root, 'bin'), File.join(@root, '.devcontainer'), File.join(@scratch, 'fakebin')])
    %w[compose-project dexec].each { |name| install_template(name) }
    File.write(File.join(@root, 'bin', 'probe'), <<~SH)
      #!/usr/bin/env bash
      . "$(cd "$(dirname "$0")" && pwd)/compose-project" || exit 1
      compose "$@"
    SH
    File.chmod(0o755, File.join(@root, 'bin', 'probe'))
    File.write(compose_file, "services:\n  app:\n    image: busybox\n")
    write_identity(IDENTITY)
    File.write(File.join(@scratch, 'fakebin', 'docker'), FAKE_DOCKER)
    File.chmod(0o755, File.join(@scratch, 'fakebin', 'docker'))
  end

  def teardown
    FileUtils.rm_rf(@scratch)
  end

  def install_template(name)
    path = File.join(@root, 'bin', name)
    File.write(path, File.read(File.join(TEMPLATES, name)).gsub('PRJ_', PREFIX))
    File.chmod(0o755, path)
  end

  def compose_file = File.join(@root, '.devcontainer', 'docker-compose.yml')
  def env_file = File.join(@root, '.devcontainer', '.env')
  def write_identity(text) = File.write(env_file, text)
  def record(name) = File.join(@scratch, "docker-#{name}")

  def recorded(name)
    path = record(name)
    File.exist?(path) ? File.read(path) : nil
  end

  def docker_args = recorded('args')&.split("\n")

  # A clean environment: only what a shell needs, the fake docker first on
  # PATH, and whatever identity the test hands in.
  def base_env(extra)
    keep = %w[HOME PATH LANG TMPDIR].to_h { |key| [key, ENV.fetch(key, nil)] }
    keep['PATH'] = "#{File.join(@scratch, 'fakebin')}:#{keep['PATH']}"
    keep.merge(
      'FAKE_DOCKER_ARGS' => record('args'), 'FAKE_DOCKER_STDIN' => record('stdin'),
      'FAKE_DOCKER_TTY' => record('tty')
    ).merge(extra)
  end

  def run_script(script, *args, env: {}, stdin: '', chdir: @scratch)
    Open3.capture3(base_env(env), File.join(@root, 'bin', script), *args,
                   stdin_data: stdin, chdir: chdir, unsetenv_others: true)
  end

  def assert_refused(result, *expected_text)
    _out, err, status = result
    refute status.success?, 'expected a refusal'
    expected_text.each { |text| assert_includes err, text }
    assert_nil docker_args, 'docker must not run after a refusal'
  end

  # --- bin/compose-project -----------------------------------------------

  def test_runs_compose_with_this_checkouts_compose_file
    _out, err, status = run_script('probe', 'ps')
    assert status.success?, err
    assert_equal ['compose', '-f', compose_file, 'ps'], docker_args
  end

  def test_runs_the_same_way_from_any_directory
    elsewhere = File.join(@scratch, 'elsewhere')
    FileUtils.mkdir_p(elsewhere)
    _out, err, status = run_script('probe', 'ps', chdir: elsewhere)
    assert status.success?, err
    assert_equal ['compose', '-f', compose_file, 'ps'], docker_args
  end

  def test_accepts_a_shell_that_agrees_with_the_checkout
    env = { 'COMPOSE_PROJECT_NAME' => 'app2', "#{PREFIX}APP_PORT" => '3200' }
    _out, err, status = run_script('probe', 'ps', env: env)
    assert status.success?, err
  end

  def test_refuses_a_shell_carrying_another_project_name
    assert_refused(run_script('probe', 'ps', env: { 'COMPOSE_PROJECT_NAME' => 'app' }),
                   'COMPOSE_PROJECT_NAME=app', 'app2')
  end

  def test_refuses_a_shell_carrying_another_port_block
    assert_refused(run_script('probe', 'ps', env: { "#{PREFIX}DB_PORT" => '5432' }),
                   "#{PREFIX}DB_PORT=5432", '5632')
  end

  def test_refuses_a_variable_that_is_set_but_empty
    assert_refused(run_script('probe', 'ps', env: { "#{PREFIX}APP_PORT" => '' }),
                   "#{PREFIX}APP_PORT", 'set, but empty')
  end

  def test_ignores_variables_outside_the_identity
    _out, err, status = run_script('probe', 'ps', env: { 'OTHER_SETTING' => 'different' })
    assert status.success?, err
  end

  def test_refuses_a_checkout_with_no_identity_file
    File.delete(env_file)
    assert_refused(run_script('probe', 'ps'), env_file, 'no identity')
  end

  def test_refuses_an_identity_file_that_names_no_project
    write_identity("#{PREFIX}APP_PORT=3200\n")
    assert_refused(run_script('probe', 'ps'), 'COMPOSE_PROJECT_NAME')
  end

  def test_reads_the_value_shapes_compose_accepts
    write_identity(<<~ENV)
      export COMPOSE_PROJECT_NAME = "app2" # quoted, with a comment\r
      #{PREFIX}APP_PORT='3200'
      #{PREFIX}DB_PORT=5632 # trailing comment
    ENV
    env = { 'COMPOSE_PROJECT_NAME' => 'app2', "#{PREFIX}APP_PORT" => '3200', "#{PREFIX}DB_PORT" => '5632' }
    _out, err, status = run_script('probe', 'ps', env: env)
    assert status.success?, err
  end

  def test_compares_the_last_assignment_of_a_repeated_variable
    write_identity("COMPOSE_PROJECT_NAME=old\nCOMPOSE_PROJECT_NAME=app2\n")
    _out, err, status = run_script('probe', 'ps', env: { 'COMPOSE_PROJECT_NAME' => 'app2' })
    assert status.success?, err
  end

  def test_refuses_an_identity_line_whose_name_is_not_a_variable_name
    pwned = File.join(@scratch, 'pwned')
    write_identity("COMPOSE_PROJECT_NAME=app2\n#{PREFIX}$(touch #{pwned})=1\n")
    assert_refused(run_script('probe', 'ps'), 'not a shell variable name')
    refute_path_exists pwned
  end

  def test_exports_the_verified_project_name
    File.write(File.join(@root, 'bin', 'probe'), <<~SH)
      #!/usr/bin/env bash
      . "$(cd "$(dirname "$0")" && pwd)/compose-project" || exit 1
      printf '%s' "$COMPOSE_PROJECT_NAME"
    SH
    out, err, status = run_script('probe')
    assert status.success?, err
    assert_equal 'app2', out
  end

  def test_includes_an_override_file_and_says_so
    override = File.join(@root, '.devcontainer', 'docker-compose.override.yml')
    File.write(override, "services: {}\n")
    _out, err, status = run_script('probe', 'ps')
    assert status.success?, err
    assert_equal ['compose', '-f', compose_file, '-f', override, 'ps'], docker_args
    assert_includes err, 'docker-compose.override.yml'
  end

  def test_refuses_to_be_executed_rather_than_sourced
    _out, err, status = run_script('compose-project')
    assert_equal 64, status.exitstatus
    assert_includes err, 'source this file'
  end

  # --- bin/dexec -----------------------------------------------------------

  def test_dexec_runs_the_command_in_the_app_service
    _out, err, status = run_script('dexec', 'bundle', 'exec', 'rspec')
    assert status.success?, err
    assert_equal ['compose', '-f', compose_file, 'exec', 'app', 'bundle', 'exec', 'rspec'], docker_args
  end

  def test_dexec_targets_another_service_by_name
    _out, err, status = run_script('dexec', 'psql', env: { 'DEXEC_SERVICE' => 'db' })
    assert status.success?, err
    assert_equal %w[exec db psql], docker_args.last(3)
  end

  def test_dexec_passes_flags_ahead_of_the_service
    _out, err, status = run_script('dexec', '-e', 'A=1', '-w', '/tmp', 'env')
    assert status.success?, err
    assert_equal %w[exec -e A=1 -w /tmp app env], docker_args.drop(3)
  end

  def test_dexec_accepts_and_ignores_the_terminal_flags
    _out, err, status = run_script('dexec', '-it', '-i', '-t', 'bash')
    assert status.success?, err
    assert_equal %w[exec app bash], docker_args.drop(3)
  end

  def test_dexec_passes_a_dash_named_command_after_a_double_dash
    _out, err, status = run_script('dexec', '--', '-weird')
    assert status.success?, err
    assert_equal %w[exec app -weird], docker_args.drop(3)
  end

  def test_dexec_forwards_piped_stdin
    _out, err, status = run_script('dexec', 'psql', stdin: "select 1;\n")
    assert status.success?, err
    assert_equal "select 1;\n", recorded('stdin')
    assert_equal "no\n", recorded('tty')
  end

  def test_dexec_leaves_an_attached_terminal_attached
    env = base_env({})
    PTY.spawn(env, File.join(@root, 'bin', 'dexec'), 'bash', unsetenv_others: true) do |reader, _writer, pid|
      begin
        reader.read
      rescue Errno::EIO
        nil # Linux closes a finished pty with EIO rather than EOF
      end
      Process.wait(pid)
    end
    assert_equal "yes\n", recorded('tty')
    assert_equal %w[exec app bash], docker_args.drop(3)
  end

  def test_dexec_passes_the_commands_exit_status_through
    _out, _err, status = run_script('dexec', 'false', env: { 'FAKE_DOCKER_EXIT' => '3' })
    assert_equal 3, status.exitstatus
  end

  def test_dexec_refuses_a_flag_missing_its_value
    _out, err, status = run_script('dexec', '-e')
    assert_equal 64, status.exitstatus
    assert_includes err, 'requires a value'
    assert_nil docker_args
  end

  def test_dexec_refuses_no_command
    _out, err, status = run_script('dexec')
    assert_equal 64, status.exitstatus
    assert_includes err, 'Usage'
    assert_nil docker_args
  end

  def test_dexec_stops_when_the_shell_disagrees_with_the_checkout
    assert_refused(run_script('dexec', 'rspec', env: { 'COMPOSE_PROJECT_NAME' => 'app' }),
                   'COMPOSE_PROJECT_NAME=app')
  end
end
