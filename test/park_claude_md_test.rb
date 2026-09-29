#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for scripts/park-claude-md.sh, which parks the user-level
# CLAUDE.md for the length of a dry-run batch. Every test points the
# script at a throwaway config directory through CLAUDE_CONFIG_DIR, and
# points HOME at the same temporary directory, so a script that stopped
# honoring CLAUDE_CONFIG_DIR would fall back to a sandboxed ~/.claude
# rather than the real one. Coverage records nothing here: the project
# measures only bin/*.
# Run: ruby test/park_claude_md_test.rb

require_relative 'cli_test_case'
require 'digest'
require 'open3'
require 'pty'
require 'tmpdir'

class ParkClaudeMdTest < Minitest::Test
  SCRIPT = File.expand_path('../scripts/park-claude-md.sh', __dir__)
  ORIGINAL = "# user rules\nalways say hello\n"
  # A start time no running process has, so a holder recorded with it
  # reads as stranded even when its process ID is reused.
  STALE_START = 'Thu Jan  1 00:00:00 1970'

  def setup
    @tmp = File.realpath(Dir.mktmpdir('park-claude-md-test'))
    @config = File.join(@tmp, 'config')
    Dir.mkdir(@config)
    @live = File.join(@config, 'CLAUDE.md')
    @lock = File.join(@config, 'CLAUDE.md.park-lock')
    File.write(@live, ORIGINAL)
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def env
    { 'CLAUDE_CONFIG_DIR' => @config, 'HOME' => @tmp, 'CLAUDE_MD_PARK_HOLDER' => nil }
  end

  def park(*args)
    Open3.capture3(env, 'bash', SCRIPT, *args)
  end

  # The script's argv run in a new session with no controlling
  # terminal, the way a headless batch runs, wherever the suite itself
  # is run from.
  def perl_available?
    system('command -v perl >/dev/null 2>&1')
  end

  # An arm that outlives its batch: output away from the test's pipes,
  # and a TERM handler that records whether CLAUDE.md was already back,
  # then keeps running so only a KILL ends it.
  def stubborn_arm(arm_file, saw_file)
    "(trap \"test -e '#{@live}' && touch '#{saw_file}'\" TERM; " \
      "while :; do sleep 0.1; done) >/dev/null 2>&1 & echo $! > '#{arm_file}'"
  end

  def headless(*args)
    ['perl', '-MPOSIX', '-e', 'POSIX::setsid(); exec { $ARGV[0] } @ARGV', '--', 'bash', SCRIPT, *args]
  end

  # The form the script records: fixed to the C locale and UTC, so the
  # same process reads the same from any terminal.
  def start_time(pid)
    out, = Open3.capture2({ 'LC_ALL' => 'C', 'TZ' => 'UTC0' }, 'ps', '-o', 'lstart=', '-p', pid.to_s)
    out.strip
  end

  # Stands in for another session's park: a lock directory holding the
  # parked file and an owner record for the given process.
  def hold_lock(pid:, started: start_time(pid))
    Dir.mkdir(@lock)
    File.write(File.join(@lock, 'owner'), "checkout=/elsewhere/checkout2\npid=#{pid}\nstarted=#{started}\n")
    File.rename(@live, File.join(@lock, 'CLAUDE.md'))
  end

  def live_holder
    pid = Process.spawn('sleep', '30')
    yield pid
  ensure
    if pid
      Process.kill('KILL', pid)
      Process.wait(pid)
    end
  end

  def assert_refused_leaving_lock_alone(status, probe)
    assert_equal 2, status.exitstatus
    refute File.exist?(probe), 'command ran despite the refusal'
    assert_equal ORIGINAL, File.read(File.join(@lock, 'CLAUDE.md'))
    refute File.exist?(@live)
  end

  # Starts the script in its own process group around a command that
  # starts an arm of its own (the way a batch starts its claude -p runs)
  # and marks itself ready, sends the signal once the file is parked,
  # and returns the script's exit status, the arm's process ID, and the
  # command's own process ID.
  def interrupt_parked_run(signal, target, run_env = env)
    ready = File.join(@tmp, 'ready')
    arm = File.join(@tmp, 'arm')
    # The trailing sleep keeps the command running after its arm dies,
    # so the script's exit shows the command itself was stopped.
    command = "echo $$ > '#{arm}.command'; sleep 30 & echo $! > '#{arm}'; touch '#{ready}'; wait; sleep 30"
    pid = Process.spawn(run_env, 'bash', SCRIPT, '--', 'sh', '-c', command, pgroup: true, err: File::NULL)
    wait_for { File.exist?(ready) }
    refute File.exist?(@live), 'command started before the file was parked'
    Process.kill(signal, target == :group ? -pid : pid)
    status = nil
    wait_for { (status = Process.wait2(pid, Process::WNOHANG)&.last) }
    [status, Integer(File.read(arm)), Integer(File.read("#{arm}.command"))]
  rescue StandardError, Minitest::Assertion
    kill_group(pid)
    raise
  end

  # Cleanup for a failed signal test only: after a clean exit the arm
  # must have stopped on its own, and killing the group would hide it.
  def kill_group(pid)
    return unless pid

    Process.kill('KILL', -pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def running?(pid)
    Process.kill(0, pid)
    stat, = Open3.capture2('ps', '-o', 'stat=', '-p', pid.to_s)
    !stat.strip.start_with?('Z')
  rescue Errno::ESRCH
    false
  end

  def wait_for(seconds: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    until yield
      flunk "gave up after #{seconds}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
  end

  def assert_interrupted(signal, target, exit_status)
    status, arm = interrupt_parked_run(signal, target)

    assert_equal exit_status, status.exitstatus
    wait_for(seconds: 3) { !running?(arm) }
    assert_equal ORIGINAL, File.read(@live)
    refute File.exist?(@lock)
  ensure
    begin
      Process.kill('KILL', arm) if arm
    rescue Errno::ESRCH
      nil
    end
  end

  def dead_pid
    pid = Process.spawn('true')
    Process.wait(pid)
    pid
  end

  # An environment whose ps reports no start times, as some sandboxes do.
  def start_time_blind_env
    shims = File.join(@tmp, 'shims')
    FileUtils.mkdir_p(shims)
    File.write(File.join(shims, 'ps'), "#!/bin/sh\ncase \"$*\" in *lstart*) exit 1 ;; esac\nexec /bin/ps \"$@\"\n")
    File.chmod(0o755, File.join(shims, 'ps'))
    env.merge('PATH' => "#{shims}:#{ENV.fetch('PATH')}")
  end

  def test_runs_the_command_with_the_file_parked_and_restores_it
    probe = File.join(@tmp, 'probe')
    _out, err, status = park('--', 'sh', '-c', "touch '#{probe}'; test -e '#{@live}' && echo present >> '#{probe}'; true")

    assert status.success?, err
    refute_includes File.read(probe), 'present', 'CLAUDE.md was visible while parked'
    assert_equal ORIGINAL, File.read(@live)
    refute File.exist?(@lock), 'lock left behind after a clean run'
  end

  def test_warns_that_sessions_started_meanwhile_lack_the_file
    _out, err, status = park('--', 'true')

    assert status.success?, err
    assert_match(/sessions started before it is restored/, err)
  end

  def test_exits_with_the_command_status
    _out, _err, status = park('--', 'sh', '-c', 'exit 7')

    assert_equal 7, status.exitstatus
    assert_equal ORIGINAL, File.read(@live)
    refute File.exist?(@lock)
  end

  def test_passes_every_argument_through_unchanged
    args = ['two words', "it's", '$HOME', '--', '*', '']
    out, err, status = park('--', 'ruby', '-e', 'print ARGV.inspect', *args)

    assert status.success?, err
    assert_equal args.inspect, out
  end

  def test_refuses_while_another_live_session_holds_the_park
    probe = File.join(@tmp, 'probe')
    live_holder do |pid|
      hold_lock(pid: pid)
      _out, err, status = park('--', 'touch', probe)

      assert_refused_leaving_lock_alone(status, probe)
      assert_match(/parked by a running session/, err)
      refute_match(/--recover/, err)
      assert_match(%r{/elsewhere/checkout2}, err)
      assert_match(/\b#{pid}\b/, err)
    end
  end

  def test_refuses_a_stale_park_and_points_at_recover
    probe = File.join(@tmp, 'probe')
    hold_lock(pid: dead_pid, started: STALE_START)
    _out, err, status = park('--', 'touch', probe)

    assert_refused_leaving_lock_alone(status, probe)
    assert_match(/--recover/, err)
  end

  def test_refuses_a_lock_that_is_still_being_acquired
    probe = File.join(@tmp, 'probe')
    Dir.mkdir(@lock)
    _out, err, status = park('--', 'touch', probe)

    assert_equal 2, status.exitstatus
    refute File.exist?(probe)
    assert_equal ORIGINAL, File.read(@live)
    assert Dir.exist?(@lock), 'removed a lock it did not own'
    assert_match(/no owner/, err)
  end

  def test_refuses_when_the_file_is_missing_with_no_lock
    probe = File.join(@tmp, 'probe')
    File.delete(@live)
    _out, err, status = park('--', 'touch', probe)

    assert_equal 2, status.exitstatus
    refute File.exist?(probe)
    refute File.exist?(@lock)
    assert_match(/--none-ok/, err)
  end

  def test_none_ok_runs_the_command_when_there_is_no_file_to_park
    probe = File.join(@tmp, 'probe')
    File.delete(@live)
    _out, err, status = park('--none-ok', '--', 'touch', probe)

    assert status.success?, err
    assert File.exist?(probe)
    refute File.exist?(@live)
    refute File.exist?(@lock)
  end

  def test_parallel_arms_inside_a_batch_share_its_park
    arms = %w[a b].map { |name| File.join(@tmp, "arm-#{name}") }
    batch = arms.map { |probe| "bash '#{SCRIPT}' -- sh -c \"test ! -e '#{@live}' && touch '#{probe}'\" &" }.join(' ')
    _out, err, status = park('--', 'sh', '-c', "#{batch} wait")

    assert status.success?, err
    arms.each { |probe| assert File.exist?(probe), "#{File.basename(probe)} did not run parked" }
    assert_equal ORIGINAL, File.read(@live)
    refute File.exist?(@lock)
  end

  def test_a_holder_token_from_another_park_does_not_bypass_the_lock
    probe = File.join(@tmp, 'probe')
    live_holder do |pid|
      hold_lock(pid: pid)
      _out, _err, status = Open3.capture3(env.merge('CLAUDE_MD_PARK_HOLDER' => '1'), 'bash', SCRIPT, '--', 'touch', probe)

      assert_refused_leaving_lock_alone(status, probe)
    end
  end

  def test_ctrl_c_stops_the_command_and_its_arms_and_restores_the_file
    assert_interrupted('INT', :group, 130)
  end

  def test_term_stops_the_command_and_its_arms_and_restores_the_file
    assert_interrupted('TERM', :script, 143)
  end

  def test_a_closed_terminal_stops_the_command_and_restores_the_file
    assert_interrupted('HUP', :script, 129)
  end

  def test_passes_standard_input_to_the_command
    out, err, status = Open3.capture3(env, 'bash', SCRIPT, '--', 'cat', stdin_data: "prompt text\n")

    assert status.success?, err
    assert_equal "prompt text\n", out
  end

  def test_keeps_both_files_when_a_new_one_appeared_while_parked
    _out, err, status = park('--', 'sh', '-c', "echo 'saved by another session' > '#{@live}'")

    assert_equal 2, status.exitstatus
    assert_equal "saved by another session\n", File.read(@live)
    assert_equal ORIGINAL, File.read(File.join(@lock, 'CLAUDE.md'))
    assert_match(/appeared while parked/, err)
  end

  def test_the_conflict_advice_leads_to_a_clean_recovery
    _out, err, = park('--', 'sh', '-c', "echo 'saved by another session' > '#{@live}'")
    parked = File.join(@lock, 'CLAUDE.md')

    assert_includes err, "delete #{parked}"
    assert_includes err, '--recover'
    File.delete(parked)
    _out, recover_err, status = park('--recover')

    assert status.success?, recover_err
    assert_equal "saved by another session\n", File.read(@live)
    refute File.exist?(@lock)
  end

  def test_keeps_the_parked_copy_when_it_changed_while_parked
    parked = File.join(@lock, 'CLAUDE.md')
    _out, err, status = park('--', 'sh', '-c', "echo 'edited' >> '#{parked}'")

    assert_equal 2, status.exitstatus
    refute File.exist?(@live)
    assert_equal "#{ORIGINAL}edited\n", File.read(parked)
    assert_match(/checksum/, err)
  end

  def test_restores_a_symlink_whose_target_changed_while_parked
    target = File.join(@tmp, 'dotfiles-CLAUDE.md')
    File.write(target, ORIGINAL)
    File.delete(@live)
    File.symlink(target, @live)
    _out, err, status = park('--', 'sh', '-c', "echo 'pulled' >> '#{target}'")

    assert status.success?, err
    assert_equal target, File.readlink(@live)
    refute File.exist?(@lock)
  end

  def test_status_reports_nothing_parked
    out, _err, status = park('--status')

    assert status.success?
    assert_match(/not parked/, out)
  end

  # Where de_DE.UTF-8 is not installed (most CI images), only the time
  # zone half is exercised; the locale half runs where it is.
  def test_a_holder_reads_as_running_from_another_time_zone_and_locale
    live_holder do |pid|
      hold_lock(pid: pid)
      out, _err, status = Open3.capture3(env.merge('TZ' => 'Asia/Tokyo', 'LC_ALL' => 'de_DE.UTF-8'),
                                         'bash', SCRIPT, '--status')

      assert status.success?
      assert_match(/parked by a running session/, out)
    end
  end

  def test_a_holder_this_user_cannot_signal_still_reads_as_running
    begin
      Process.kill(0, 1)
      skip 'process 1 can be signalled here, so it cannot stand in for an unsignalable holder'
    rescue Errno::EPERM
      nil
    end
    hold_lock(pid: 1)
    out, _err, status = park('--status')

    assert status.success?
    assert_match(/parked by a running session/, out)
  end

  def test_status_names_a_running_holder
    live_holder do |pid|
      hold_lock(pid: pid)
      out, _err, status = park('--status')

      assert status.success?
      assert_match(/parked by a running session/, out)
      refute_match(/no longer running/, out)
      assert_match(%r{/elsewhere/checkout2}, out)
      assert_match(/\b#{pid}\b/, out)
    end
  end

  def test_status_flags_a_stranded_park
    hold_lock(pid: dead_pid, started: STALE_START)
    out, _err, status = park('--status')

    assert status.success?
    assert_match(/no longer running/, out)
    assert_match(/--recover/, out)
  end

  def test_recover_restores_a_stranded_park
    hold_lock(pid: dead_pid, started: STALE_START)
    _out, err, status = park('--recover')

    assert status.success?, err
    assert_equal ORIGINAL, File.read(@live)
    refute File.exist?(@lock)
  end

  def test_recover_treats_a_reused_process_id_as_stranded
    live_holder do |pid|
      hold_lock(pid: pid, started: STALE_START)
      _out, err, status = park('--recover')

      assert status.success?, err
      assert_equal ORIGINAL, File.read(@live)
      refute File.exist?(@lock)
    end
  end

  def test_recover_refuses_while_the_holder_is_running
    live_holder do |pid|
      hold_lock(pid: pid)
      _out, err, status = park('--recover')

      assert_equal 2, status.exitstatus
      assert_match(/\b#{pid}\b/, err)
      assert_equal ORIGINAL, File.read(File.join(@lock, 'CLAUDE.md'))
      refute File.exist?(@live)
    end
  end

  def test_recover_keeps_both_files_when_a_new_one_exists
    hold_lock(pid: dead_pid, started: STALE_START)
    File.write(@live, "newer\n")
    _out, err, status = park('--recover')

    assert_equal 2, status.exitstatus
    assert_equal "newer\n", File.read(@live)
    assert_equal ORIGINAL, File.read(File.join(@lock, 'CLAUDE.md'))
    assert_match(/appeared while parked/, err)
  end

  def test_recover_restores_a_parked_copy_that_changed
    hold_lock(pid: dead_pid, started: STALE_START)
    File.write(File.join(@lock, 'CLAUDE.md'), "checked by hand\n")
    _out, err, status = park('--recover')

    assert status.success?, err
    assert_equal "checked by hand\n", File.read(@live)
    refute File.exist?(@lock)
  end

  def test_recover_leaves_a_new_ownerless_lock_to_the_session_parking
    Dir.mkdir(@lock)
    _out, err, status = park('--recover')

    assert_equal 2, status.exitstatus
    assert_match(/try again/i, err)
    assert Dir.exist?(@lock)
  end

  def test_recover_clears_an_empty_lock_left_by_a_crash
    Dir.mkdir(@lock)
    two_minutes_ago = Time.now - 120
    File.utime(two_minutes_ago, two_minutes_ago, @lock)
    _out, err, status = park('--recover')

    assert status.success?, err
    assert_equal ORIGINAL, File.read(@live)
    refute File.exist?(@lock)
  end

  def test_recover_with_nothing_parked_changes_nothing
    out, _err, status = park('--recover')

    assert status.success?
    assert_match(/nothing to recover/, out)
    assert_equal ORIGINAL, File.read(@live)
  end

  def test_leaves_alone_a_lock_another_session_took_over
    live_holder do |pid|
      owner = File.join(@lock, 'owner')
      fingerprint = "sha256:#{Digest::SHA256.hexdigest(ORIGINAL)}"
      takeover = "checkout=/elsewhere/checkout2\npid=#{pid}\nstarted=#{start_time(pid)}\nfingerprint=#{fingerprint}\n"
      _out, err, status = park('--', 'ruby', '-e', "File.write(#{owner.inspect}, #{takeover.inspect})")

      assert_equal 2, status.exitstatus
      assert_match(/taken over/, err)
      assert_equal takeover, File.read(owner)
      assert_equal ORIGINAL, File.read(File.join(@lock, 'CLAUDE.md'))
      refute File.exist?(@live)
    end
  end

  def test_reports_a_park_cleared_while_the_command_ran
    clear = "mv '#{@lock}/CLAUDE.md' '#{@live}' && rm '#{@lock}/owner' && rmdir '#{@lock}'"
    _out, err, status = park('--', 'sh', '-c', clear)

    assert_equal 2, status.exitstatus
    assert_match(/cleared while this run was parked/, err)
    assert_equal ORIGINAL, File.read(@live)
  end

  def test_leaves_alone_a_lock_another_session_is_creating_after_a_clear
    clear = "mv '#{@lock}/CLAUDE.md' '#{@live}' && rm '#{@lock}/owner' && rmdir '#{@lock}'"
    other = "mkdir '#{@lock}'"
    _out, _err, status = park('--', 'sh', '-c', "#{clear} && #{other}")

    assert_equal 2, status.exitstatus
    assert Dir.exist?(@lock), "removed another session's newly created lock"
  end

  def test_says_plainly_when_the_lock_cannot_be_created
    missing = File.join(@tmp, 'no-such-config')
    _out, err, status = Open3.capture3(env.merge('CLAUDE_CONFIG_DIR' => missing), 'bash', SCRIPT, '--', 'true')

    assert_equal 2, status.exitstatus
    assert_match(/could not create/, err)
    refute_match(/another session/, err)
  end

  def test_refuses_to_park_when_it_cannot_read_its_own_start_time
    probe = File.join(@tmp, 'probe')
    _out, err, status = Open3.capture3(start_time_blind_env, 'bash', SCRIPT, '--', 'touch', probe)

    assert_equal 2, status.exitstatus
    assert_match(/start time/, err)
    refute File.exist?(probe)
    assert_equal ORIGINAL, File.read(@live)
    refute File.exist?(@lock)
  end

  def test_cleans_up_its_lock_when_it_cannot_write_the_owner_record
    shims = File.join(@tmp, 'shims')
    Dir.mkdir(shims)
    File.write(File.join(shims, 'mv'), "#!/bin/sh\ncase \"$2\" in */owner) exit 1 ;; esac\nexec /bin/mv \"$@\"\n")
    File.chmod(0o755, File.join(shims, 'mv'))
    probe = File.join(@tmp, 'probe')
    _out, err, status = Open3.capture3(env.merge('PATH' => "#{shims}:#{ENV.fetch('PATH')}"),
                                       'bash', SCRIPT, '--', 'touch', probe)

    assert_equal 2, status.exitstatus
    assert_match(/could not write/, err)
    refute File.exist?(probe)
    assert_equal ORIGINAL, File.read(@live)
    refute File.exist?(@lock)
  end

  def test_recover_refuses_where_it_cannot_tell_whether_the_holder_runs
    live_holder do |pid|
      hold_lock(pid: pid)
      _out, err, status = Open3.capture3(start_time_blind_env, 'bash', SCRIPT, '--recover')

      assert_equal 2, status.exitstatus
      assert_match(/cannot tell/, err)
      assert_equal ORIGINAL, File.read(File.join(@lock, 'CLAUDE.md'))
      refute File.exist?(@live)
    end
  end

  def test_status_and_refusal_do_not_call_a_holder_stranded_when_they_cannot_tell
    live_holder do |pid|
      hold_lock(pid: pid)
      out, _err, status = Open3.capture3(start_time_blind_env, 'bash', SCRIPT, '--status')

      assert status.success?
      assert_match(/cannot tell/, out)
      refute_match(/--recover/, out)

      _out, err, status = Open3.capture3(start_time_blind_env.merge('CLAUDE_MD_PARK_HOLDER' => pid.to_s),
                                         'bash', SCRIPT, '--', 'true')

      assert_equal 2, status.exitstatus
      assert_match(/cannot tell/, err)
      refute_match(/--recover/, err)
    end
  end

  def test_term_still_stops_the_command_when_ps_cannot_report_parents
    shims = File.join(@tmp, 'list-shims')
    Dir.mkdir(shims)
    File.write(File.join(shims, 'ps'), "#!/bin/sh\ncase \"$*\" in *ppid*) exit 1 ;; esac\nexec /bin/ps \"$@\"\n")
    File.chmod(0o755, File.join(shims, 'ps'))
    status, arm, command = interrupt_parked_run('TERM', :script, env.merge('PATH' => "#{shims}:#{ENV.fetch('PATH')}"))

    assert_equal 143, status.exitstatus
    wait_for(seconds: 3) { !running?(command) }
    assert_equal ORIGINAL, File.read(@live)
    refute File.exist?(@lock)
  ensure
    [arm, command].compact.each do |leftover|
      Process.kill('KILL', leftover)
    rescue Errno::ESRCH
      nil
    end
  end

  def test_explains_a_lock_it_cannot_remove
    _out, err, status = park('--', 'touch', File.join(@lock, 'stray'))

    assert_equal 2, status.exitstatus
    assert_match(/could not remove/, err)
    assert_equal ORIGINAL, File.read(@live)
    assert File.exist?(File.join(@lock, 'owner')), 'dropped the owner record, leaving a lock nobody can name'
  end

  def test_the_unremovable_lock_advice_leads_to_a_clean_recovery
    park('--', 'touch', File.join(@lock, 'stray'))
    File.delete(File.join(@lock, 'stray'))
    _out, err, status = park('--recover')

    assert status.success?, err
    assert_equal ORIGINAL, File.read(@live)
    refute File.exist?(@lock)
  end

  def test_refuses_without_a_command_and_parks_nothing
    _out, err, status = park('--')

    assert_equal 2, status.exitstatus
    assert_match(/usage/, err)
    assert_equal ORIGINAL, File.read(@live)
    refute File.exist?(@lock)
  end

  def test_status_reports_a_lock_with_no_owner_record
    Dir.mkdir(@lock)
    out, _err, status = park('--status')

    assert status.success?
    assert_match(/no owner record/, out)
  end

  def test_a_holder_token_for_a_stranded_park_does_not_bypass_the_lock
    probe = File.join(@tmp, 'probe')
    dead = dead_pid
    hold_lock(pid: dead, started: STALE_START)
    _out, err, status = Open3.capture3(env.merge('CLAUDE_MD_PARK_HOLDER' => dead.to_s), 'bash', SCRIPT, '--', 'touch', probe)

    assert_refused_leaving_lock_alone(status, probe)
    assert_match(/no longer running/, err)
  end

  def test_none_ok_still_parks_a_file_that_exists
    probe = File.join(@tmp, 'probe')
    _out, err, status = park('--none-ok', '--', 'sh', '-c', "test -e '#{@live}' && echo present > '#{probe}'; true")

    assert status.success?, err
    refute File.exist?(probe), 'CLAUDE.md was visible while parked'
    assert_equal ORIGINAL, File.read(@live)
    refute File.exist?(@lock)
  end

  def test_refuses_a_park_whose_process_id_was_reused
    probe = File.join(@tmp, 'probe')
    live_holder do |pid|
      hold_lock(pid: pid, started: STALE_START)
      _out, err, status = park('--', 'touch', probe)

      assert_refused_leaving_lock_alone(status, probe)
      assert_match(/no longer running/, err)
    end
  end

  def test_stops_and_reports_arms_the_command_left_running
    skip 'perl is needed for the command to get a process group of its own' unless perl_available?
    arm_file = File.join(@tmp, 'arm')
    saw = File.join(@tmp, 'saw')
    _out, err, status = Open3.capture3(env, *headless('--', 'sh', '-c', stubborn_arm(arm_file, saw)))
    arm = Integer(File.read(arm_file))

    assert status.success?, err
    assert_match(/left running process\(es\) .*\b#{arm}\b/, err)
    refute running?(arm), 'an arm that ignores TERM outlived the restore'
    refute File.exist?(saw), 'the arm was signalled after the file was back'
    assert_equal ORIGINAL, File.read(@live)
    refute File.exist?(@lock)
  ensure
    begin
      Process.kill('KILL', arm) if arm
    rescue Errno::ESRCH
      nil
    end
  end

  def test_a_command_that_does_not_exist_exits_127_and_restores
    _out, err, status = park('--', 'no-such-command-for-park-test')

    assert_equal 127, status.exitstatus
    assert_match(/no-such-command-for-park-test/, err)
    assert_equal ORIGINAL, File.read(@live)
    refute File.exist?(@lock)
  end

  def test_a_signal_while_stopping_leftovers_still_stops_them_first
    skip 'perl is needed for the command to get a process group of its own' unless perl_available?
    arm_file = File.join(@tmp, 'arm')
    saw = File.join(@tmp, 'saw')
    pid = Process.spawn(env, *headless('--', 'sh', '-c', stubborn_arm(arm_file, saw)), err: File::NULL)
    wait_for { File.size?(arm_file) }
    sleep 0.5
    Process.kill('TERM', pid)
    status = nil
    wait_for(seconds: 15) { (status = Process.wait2(pid, Process::WNOHANG)&.last) }
    arm = Integer(File.read(arm_file))

    assert_equal 143, status.exitstatus
    refute running?(arm), 'an arm that ignores TERM outlived the restore'
    refute File.exist?(saw), 'the arm was signalled after the file was back'
    assert_equal ORIGINAL, File.read(@live)
  ensure
    kill_group(pid)
    begin
      Process.kill('KILL', arm) if arm
    rescue Errno::ESRCH
      nil
    end
  end

  def test_term_stops_an_arm_the_command_orphaned
    skip 'perl is needed for the command to get a process group of its own' unless perl_available?
    arm_file = File.join(@tmp, 'arm')
    ready = File.join(@tmp, 'ready')
    command = "(sleep 30 >/dev/null 2>&1 & echo $! > '#{arm_file}'); touch '#{ready}'; sleep 30"
    pid = Process.spawn(env, *headless('--', 'sh', '-c', command), err: File::NULL)
    wait_for { File.exist?(ready) }
    arm = Integer(File.read(arm_file))
    Process.kill('TERM', pid)
    status = nil
    wait_for { (status = Process.wait2(pid, Process::WNOHANG)&.last) }

    assert_equal 143, status.exitstatus
    wait_for(seconds: 3) { !running?(arm) }
    assert_equal ORIGINAL, File.read(@live)
  ensure
    kill_group(pid)
    begin
      Process.kill('KILL', arm) if arm
    rescue Errno::ESRCH
      nil
    end
  end

  def test_without_perl_the_command_runs_and_the_file_comes_back
    shims = File.join(@tmp, 'no-perl')
    Dir.mkdir(shims)
    ENV.fetch('PATH').split(':').each do |dir|
      Dir.glob(File.join(dir, '*')).each do |tool|
        name = File.basename(tool)
        next if name.start_with?('perl') || File.exist?(File.join(shims, name))
        next unless File.file?(tool) && File.executable?(tool)

        File.symlink(tool, File.join(shims, name))
      end
    end
    probe = File.join(@tmp, 'probe')
    _out, err, status = Open3.capture3(env.merge('PATH' => shims), 'bash', SCRIPT, '--', 'touch', probe)

    assert status.success?, err
    assert File.exist?(probe)
    refute_match(/left running/, err)
    assert_equal ORIGINAL, File.read(@live)
    refute File.exist?(@lock)
  end

  def test_a_command_can_read_the_terminal
    output = +''
    PTY.spawn(env, 'bash', SCRIPT, '--', 'sh', '-c', 'read line; echo "got $line"') do |reader, writer, pid|
      writer.puts 'hello'
      wait_for(seconds: 5) do
        output << reader.read_nonblock(4096)
        output.include?('got hello')
      rescue IO::WaitReadable, Errno::EIO
        false
      end
      Process.wait(pid)
    ensure
      begin
        Process.kill('KILL', pid)
      rescue Errno::ESRCH
        nil
      end
    end

    assert_includes output, 'got hello'
    assert_includes output, 'will not be stopped'
    assert_equal ORIGINAL, File.read(@live)
  end

  def test_a_command_that_cannot_be_executed_exits_126
    blocked = File.join(@tmp, 'not-executable')
    File.write(blocked, "#!/bin/sh\n")
    _out, _err, status = park('--', blocked)

    assert_equal 126, status.exitstatus
    assert_equal ORIGINAL, File.read(@live)
  end

  def test_refuses_without_the_separator_and_parks_nothing
    _out, err, status = park('true')

    assert_equal 2, status.exitstatus
    assert_match(/usage/, err)
    assert_equal ORIGINAL, File.read(@live)
    refute File.exist?(@lock)
  end
end
