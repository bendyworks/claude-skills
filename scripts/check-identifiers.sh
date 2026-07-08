#!/usr/bin/env bash
# Guard against re-introducing personal or client-specific identifiers.
#
# This deliberately checks generic PATTERNS, not client names -- a public
# blocklist naming clients would itself be a leak. Skill examples should
# use the neutral ABC-NNN tracker prefix and example.com emails.
set -euo pipefail
cd "$(dirname "$0")/.."

SCAN="skills bin scripts README.md CONTRIBUTING.md .github .claude-plugin"

fail=0

# Tracker-style issue IDs other than the sanctioned placeholders (ABC-, SC-).
# Common technical tokens (UTF-8, ISO-8601, RFC-2822, CVE-..., SHA-256) are
# allowed. Filtering happens per match (-o), so an allowed token on the same
# line as a forbidden ID cannot mask it.
if grep -rnoE '\b[A-Z]{2,5}-[0-9]{1,6}\b' $SCAN 2>/dev/null \
  | grep -vE ':(ABC|SC|UTF|ISO|RFC|CVE|SHA|MD|CRC)-[0-9]+$' ; then
  echo "FAIL: tracker-style issue IDs found (use the ABC-NNN placeholder)."
  fail=1
fi

# Personal email addresses. The org contact address is allowed.
if grep -rnE '[A-Za-z0-9._%+-]+@bendyworks\.com' $SCAN 2>/dev/null \
  | grep -v 'info@bendyworks\.com' ; then
  echo "FAIL: personal email address found (use teammate@example.com)."
  fail=1
fi

# Absolute home-directory paths baked into skills.
if grep -rnE '(/Users|/home)/[A-Za-z0-9._-]+/' $SCAN 2>/dev/null ; then
  echo 'FAIL: absolute home-directory path found (use ${CLAUDE_PLUGIN_ROOT} or a relative path).'
  fail=1
fi

# Paths into a personal ~/.claude that installers will not have. This script
# must name the forbidden string in its own pattern and message, so it is
# excluded from its own scan.
if grep -rn --exclude=check-identifiers.sh '~/\.claude/bin' $SCAN 2>/dev/null ; then
  echo 'FAIL: ~/.claude/bin path found (the CLI is bundled in this plugin'"'"'s bin/).'
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "check-identifiers: clean"
fi
exit "$fail"
