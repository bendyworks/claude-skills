# parallel-checkouts template v1 (bendyworks/claude-skills)
#
# Refuses to boot development or test when this shell carries another
# checkout's identity. Database names, Redis databases, and ports all
# follow PRJ_* variables that direnv exports per checkout, so a shell
# still holding one checkout's variables would point this checkout's
# code at the other checkout's databases. See docs/parallel-checkouts.md.
if Rails.env.development? || Rails.env.test?
  claimed_root = ENV.fetch("PRJ_CHECKOUT_ROOT", "")
  actual_root = File.realpath(Rails.root.to_s)
  claimed_root = File.realpath(claimed_root) if File.exist?(claimed_root)

  unless claimed_root.empty? || claimed_root == actual_root
    raise <<~MESSAGE
      This shell carries the parallel-checkout identity of #{claimed_root},
      but this code lives in #{actual_root}. Running it would use the other
      checkout's databases. Run from #{actual_root} in a shell where direnv
      has loaded its .envrc, or use `direnv exec #{actual_root} <command>`.
    MESSAGE
  end
end
