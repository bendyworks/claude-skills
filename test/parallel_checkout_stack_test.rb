#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for the parallel-checkouts skill's containerized stack templates:
# bin/compose-project (the sourced resolver that refuses a shell whose
# identity disagrees with its checkout's), bin/dexec (runs a command in
# the checkout's app container), and the bin/docker-up, bin/docker-down,
# and bin/docker-rebuild lifecycle wrappers. Each test copies the
# templates into a throwaway project, replaces the PRJ placeholder prefix
# the way the skill does, and runs them against a fake `docker` on PATH
# that records its arguments, its stdin, whether stdin was a terminal,
# and the project name it inherited.
#
# The templates promise macOS's bash 3.2. Where /bin/bash is 3.x, the
# tests run them under it, through a `bash` placed first on PATH; CI's
# Linux bash is 5.x, so a lint test also rejects bash-4-only syntax
# everywhere. Coverage records nothing here: the project measures only
# bin/*. Run: ruby test/parallel_checkout_stack_test.rb

require_relative 'cli_test_case'
require 'open3'
require 'pty'

class ParallelCheckoutStackTest < Minitest::Test
  TEMPLATES = File.expand_path('../skills/parallel-checkouts/templates', __dir__)
  SCRIPT_TEMPLATES = %w[compose-project dexec docker-up docker-down docker-rebuild].freeze
  PREFIX = 'ZZSTACK_'
  SYSTEM_BASH = '/bin/bash'
  BASH3 = File.executable?(SYSTEM_BASH) && `#{SYSTEM_BASH} -c 'echo $BASH_VERSINFO'`.strip == '3'
  FAKE_DOCKER = <<~SH
    #!/bin/sh
    printf '%s\\n' "$@" > "$FAKE_DOCKER_ARGS"
    printf '%s' "${COMPOSE_PROJECT_NAME-(unset)}" > "$FAKE_DOCKER_PROJECT"
    if [ -t 0 ]; then echo yes > "$FAKE_DOCKER_TTY"; else echo no > "$FAKE_DOCKER_TTY"; cat > "$FAKE_DOCKER_STDIN"; fi
    exit "${FAKE_DOCKER_EXIT:-0}"
  SH
  IDENTITY = <<~ENV
    COMPOSE_PROJECT_NAME=stack2
    #{PREFIX}CHECKOUT_SUFFIX=2
    #{PREFIX}APP_PORT=3200
    #{PREFIX}DB_PORT=5632
    #{PREFIX}API_KEY=file-secret
    OTHER_SETTING=kept-out-of-the-comparison
  ENV

  def setup
    @scratch = File.realpath(Dir.mktmpdir('stack'))
    @root = File.join(@scratch, 'app2')
    @fakebin = File.join(@scratch, 'fakebin')
    FileUtils.mkdir_p([File.join(@root, 'bin'), File.join(@root, '.devcontainer'), @fakebin])
    SCRIPT_TEMPLATES.each { |name| install_template(name) }
    write_probe('compose "$@"')
    File.write(compose_file, "services:\n  app:\n    image: busybox\n")
    write_identity(IDENTITY)
    File.write(File.join(@fakebin, 'docker'), FAKE_DOCKER)
    File.chmod(0o755, File.join(@fakebin, 'docker'))
    File.symlink(SYSTEM_BASH, File.join(@fakebin, 'bash')) if BASH3
  end

  def teardown
    FileUtils.rm_rf(@scratch)
  end

  def install_template(name)
    path = File.join(@root, 'bin', name)
    File.write(path, File.read(File.join(TEMPLATES, name)).gsub('PRJ_', PREFIX))
    File.chmod(0o755, path)
  end

  # bin/probe sources the resolver the way a stack script does, then runs
  # the given shell lines. `prelude` runs before the source.
  def write_probe(body, prelude: '')
    path = File.join(@root, 'bin', 'probe')
    File.write(path, <<~SH)
      #!/usr/bin/env bash
      #{prelude}
      . "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/compose-project" || exit 1
      #{body}
    SH
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
  def exec_args = docker_args.drop(3)

  # A clean environment: only what a shell needs, the fake docker (and, on
  # macOS, bash 3.2) first on PATH, and whatever identity the test hands in.
  def base_env(extra)
    keep = %w[HOME PATH LANG TMPDIR].to_h { |key| [key, ENV.fetch(key, nil)] }
    keep['PATH'] = "#{@fakebin}:#{keep['PATH']}"
    keep.merge(
      'FAKE_DOCKER_ARGS' => record('args'), 'FAKE_DOCKER_STDIN' => record('stdin'),
      'FAKE_DOCKER_TTY' => record('tty'), 'FAKE_DOCKER_PROJECT' => record('project')
    ).merge(extra)
  end

  def run_script(script, *args, env: {}, stdin: '', chdir: @scratch, command: File.join(@root, 'bin', script))
    Open3.capture3(base_env(env), command, *args, stdin_data: stdin, chdir: chdir, unsetenv_others: true)
  end

  def assert_refused(result, *expected_text)
    _out, err, status = result
    refute status.success?, 'expected a refusal'
    expected_text.each { |text| assert_includes err, text }
    assert_nil docker_args, 'docker must not run after a refusal'
    err
  end

  def assert_ran(result)
    _out, err, status = result
    assert status.success?, err
  end

  # --- both templates -------------------------------------------------------

  def test_the_templates_use_no_syntax_newer_than_bash_3_2
    bash4 = /declare -A|\bmapfile\b|\breadarray\b|\$\{[^}]*(,,|\^\^|@[QEPAKa])\}|\[-\d+\]|\|&|;;&|;&|\bcoproc\b/
    SCRIPT_TEMPLATES.each do |name|
      File.readlines(File.join(TEMPLATES, name)).each_with_index do |line, index|
        next if line.lstrip.start_with?('#')

        refute_match bash4, line, "#{name}:#{index + 1} uses bash 4+ syntax"
      end
    end
  end

  def test_runs_under_the_bash_the_templates_promise
    skip 'no bash 3.x at /bin/bash on this machine' unless BASH3
    write_probe('printf %s "$BASH_VERSION"')
    out, err, status = run_script('probe')
    assert status.success?, err
    assert_match(/\A3\./, out)
  end

  # --- bin/compose-project ------------------------------------------------

  def test_runs_compose_with_this_checkouts_compose_file_and_exports_its_project
    assert_ran(run_script('probe', 'ps'))
    assert_equal ['compose', '-f', compose_file, 'ps'], docker_args
    assert_equal 'stack2', recorded('project')
  end

  def test_runs_the_same_way_from_any_directory
    elsewhere = File.join(@scratch, 'elsewhere')
    FileUtils.mkdir_p(elsewhere)
    assert_ran(run_script('probe', 'ps', chdir: elsewhere))
    assert_equal ['compose', '-f', compose_file, 'ps'], docker_args
  end

  def test_resolves_its_own_checkout_under_an_exported_cdpath
    decoy = File.join(@scratch, 'decoy')
    FileUtils.mkdir_p(File.join(decoy, 'bin'))
    assert_ran(run_script('dexec', 'ls', env: { 'CDPATH' => ".:#{decoy}" }, chdir: @root, command: 'bin/dexec'))
    assert_equal ['compose', '-f', compose_file], docker_args.first(3)
  end

  def test_accepts_a_shell_that_agrees_with_the_checkout
    env = { 'COMPOSE_PROJECT_NAME' => 'stack2', "#{PREFIX}APP_PORT" => '3200', "#{PREFIX}CHECKOUT_SUFFIX" => '2' }
    assert_ran(run_script('probe', 'ps', env: env))
  end

  def test_refuses_a_shell_carrying_another_project_name
    assert_refused(run_script('probe', 'ps', env: { 'COMPOSE_PROJECT_NAME' => 'stack' }),
                   'COMPOSE_PROJECT_NAME=stack', '(stack2)')
  end

  def test_refuses_a_shell_carrying_another_port_block
    assert_refused(run_script('probe', 'ps', env: { "#{PREFIX}DB_PORT" => '5432' }),
                   "#{PREFIX}DB_PORT=5432", '(5632)')
  end

  def test_refuses_a_variable_that_is_set_but_empty
    assert_refused(run_script('probe', 'ps', env: { "#{PREFIX}APP_PORT" => '' }),
                   "#{PREFIX}APP_PORT", 'set, but empty')
  end

  def test_refuses_an_identity_variable_the_shell_carries_and_the_file_lacks
    assert_refused(run_script('probe', 'ps', env: { "#{PREFIX}REDIS_PORT" => '6579' }),
                   "#{PREFIX}REDIS_PORT=6579", 'does not set it')
  end

  def test_leaves_the_projects_other_prefixed_variables_alone_and_unprinted
    _out, err, status = run_script('probe', 'ps', env: { "#{PREFIX}API_KEY" => 'shell-secret' })
    assert status.success?, err
    refute_includes err, 'secret'
  end

  def test_ignores_an_unexported_shell_variable_that_compose_never_sees
    write_probe('compose "$@"', prelude: "#{PREFIX}APP_PORT=1")
    assert_ran(run_script('probe', 'ps'))
  end

  def test_ignores_variables_outside_the_identity
    assert_ran(run_script('probe', 'ps', env: { 'OTHER_SETTING' => 'different' }))
  end

  def test_works_for_a_caller_with_a_strict_mode_ifs
    write_probe('compose "$@"', prelude: "IFS=$'\\n\\t'")
    assert_ran(run_script('probe', 'ps', env: { 'COMPOSE_PROJECT_NAME' => 'stack2' }))
  end

  def test_ignores_an_exported_variable_that_only_starts_like_compose_env_files
    assert_ran(run_script('probe', 'ps', env: { 'COMPOSE_ENV_FILES_NOTE' => 'x' }))
  end

  def test_refuses_when_compose_is_pointed_at_another_env_file
    assert_refused(run_script('probe', 'ps', env: { 'COMPOSE_ENV_FILES' => '/elsewhere/.env' }),
                   'COMPOSE_ENV_FILES')
  end

  def mark_as_parallel_checkout(suffix = '2')
    _out, err, status = Open3.capture3('git', 'init', '-q', @root)
    raise err unless status.success?

    File.write(File.join(@root, '.git', 'parallel-checkout'), "#{suffix}\n")
  end

  def test_uses_the_compose_files_own_name_when_no_checkout_has_an_identity
    write_identity("SECRET_TOKEN=keep-me\n")
    assert_ran(run_script('probe', 'ps'))
    assert_equal ['compose', '-f', compose_file, 'ps'], docker_args
    assert_equal '(unset)', recorded('project')
  end

  def test_uses_the_compose_files_own_name_when_there_is_no_env_file
    File.delete(env_file)
    assert_ran(run_script('probe', 'ps'))
    assert_equal '(unset)', recorded('project')
  end

  def test_refuses_a_parallel_checkout_whose_identity_is_missing
    mark_as_parallel_checkout
    File.delete(env_file)
    assert_refused(run_script('probe', 'ps'), 'parallel checkout 2', 'no identity')
  end

  def test_refuses_a_shell_identity_when_the_file_has_none
    write_identity("SECRET_TOKEN=keep-me\n")
    assert_refused(run_script('probe', 'ps', env: { "#{PREFIX}APP_PORT" => '3200' }), "#{PREFIX}APP_PORT=3200",
                   'does not set it')
  end

  def test_leaves_a_project_variable_that_only_looks_like_the_identity_alone
    write_identity("#{IDENTITY}#{PREFIX}CHECKOUT_SECRET=file-secret\n")
    _out, err, status = run_script('probe', 'ps', env: { "#{PREFIX}CHECKOUT_SECRET" => 'shell-secret' })
    assert status.success?, err
    refute_includes err, 'secret'
  end

  def test_refuses_an_identity_file_that_names_no_project
    write_identity("#{PREFIX}APP_PORT=3200\n")
    assert_refused(run_script('probe', 'ps'), 'names no COMPOSE_PROJECT_NAME')
  end

  def test_reads_the_value_shapes_compose_accepts
    write_identity(<<~ENV)
      export COMPOSE_PROJECT_NAME = "stack2" # quoted, with a comment\r
      export\t#{PREFIX}APP_PORT='3200'
      #{PREFIX}DB_PORT=5632 # trailing comment
      #{PREFIX}CHECKOUT_SUFFIX=x#y
    ENV
    env = { 'COMPOSE_PROJECT_NAME' => 'stack2', "#{PREFIX}APP_PORT" => '3200', "#{PREFIX}DB_PORT" => '5632',
            "#{PREFIX}CHECKOUT_SUFFIX" => 'x#y' }
    assert_ran(run_script('probe', 'ps', env: env))
  end

  def test_keeps_a_tab_before_a_hash_as_part_of_the_value_the_way_compose_does
    write_identity("COMPOSE_PROJECT_NAME=stack2\n#{PREFIX}APP_PORT=3200\t# not a comment to compose\n")
    assert_refused(run_script('probe', 'ps', env: { "#{PREFIX}APP_PORT" => '3200' }), "#{PREFIX}APP_PORT")
  end

  def test_compares_an_export_line_separated_by_a_tab
    write_identity("COMPOSE_PROJECT_NAME=stack2\nexport\t#{PREFIX}APP_PORT=3200\n")
    assert_refused(run_script('probe', 'ps', env: { "#{PREFIX}APP_PORT" => '1' }), "#{PREFIX}APP_PORT=1", '(3200)')
  end

  def test_refuses_an_identity_line_in_the_colon_form_with_an_equals_sign_after_it
    write_identity("COMPOSE_PROJECT_NAME=stack2\nCOMPOSE_PROJECT_NAME: stack3 # note a=b\n")
    assert_refused(run_script('probe', 'ps'), 'COMPOSE_PROJECT_NAME', 'KEY=value')
  end

  def test_refuses_a_bare_identity_key_that_defers_to_the_environment
    write_identity("COMPOSE_PROJECT_NAME=stack2\n#{PREFIX}APP_PORT\n")
    assert_refused(run_script('probe', 'ps'), "#{PREFIX}APP_PORT", 'with no value')
  end

  def test_reads_an_unquoted_value_with_a_windows_line_ending
    write_identity("COMPOSE_PROJECT_NAME=stack2\r\n#{PREFIX}APP_PORT=3200\r\n")
    assert_ran(run_script('probe', 'ps', env: { 'COMPOSE_PROJECT_NAME' => 'stack2', "#{PREFIX}APP_PORT" => '3200' }))
  end

  def test_refuses_an_identity_line_in_the_colon_form
    write_identity("COMPOSE_PROJECT_NAME=stack2\n#{PREFIX}APP_PORT: 3200\n")
    assert_refused(run_script('probe', 'ps'), "#{PREFIX}APP_PORT", 'KEY=value')
  end

  def test_reads_a_last_line_with_no_trailing_newline
    write_identity("COMPOSE_PROJECT_NAME=stack2\n#{PREFIX}DB_PORT=5632")
    assert_refused(run_script('probe', 'ps', env: { "#{PREFIX}DB_PORT" => '1' }), "#{PREFIX}DB_PORT=1", '(5632)')
  end

  def test_compares_the_last_assignment_of_a_repeated_variable
    write_identity("COMPOSE_PROJECT_NAME=old\nCOMPOSE_PROJECT_NAME=stack2\n")
    assert_ran(run_script('probe', 'ps', env: { 'COMPOSE_PROJECT_NAME' => 'stack2' }))
  end

  def test_refuses_an_identity_line_whose_name_is_not_a_variable_name
    pwned = File.join(@scratch, 'pwned')
    write_identity("COMPOSE_PROJECT_NAME=stack2\n#{PREFIX}$(touch #{pwned})_PORT=1\n")
    assert_refused(run_script('probe', 'ps'), 'not a shell variable name')
    refute_path_exists pwned
  end

  def test_refuses_an_identity_name_with_a_non_ascii_letter
    write_identity("COMPOSE_PROJECT_NAME=stack2\n#{PREFIX}é_PORT=1\n")
    assert_refused(run_script('probe', 'ps', env: { 'LANG' => 'en_US.UTF-8', 'LC_ALL' => 'en_US.UTF-8' }),
                   'not a shell variable name')
  end

  def test_leaves_only_the_compose_wrapper_and_its_paths_behind_in_the_sourcing_shell
    write_probe('compgen -v compose_project_; declare -F | grep compose_project_ || true; printf %s "$compose_project_env_file"')
    out, err, status = run_script('probe')
    assert status.success?, err
    assert_equal "compose_project_env_file\ncompose_project_files\n#{env_file}", out
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

  def test_refuses_to_be_sourced_by_a_shell_other_than_bash
    zsh = ENV.fetch('PATH', '').split(':').map { |dir| File.join(dir, 'zsh') }.find { |path| File.executable?(path) }
    skip 'zsh is not installed' unless zsh
    _out, err, status = Open3.capture3(base_env({}), zsh, '-c', ". #{File.join(@root, 'bin', 'compose-project')}",
                                       unsetenv_others: true)
    refute status.success?
    assert_includes err, 'needs bash'
  end

  # --- bin/dexec -----------------------------------------------------------

  def test_dexec_runs_the_command_in_the_app_service
    assert_ran(run_script('dexec', 'bundle', 'exec', 'rspec'))
    assert_equal ['compose', '-f', compose_file, 'exec', '-T', 'app', 'bundle', 'exec', 'rspec'], docker_args
  end

  def test_dexec_targets_another_service_by_name
    assert_ran(run_script('dexec', 'psql', env: { 'DEXEC_SERVICE' => 'db' }))
    assert_equal %w[db psql], exec_args.last(2)
  end

  def test_dexec_pairs_each_valued_flag_with_its_value
    [%w[-e A=1], %w[--env A=1], %w[-w /tmp], %w[--workdir /tmp], %w[-u root], %w[--user root],
     %w[--index 2]].each do |flag, value|
      File.delete(record('args')) if File.exist?(record('args'))
      assert_ran(run_script('dexec', flag, value, 'env'))
      assert_equal ['exec', flag, value, '-T', 'app', 'env'], exec_args, flag
    end
  end

  def test_dexec_passes_a_flag_without_a_value_ahead_of_the_service
    assert_ran(run_script('dexec', '--privileged', 'env'))
    assert_equal %w[exec --privileged -T app env], exec_args
  end

  def test_dexec_accepts_and_ignores_the_terminal_flags
    assert_ran(run_script('dexec', '-it', '-i', '-t', '-Ti', '--no-tty', '--interactive', '--tty', 'bash'))
    assert_equal %w[exec -T app bash], exec_args
  end

  def test_dexec_passes_a_dash_named_command_after_a_double_dash
    assert_ran(run_script('dexec', '--', '-weird'))
    assert_equal %w[exec -T app -weird], exec_args
  end

  def test_dexec_turns_off_the_terminal_and_forwards_piped_stdin
    assert_ran(run_script('dexec', 'psql', stdin: "select 1;\n"))
    assert_includes exec_args, '-T'
    assert_equal "select 1;\n", recorded('stdin')
  end

  def test_dexec_leaves_an_attached_terminal_attached
    PTY.spawn(base_env({}), File.join(@root, 'bin', 'dexec'), 'bash', unsetenv_others: true) do |reader, _writer, pid|
      begin
        reader.read
      rescue Errno::EIO
        nil # Linux closes a finished pty with EIO rather than EOF
      end
      Process.wait(pid)
    end
    assert_equal "yes\n", recorded('tty')
    assert_equal %w[exec app bash], exec_args
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
    result = run_script('dexec', 'rspec', env: { 'COMPOSE_PROJECT_NAME' => 'stack' })
    err = assert_refused(result, 'COMPOSE_PROJECT_NAME=stack')
    assert_equal 1, result.last.exitstatus
    refute_includes err, 'command not found'
  end

  # --- lifecycle wrappers ---------------------------------------------------

  def test_docker_up_starts_this_checkouts_stack_detached_from_any_directory
    assert_ran(run_script('docker-up', 'app'))
    assert_equal ['compose', '-f', compose_file, 'up', '-d', 'app'], docker_args
    assert_equal 'stack2', recorded('project')
  end

  def test_docker_down_stops_this_checkouts_stack
    assert_ran(run_script('docker-down', '--volumes'))
    assert_equal ['compose', '-f', compose_file, 'down', '--volumes'], docker_args
  end

  def write_initializer(body, executable: true)
    initializer = File.join(@root, '.devcontainer', 'initialize.sh')
    File.write(initializer, "#!/bin/sh\n#{body}\n")
    File.chmod(executable ? 0o755 : 0o644, initializer)
  end

  def test_docker_rebuild_runs_the_projects_initializer_first
    write_initializer("echo ran > #{record('initializer')}")
    assert_ran(run_script('docker-rebuild'))
    assert_equal "ran\n", recorded('initializer')
    assert_equal ['compose', '-f', compose_file, 'up', '--force-recreate', '--build', '-d'], docker_args
  end

  def test_docker_rebuild_runs_the_initializer_from_the_checkout_root
    write_initializer('echo ran > .devcontainer/initializer-ran')
    assert_ran(run_script('docker-rebuild', chdir: @scratch))
    assert_path_exists File.join(@root, '.devcontainer', 'initializer-ran')
  end

  def test_docker_rebuild_runs_an_initializer_that_is_not_executable
    write_initializer("echo ran > #{record('initializer')}", executable: false)
    assert_ran(run_script('docker-rebuild'))
    assert_equal "ran\n", recorded('initializer')
  end

  def test_docker_rebuild_rechecks_the_identity_the_initializer_wrote
    write_initializer("sed 's/^#{PREFIX}APP_PORT=.*/#{PREFIX}APP_PORT=9999/' .devcontainer/.env > .devcontainer/.env.new && " \
                      'mv .devcontainer/.env.new .devcontainer/.env')
    assert_refused(run_script('docker-rebuild', env: { "#{PREFIX}APP_PORT" => '3200' }), "#{PREFIX}APP_PORT=3200", '(9999)')
  end

  def test_docker_rebuild_needs_no_initializer
    assert_ran(run_script('docker-rebuild', 'app'))
    assert_equal ['compose', '-f', compose_file, 'up', '--force-recreate', '--build', '-d', 'app'], docker_args
  end

  def test_docker_rebuild_refuses_an_initializer_that_renames_the_project
    write_initializer("sed 's/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=stack9/' .devcontainer/.env > .devcontainer/.env.new && " \
                      'mv .devcontainer/.env.new .devcontainer/.env')
    assert_refused(run_script('docker-rebuild'), 'the initializer', 'changed COMPOSE_PROJECT_NAME from stack2 to stack9')
  end

  def test_docker_rebuild_announces_the_override_file_once
    File.write(File.join(@root, '.devcontainer', 'docker-compose.override.yml'), "services: {}\n")
    write_initializer("echo ran > #{record('initializer')}")
    _out, err, status = run_script('docker-rebuild')
    assert status.success?, err
    assert_equal 1, err.scan('docker-compose.override.yml').size, err
  end

  def test_docker_rebuild_stops_when_the_initializer_fails
    write_initializer('exit 5')
    _out, _err, status = run_script('docker-rebuild')
    refute status.success?
    assert_nil docker_args
  end

  def test_the_lifecycle_wrappers_pass_composes_exit_status_through
    %w[docker-up docker-down docker-rebuild].each do |script|
      _out, _err, status = run_script(script, env: { 'FAKE_DOCKER_EXIT' => '3' })
      assert_equal 3, status.exitstatus, script
    end
  end

  def test_the_lifecycle_wrappers_refuse_a_shell_that_disagrees_with_the_checkout
    %w[docker-up docker-down docker-rebuild].each do |script|
      result = run_script(script, env: { 'COMPOSE_PROJECT_NAME' => 'stack' })
      assert_refused(result, 'COMPOSE_PROJECT_NAME=stack')
      assert_equal 1, result.last.exitstatus, script
    end
  end
end
