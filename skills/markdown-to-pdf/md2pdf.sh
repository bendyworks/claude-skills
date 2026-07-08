#!/usr/bin/env bash
# Markdown -> PDF with engine fallbacks and MANDATORY page-count verification.
#
# Usage: md2pdf.sh INPUT.md [OUTPUT.pdf] [WORKDIR_FOR_INTERMEDIATE_HTML]
#   OUTPUT.pdf  defaults to INPUT with .pdf extension (next to the source).
#   WORKDIR     defaults to a temp dir; pass your session scratchpad to keep it.
#
# Pipeline: md -> self-contained HTML (md2html.rb) -> PDF (Chrome headless,
# then wkhtmltopdf-with-verification). Exits non-zero if the final PDF has 0
# pages -- the wkhtmltopdf-on-macOS failure mode this skill exists to catch.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IN="${1:?usage: md2pdf.sh INPUT.md [OUTPUT.pdf] [WORKDIR]}"
OUT="${2:-${IN%.*}.pdf}"
WORK="${3:-$(mktemp -d)}"
mkdir -p "$WORK"
HTML="$WORK/$(basename "${IN%.*}").html"

# --- md -> HTML ---
if command -v ruby >/dev/null 2>&1 && ruby -e 'require "kramdown"' 2>/dev/null; then
  ruby "$HERE/md2html.rb" "$IN" "$HTML"
elif command -v pandoc >/dev/null 2>&1; then
  pandoc "$IN" -o "$HTML" --standalone --metadata title="$(basename "${IN%.*}")"
elif command -v python3 >/dev/null 2>&1 && python3 -c 'import markdown' 2>/dev/null; then
  python3 -c 'import markdown,sys; open(sys.argv[2],"w").write("<!DOCTYPE html><meta charset=utf-8><body>"+markdown.markdown(open(sys.argv[1]).read(),extensions=["fenced_code","tables"])+"</body>")' "$IN" "$HTML"
else
  echo "md2pdf: no markdown->HTML converter (need ruby+kramdown, pandoc, or python3+markdown)" >&2
  exit 3
fi

# --- locate a Chromium-family browser (most reliable HTML->PDF on macOS) ---
CHROME=""
for c in \
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  "/Applications/Chromium.app/Contents/MacOS/Chromium" \
  "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" \
  "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
  google-chrome chromium chromium-browser brave-browser microsoft-edge ; do
  if [ -x "$c" ] || command -v "$c" >/dev/null 2>&1; then CHROME="$c"; break; fi
done

pagecount() { # echo page count, or 0 if unknown/none
  local f="$1"
  [ -s "$f" ] || { echo 0; return; }
  local n
  n="$(file "$f" 2>/dev/null | grep -oE '[0-9]+ pages?' | grep -oE '[0-9]+' | head -1 || true)"
  [ -n "$n" ] && echo "$n" || echo unknown
}

render_ok=0
try_finalize() { # $1=candidate pdf -> promote to $OUT if it has pages
  local cand="$1" n; n="$(pagecount "$cand")"
  if [ "$n" = "0" ]; then echo "md2pdf: $cand rendered 0 pages, discarding" >&2; rm -f "$cand"; return 1; fi
  mv -f "$cand" "$OUT"; render_ok=1
  echo "md2pdf: wrote $OUT (${n} pages)"; return 0
}

# --- Attempt 1: Chrome headless ---
if [ -n "$CHROME" ]; then
  # --headless=new for modern Chrome; fall back to --headless for old builds.
  if "$CHROME" --headless=new --disable-gpu --no-pdf-header-footer \
       --print-to-pdf="$WORK/_chrome.pdf" "file://$HTML" >/dev/null 2>&1 \
     || "$CHROME" --headless --disable-gpu --no-pdf-header-footer \
       --print-to-pdf="$WORK/_chrome.pdf" "file://$HTML" >/dev/null 2>&1; then
    [ -f "$WORK/_chrome.pdf" ] && try_finalize "$WORK/_chrome.pdf" || true
  fi
fi

# --- Attempt 2: wkhtmltopdf (VERIFY -- it emits 0-page PDFs on macOS/Qt) ---
if [ "$render_ok" = 0 ] && command -v wkhtmltopdf >/dev/null 2>&1; then
  wkhtmltopdf --quiet --page-size Letter \
    --margin-top 16mm --margin-bottom 16mm --margin-left 16mm --margin-right 16mm \
    --encoding utf-8 "$HTML" "$WORK/_wk.pdf" >/dev/null 2>&1 || true
  [ -f "$WORK/_wk.pdf" ] && try_finalize "$WORK/_wk.pdf" || true
fi

# --- Attempt 3: weasyprint ---
if [ "$render_ok" = 0 ] && command -v weasyprint >/dev/null 2>&1; then
  weasyprint "$HTML" "$WORK/_wp.pdf" >/dev/null 2>&1 || true
  [ -f "$WORK/_wp.pdf" ] && try_finalize "$WORK/_wp.pdf" || true
fi

if [ "$render_ok" = 0 ]; then
  echo "md2pdf: all PDF engines failed. HTML is at $HTML -- open it in a browser and Print to PDF." >&2
  exit 4
fi
