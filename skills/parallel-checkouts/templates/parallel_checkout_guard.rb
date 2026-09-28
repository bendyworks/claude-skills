# parallel-checkouts template v1 (bendyworks/claude-skills)
#
# Refuses to boot development or test when this shell's parallel-checkout
# identity does not belong to this checkout. Database names, Redis
# databases, and ports all follow PRJ_* variables that direnv exports per
# checkout, so running this code with another checkout's variables, or with
# none at all in a checkout that needs them, would point it at another
# checkout's databases. A checkout other than the original one carries an
# untracked .parallel-checkout file holding its suffix. See
# docs/parallel-checkouts.md.
if Rails.env.development? || Rails.env.test?
  actual_root = File.realpath(Rails.root.to_s)
  claimed_root = ENV.fetch("PRJ_CHECKOUT_ROOT", "")
  claimed_root = File.realpath(claimed_root) if File.exist?(claimed_root)
  marker = File.join(actual_root, ".parallel-checkout")
  expected_suffix = File.exist?(marker) ? File.read(marker).strip : nil

  problem =
    if !claimed_root.empty? && claimed_root != actual_root
      "This shell carries the parallel-checkout identity of #{claimed_root}."
    elsif expected_suffix && ENV.fetch("PRJ_CHECKOUT_SUFFIX", "") != expected_suffix
      "This checkout's identity (suffix #{expected_suffix}) is not loaded in this shell."
    end

  if problem
    raise <<~MESSAGE
      #{problem}
      The code being run lives in #{actual_root}, and running it this way would
      use another checkout's databases. Run from #{actual_root} in a shell where
      direnv has loaded its .envrc, or use `direnv exec #{actual_root} <command>`.
    MESSAGE
  end
end
