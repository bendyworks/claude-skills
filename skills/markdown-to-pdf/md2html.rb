#!/usr/bin/env ruby
# Markdown -> self-contained styled HTML. No external resources (inline CSS,
# no web fonts, no remote images) so the HTML->PDF step never touches the
# network. Usage: ruby md2html.rb INPUT.md OUTPUT.html [--title "Title"]
#
# Converter preference: kramdown (default parser -- do NOT pass input:"GFM",
# the kramdown-parser-gfm gem is often absent). Falls back to redcarpet.

infile, outfile = ARGV[0], ARGV[1]
abort "usage: md2html.rb INPUT.md OUTPUT.html" unless infile && outfile
title_idx = ARGV.index("--title")
title = title_idx ? ARGV[title_idx + 1] : File.basename(infile, ".*")

src = File.read(infile)

body =
  begin
    require "kramdown"
    Kramdown::Document.new(src, auto_ids: false, hard_wrap: false).to_html
  rescue LoadError
    require "redcarpet"
    md = Redcarpet::Markdown.new(
      Redcarpet::Render::HTML.new(with_toc_data: false),
      fenced_code_blocks: true, tables: true, autolink: true,
      strikethrough: true, no_intra_emphasis: true
    )
    md.render(src)
  end

CSS = <<~CSS
  * { box-sizing: border-box; }
  body { font-family: -apple-system, "Helvetica Neue", Arial, sans-serif;
    font-size: 11pt; line-height: 1.5; color: #1a1a1a; margin: 0; }
  h1 { font-size: 20pt; border-bottom: 2px solid #333; padding-bottom: 6px; margin: 0 0 4px; }
  h2 { font-size: 14pt; margin: 20px 0 6px; border-bottom: 1px solid #ccc; padding-bottom: 3px; }
  h3 { font-size: 12pt; margin: 16px 0 4px; color: #222; }
  h1, h2, h3 { page-break-after: avoid; }
  p, li { font-size: 11pt; }
  ul, ol { margin: 6px 0; padding-left: 22px; }
  li { margin: 2px 0; }
  strong { color: #000; }
  em { color: #333; }
  code { font-family: "SF Mono", Menlo, Consolas, monospace; font-size: 9.5pt;
    background: #f2f2f2; padding: 1px 4px; border-radius: 3px; }
  pre { font-family: "SF Mono", Menlo, Consolas, monospace; font-size: 9pt;
    line-height: 1.35; background: #f6f8fa; border: 1px solid #e1e4e8;
    border-radius: 5px; padding: 10px 12px; white-space: pre; overflow-x: auto;
    page-break-inside: avoid; }
  pre code { background: none; padding: 0; font-size: 9pt; }
  hr { border: none; border-top: 1px solid #ddd; margin: 18px 0; }
  blockquote { border-left: 3px solid #ccc; margin: 8px 0; padding: 2px 12px; color: #555; }
  table { border-collapse: collapse; width: 100%; font-size: 10pt; }
  th, td { border: 1px solid #ccc; padding: 5px 8px; text-align: left; vertical-align: top; }
  th { background: #f2f2f2; }
CSS

html = %(<!DOCTYPE html><html><head><meta charset="utf-8"><title>#{title}</title>) +
       %(<style>#{CSS}</style></head><body>#{body}</body></html>)
File.write(outfile, html)
warn "md2html: wrote #{outfile} (#{html.bytesize} bytes)"
