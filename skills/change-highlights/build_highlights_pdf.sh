#!/usr/bin/env bash
#
# Build one change-highlights PDF per manifest. For each manifest JSON:
#   1. render HTML    (render_highlights.rb, which also runs the segregation gate)
#   2. print to PDF   (a Chromium-family browser, headless)
#   3. verify the PDF (it must exist and have at least one page)
#
#   bash build_highlights_pdf.sh MANIFEST.json [MORE.json ...]
#
# Output: OUT.html and OUT.pdf beside each manifest (same basename), so each
# manifest's name must end in .json. Any earlier OUT.html and OUT.pdf beside
# every manifest are deleted before the first build. If a manifest's
# `segregation.deny` token appears in its rendered HTML, no HTML is written
# for it and the script stops there: PDFs already built for earlier
# manifests remain, and later manifests are not built.
#
# The gate reads text, not images: every image the page shows comes from an
# image or image_row block (the renderer allows no other), and each one is
# listed as not scanned, to be checked by eye. Needs ruby and Chrome, Chromium,
# Brave, or Edge (see find_chrome.sh); CHROME=/path overrides discovery.

set -euo pipefail

SKILL_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RENDERER="$SKILL_DIR/render_highlights.rb"
# shellcheck source=find_chrome.sh
. "$SKILL_DIR/find_chrome.sh"

if [ "$#" -eq 0 ]; then
  sed -n '3,/^$/s/^# \{0,1\}//p' "$0" >&2
  exit 2
fi

# Check every manifest, then clear every earlier output, before building any:
# after a refusal, an old PDF or page is exactly the file that must not be
# sent, and a refusal stops the build before later manifests are reached.
for manifest in "$@"; do
  [ -f "$manifest" ] || { echo "Manifest not found: $manifest" >&2; exit 1; }
  case "$manifest" in
    *.json) ;;
    *) echo "Manifest name must end in .json (its .html and .pdf are replaced): $manifest" >&2; exit 1 ;;
  esac
done
for manifest in "$@"; do
  rm -f -- "${manifest%.json}.pdf" "${manifest%.json}.html"
done

CHROME="$(find_chrome)" || exit 1
# The page needs no network: its images are local files and its policy loads
# nothing else. Every request the browser makes goes to a proxy at
# 127.0.0.1:9, where nothing answers, and loopback loses its usual exemption.
# Both header-and-footer switches are passed (--print-to-pdf-no-header is the
# older name), since a printed footer would show the page's file:// URL.
PRINT_FLAGS=(--disable-gpu --no-pdf-header-footer --print-to-pdf-no-header
  --proxy-server=127.0.0.1:9 "--proxy-bypass-list=<-loopback>")

# Page count, and the path of each image, read from the built files: the page
# writes images as file:// URLs, which are decoded back to paths to open.
pdf_pages() {
  ruby -e 'print File.binread(ARGV[0]).scan(%r{/Type\s*/Page(?![s\w])}).size' -- "$1"
}
# The page's file:// URL, each path segment percent-encoded: the browser
# decodes the URL, so a raw "%41" or "#" in a name would print another file.
page_url() {
  ruby -rerb -e 'print "file://" + File.expand_path(ARGV[0]).split("/", -1).map { |s| ERB::Util.url_encode(s) }.join("/")' -- "$1"
}
image_sources() {
  ruby -r "$RENDERER" -e 'puts File.read(ARGV[0], encoding: "UTF-8").scan(/<img\b[^>]*?\ssrc="([^"]*)"/i).flatten.map { |s| ChangeHighlights.percent_decode(CGI.unescapeHTML(s).sub(%r{\Afile://}, "")) }' -- "$1"
}

for manifest in "$@"; do
  base="${manifest%.json}"
  html="${base}.html"
  pdf="${base}.pdf"

  echo "==> Rendering $manifest (segregation gate runs here)"
  ruby "$RENDERER" "$manifest" "$html"

  url="$(page_url "$html")"
  echo "==> Printing $pdf"
  # --headless=new first; if that run fails, once more with plain --headless.
  "$CHROME" --headless=new "${PRINT_FLAGS[@]}" --print-to-pdf="$pdf" "$url" >/dev/null 2>&1 \
    || "$CHROME" --headless "${PRINT_FLAGS[@]}" --print-to-pdf="$pdf" "$url" >/dev/null 2>&1 \
    || true

  pages=0
  if [ -s "$pdf" ]; then
    pages="$(pdf_pages "$pdf")" || pages=0
  fi
  # Fails closed: anything but a positive count, a non-number included.
  if ! [ "$pages" -gt 0 ] 2>/dev/null; then
    rm -f -- "$pdf"
    echo "$pdf has no pages: the browser ($CHROME) did not print it. The HTML is at $html." >&2
    exit 1
  fi
  echo "    wrote $pdf ($pages page$([ "$pages" -eq 1 ] || echo s))"

  images="$(image_sources "$html")"
  if [ -n "$images" ]; then
    echo "    NOT SCANNED by the segregation gate -- check these images by eye for other recipients' data:"
    printf '%s\n' "$images" | sed 's/^/      /'
  fi
done

echo "==> Done. Open each PDF to confirm its layout and that only the intended recipient's data is present."
