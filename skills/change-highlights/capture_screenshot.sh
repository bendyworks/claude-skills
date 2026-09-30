#!/usr/bin/env bash
#
# Capture strategies 2 and 3: screenshot one URL to a PNG with a headless
# browser. Run it once under the "before" code and once under "after",
# then reference the two images as `image` or `image_row` blocks.
#
#   bash capture_screenshot.sh URL OUT.png
#
# URL is usually a file:// path to a page the app rendered to disk (see
# SKILL.md), which needs no signed-in session. To reuse a signed-in
# session instead, sign in once in a browser started with
# --user-data-dir=<dir> and pass PROFILE=<dir>.
#
# Env: CHROME (browser path, overrides discovery), PROFILE (browser
# user-data dir), WIDTH (viewport width, default 1200).

set -euo pipefail

SKILL_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=find_chrome.sh
. "$SKILL_DIR/find_chrome.sh"

if [ "$#" -ne 2 ]; then
  sed -n '3,/^$/s/^# \{0,1\}//p' "$0" >&2
  exit 2
fi

url="$1"
out="$2"
# Only a page address, never something the browser would read as a switch.
# The scheme is compared in lowercase, as the browser does.
case "$(printf '%s' "${url%%:*}" | tr '[:upper:]' '[:lower:]'):${url#*:}" in
  file://* | http://* | https://*) ;;
  *) echo "URL must start with file://, http://, or https://: $url" >&2; exit 2 ;;
esac
CHROME="$(find_chrome)" || exit 1

args=(--disable-gpu --hide-scrollbars "--window-size=${WIDTH:-1200},2400" "--screenshot=${out}")
[ -n "${PROFILE:-}" ] && args+=("--user-data-dir=${PROFILE}")

echo "==> Screenshotting $url -> $out"
rm -f -- "$out"
# --headless=new first; if that run fails, once more with plain --headless.
"$CHROME" --headless=new "${args[@]}" "$url" >/dev/null 2>&1 \
  || "$CHROME" --headless "${args[@]}" "$url" >/dev/null 2>&1 \
  || true
if [ ! -s "$out" ]; then
  rm -f -- "$out"
  echo "$out was not written: the browser ($CHROME) did not capture $url." >&2
  exit 1
fi
echo "    wrote $out"
echo "    Reference it as an \"image\" block, or pair before and after in an \"image_row\"."
