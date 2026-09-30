# shellcheck shell=bash
#
# Browser discovery for the change-highlights scripts. Source it, then:
#
#   CHROME="$(find_chrome)" || exit 1
#
# CHROME, when set, is used as given and never replaced by a fallback: a
# typo in it should fail loudly, not print with a different browser.
# Otherwise the first Chromium-family browser in CHROME_CANDIDATES wins
# (the list is adapted from the markdown-to-pdf skill's md2pdf.sh). Prints
# the browser's path or command name; returns 1 with a hint when there is
# none.

CHROME_CANDIDATES=(
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  "/Applications/Chromium.app/Contents/MacOS/Chromium"
  "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
  "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
  google-chrome
  chromium
  chromium-browser
  brave-browser
  microsoft-edge
)

# A path must be an executable file (a macOS .app bundle is a directory); a
# bare name must be an executable on PATH, which is where the shell will
# look for it when the browser runs.
browser_runnable() {
  case "$1" in
    */*) [ -f "$1" ] && [ -x "$1" ] ;;
    *) type -P "$1" >/dev/null 2>&1 ;;
  esac
}

find_chrome() {
  local candidate
  if [ -n "${CHROME:-}" ]; then
    if browser_runnable "$CHROME"; then
      printf '%s\n' "$CHROME"
      return 0
    fi
    echo "CHROME is set but not executable: $CHROME" >&2
    return 1
  fi
  for candidate in "${CHROME_CANDIDATES[@]}"; do
    if browser_runnable "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  echo "No Chrome, Chromium, Brave, or Edge found. Install one, or set CHROME=/path/to/browser." >&2
  return 1
}
