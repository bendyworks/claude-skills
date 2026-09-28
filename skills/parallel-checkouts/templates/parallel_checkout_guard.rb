# parallel-checkouts template v1 (bendyworks/claude-skills)
#
# Refuses to boot development or test when this shell's parallel-checkout
# identity does not belong to this checkout. Database names, Redis
# databases, and ports all follow PRJ_* variables that direnv exports per
# checkout, so running this code with another checkout's variables, or with
# none at all in a checkout that needs them, would point it at another
# checkout's databases.
#
# A checkout other than the original one keeps its suffix in a file named
# parallel-checkout inside its git directory, where `git clean` never
# reaches and every worktree of that clone finds it. Checkouts are compared
# by git directory rather than by path, so a worktree of a checkout runs
# under that checkout's identity. See docs/parallel-checkouts.md.
if Rails.env.development? || Rails.env.test?
  git_common_dir = lambda do |root|
    dot_git = File.join(root, ".git")
    if File.directory?(dot_git)
      File.realpath(dot_git)
    elsif File.file?(dot_git)
      git_dir = File.expand_path(File.read(dot_git)[/\Agitdir: (.+)$/, 1].to_s, root)
      common_file = File.join(git_dir, "commondir")
      File.realpath(File.exist?(common_file) ? File.expand_path(File.read(common_file).strip, git_dir) : git_dir)
    end
  end

  actual_root = File.realpath(Rails.root.to_s)
  actual_git = git_common_dir.call(actual_root)
  claimed_root = ENV.fetch("PRJ_CHECKOUT_ROOT", "")
  marker = actual_git && File.join(actual_git, "parallel-checkout")
  expected_suffix = File.read(marker).strip if marker && File.exist?(marker)

  problem =
    if expected_suffix == ""
      "This checkout's parallel-checkout marker (#{marker}) is empty."
    elsif !claimed_root.empty? && !claimed_root.start_with?("/")
      "PRJ_CHECKOUT_ROOT (#{claimed_root}) is not an absolute path."
    elsif !claimed_root.empty? && !File.directory?(claimed_root)
      "This shell carries the parallel-checkout identity of #{claimed_root}, which does not exist."
    elsif !claimed_root.empty? &&
          (git_common_dir.call(File.realpath(claimed_root)) || File.realpath(claimed_root)) != (actual_git || actual_root)
      "This shell carries the parallel-checkout identity of #{claimed_root}."
    elsif expected_suffix && ENV.fetch("PRJ_CHECKOUT_SUFFIX", "") != expected_suffix
      "This checkout's identity (suffix #{expected_suffix}) is not loaded in this shell."
    end

  if problem
    raise <<~MESSAGE
      #{problem}
      The code being run lives in #{actual_root}, and running it this way could
      use another checkout's databases. Run from #{actual_root} in a shell where
      direnv has loaded its .envrc, or use `direnv exec #{actual_root} <command>`.
    MESSAGE
  end
end
