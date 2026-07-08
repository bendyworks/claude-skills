---
name: markdown-to-pdf
description: Convert one or more Markdown files to clean, print-styled PDFs. Use when the user asks for "a PDF version of <doc>.md", "export this markdown to PDF", "make a PDF of this doc", "turn these notes into a PDF", or wants to share a local .md as a PDF. Handles the macOS wkhtmltopdf 0-page trap and preserves monospace/aligned blocks.
---

# Markdown to PDF

Turn a local Markdown file into a shareable, print-styled PDF. The pipeline is
**md -> self-contained styled HTML -> PDF**, because going through HTML gives
consistent typography and keeps aligned/monospace blocks intact, and because
the reliable PDF engine (a Chromium-family browser's headless print) takes
HTML, not Markdown.

## Fast path

Run the bundled driver; it does everything and verifies the result:

```
bash SKILL_DIR/md2pdf.sh INPUT.md [OUTPUT.pdf] [WORKDIR]
```

- `OUTPUT.pdf` defaults to the source path with a `.pdf` extension (PDF lands
  next to the source, which is what "give me a PDF of X.md" almost always
  means -- do NOT drop it in a temp dir).
- Pass your session **scratchpad** as `WORKDIR` so the intermediate HTML is
  kept out of the user's project; otherwise a temp dir is used.
- For several files, loop over the driver; add a short `sleep 1` between
  Chrome invocations (headless Chrome can trip over rapid back-to-back runs).

The driver converts md->HTML (kramdown, else pandoc, else python-markdown),
then tries PDF engines in order (Chrome/Chromium headless, then wkhtmltopdf
**with page-count verification**, then weasyprint), and **exits non-zero if the
final PDF has 0 pages**. `SKILL_DIR` is this skill's own directory.

## Hard-won gotchas (the reason this skill exists)

1. **wkhtmltopdf silently emits 0-page PDFs on macOS (patched-Qt builds).** It
   returns success and writes a ~50KB file that opens blank -- `file x.pdf`
   says `PDF document, version 1.4, 0 pages`. ALWAYS verify page count; never
   trust a zero exit. The driver does this and discards a 0-page result. Prefer
   a Chromium-family browser's headless print, which is reliable here.
2. **kramdown: use the default parser, not GFM.** `Kramdown::Document.new(src,
   input: "GFM")` raises `no parser to handle GFM` unless `kramdown-parser-gfm`
   is installed (it usually is not). The default parser handles headings, bold,
   lists, indented code blocks, and tables -- which covers ordinary docs. The
   bundled `md2html.rb` already does this (and falls back to redcarpet).
3. **Keep the HTML self-contained.** Inline all CSS; no web fonts, no remote
   images. An external reference makes the PDF step attempt a network fetch
   (wkhtmltopdf throws `HostNotFoundError`; Chrome stalls). `md2html.rb`
   inlines everything.
4. **Preserve aligned/monospace blocks.** Space-aligned column blocks and code
   fences must render as `<pre>` with `white-space: pre` and a monospace font,
   or the alignment collapses. The bundled CSS does this; it's the thing most
   sensitive to breakage, so eyeball those blocks after rendering.

## Chrome headless invocation (manual fallback)

If you skip the driver:

```
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --disable-gpu --no-pdf-header-footer \
  --print-to-pdf="OUT.pdf" "file://ABSOLUTE/PATH/TO/page.html"
```

Use an **absolute** `file://` path. `--headless=new` is for modern Chrome; old
builds want plain `--headless`. `--no-pdf-header-footer` drops the default
date/URL chrome. On Linux use `google-chrome`/`chromium`; `weasyprint` or
`pandoc --pdf-engine=weasyprint` are good non-browser alternatives there.

## Verify before reporting done

- `file OUT.pdf` -> must say `N pages` with N > 0 (0 pages = failed render).
  Some Linux builds of `file(1)` omit the page count entirely -- fall back to
  `pdfinfo OUT.pdf`, or at minimum a non-zero-size check.
- A real multi-page PDF is tens of KB+; a couple-KB file is suspect.
- If `pdftoppm`/poppler is installed you can rasterize a page to eyeball it;
  if not, confirm the corrected/critical sections made it in by grepping the
  intermediate HTML for a distinctive phrase, and tell the user you verified
  structurally (not visually) so they give the layout a glance -- monospace
  column alignment is the one thing worth a human look.

## Styling / tweaks

Edit `md2html.rb`'s `CSS` block: page size and margins are set on the PDF-engine
side (driver uses Letter + 16mm; Chrome uses the HTML's `@page` if present).
Common asks: force a page break before a section (`page-break-before: always`),
shrink a wide `<pre>` (drop its font-size), or add a title/date header (prepend
to the body). Keep everything inline and offline.
