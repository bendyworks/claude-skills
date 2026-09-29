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
require 'tmpdir'

class ParkClaudeMdTest < Minitest::Test
  SCRIPT = File.expand_path('../scripts/park-claude-md.sh', __dir__)
  ORIGINAL = "# user rules\nalways say hello\n"

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

  def test_runs_the_command_with_the_file_parked_and_restores_it
    probe = File.join(@tmp, 'probe')
    _out, err, status = park('--', 'sh', '-c', "ls '#{@config}' > '#{probe}'; test -e '#{@live}' && echo present >> '#{probe}'; true")

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

  # The form the script records: fixed to the C locale and UTC, so the
  # same process reads the same from any terminal.
  def start_time(pid)
    out, = Open3.capture2({ 'LC_ALL' => 'C', 'TZ' => 'UTC0' }, 'ps', '-o', 'lstart=', '-p', pid.to_s)
    out.strip
  end

  # Stands in for another session's park: a lock directory holding the
  # parked file and an owner record for the given process.
  def hold_lock(pid:, started: start_time(pid), checkout: '/elsewhere/checkout2')
    Dir.mkdir(@lock)
    File.write(File.join(@lock, 'owner'), "checkout=#{checkout}\npid=#{pid}\nstarted=#{started}\n")
    File.rename(@live, File.join(@lock, 'CLAUDE.md'))
  end

  def live_holder
    pid = Process.spawn('sleep', '30')
    yield pid
  ensure
    Process.kill('KILL', pid)
    Process.wait(pid)
  end

  def assert_refused_leaving_lock_alone(status, probe)
    assert_equal 2, status.exitstatus
    refute File.exist?(probe), 'command ran despite the refusal'
    assert_equal ORIGINAL, File.read(File.join(@lock, 'CLAUDE.md'))
    refute File.exist?(@live)
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
    dead = Process.spawn('true')
    Process.wait(dead)
    hold_lock(pid: dead, started: 'Thu Jan  1 00:00:00 1970')
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

  # Starts the script in its own process group around a command that
  # starts an arm of its own (the way a batch starts its claude -p runs)
  # and marks itself ready, sends the signal once the file is parked,
  # and returns the script's exit status and the arm's process ID.
  def interrupt_parked_run(signal, target)
    ready = File.join(@tmp, 'ready')
    arm = File.join(@tmp, 'arm')
    # The trailing sleep keeps the command running after its arm dies,
    # so the script's exit shows the command itself was stopped.
    command = "sleep 30 & echo $! > '#{arm}'; touch '#{ready}'; wait; sleep 30"
    pid = Process.spawn(env, 'bash', SCRIPT, '--', 'sh', '-c', command, pgroup: true, err: File::NULL)
    wait_for { File.exist?(ready) }
    refute File.exist?(@live), 'command started before the file was parked'
    Process.kill(signal, target == :group ? -pid : pid)
    status = nil
    wait_for { (status = Process.wait2(pid, Process::WNOHANG)&.last) }
    [status, Integer(File.read(arm))]
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
    !`ps -o stat= -p #{pid}`.strip.start_with?('Z')
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

  def dead_pid
    pid = Process.spawn('true')
    Process.wait(pid)
    pid
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
    hold_lock(pid: dead_pid, started: 'Thu Jan  1 00:00:00 1970')
    out, _err, status = park('--status')

    assert status.success?
    assert_match(/no longer running/, out)
    assert_match(/--recover/, out)
  end

  def test_recover_restores_a_stranded_park
    hold_lock(pid: dead_pid, started: 'Thu Jan  1 00:00:00 1970')
    _out, err, status = park('--recover')

    assert status.success?, err
    assert_equal ORIGINAL, File.read(@live)
    refute File.exist?(@lock)
  end

  def test_recover_treats_a_reused_process_id_as_stranded
    live_holder do |pid|
      hold_lock(pid: pid, started: 'Thu Jan  1 00:00:00 1970')
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
    hold_lock(pid: dead_pid, started: 'Thu Jan  1 00:00:00 1970')
    File.write(@live, "newer\n")
    _out, err, status = park('--recover')

    assert_equal 2, status.exitstatus
    assert_equal "newer\n", File.read(@live)
    assert_equal ORIGINAL, File.read(File.join(@lock, 'CLAUDE.md'))
    assert_match(/appeared while parked/, err)
  end

  def test_recover_restores_a_parked_copy_that_changed
    hold_lock(pid: dead_pid, started: 'Thu Jan  1 00:00:00 1970')
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
    shims = File.join(@tmp, 'shims')
    Dir.mkdir(shims)
    File.write(File.join(shims, 'ps'), "#!/bin/sh\ncase \"$*\" in *lstart*) exit 1 ;; esac\nexec /bin/ps \"$@\"\n")
    File.chmod(0o755, File.join(shims, 'ps'))
    probe = File.join(@tmp, 'probe')
    _out, err, status = Open3.capture3(env.merge('PATH' => "#{shims}:#{ENV.fetch('PATH')}"),
                                       'bash', SCRIPT, '--', 'touch', probe)

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

  def test_refuses_without_the_separator_and_parks_nothing
    _out, err, status = park('true')

    assert_equal 2, status.exitstatus
    assert_match(/usage/, err)
    assert_equal ORIGINAL, File.read(@live)
    refute File.exist?(@lock)
  end
end
