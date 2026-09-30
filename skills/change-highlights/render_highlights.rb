#!/usr/bin/env ruby
# frozen_string_literal: true

# Render a stakeholder-facing "what's changing" highlights HTML page from a
# highlights manifest (JSON). The companion build_highlights_pdf.sh prints the
# HTML to PDF with a headless Chromium-family browser.
#
#   ruby render_highlights.rb MANIFEST.json [OUT.html]
#
# Runs under plain `ruby` -- it only reads JSON and writes HTML, so it needs
# neither Docker nor Rails. Stdlib only: no ActiveSupport.
#
# Data segregation is enforced here: after building the HTML and BEFORE writing
# it, every `segregation.deny` token is searched for in the text the page
# displays and in its image attributes, both normalized (see comparable). The
# renderer escapes every text a manifest supplies and writes every tag itself,
# so the gate reads what the browser prints. If a token appears, or the
# manifest cannot be checked as written, nothing is written, any page an
# earlier run left is deleted, and the script exits non-zero.
#
# The ChangeHighlights module is pure (manifest in, HTML out, errors raised);
# the CLI class does the file I/O and turns an error into a non-zero exit.
# Tests load this file without running the CLI. See SKILL.md for the manifest
# schema and the capture recipes that produce one.

require 'json'
require 'cgi/escape'
require 'erb'

module ChangeHighlights
  # Raised when a manifest cannot be checked as written, such as a deny list
  # that is not a list of strings: checking it anyway would pass every page.
  class ManifestError < StandardError; end

  # Raised when a deny token appears in the rendered HTML. Carries each leaked
  # token with its occurrence count.
  class SegregationError < StandardError
    attr_reader :leaks

    def initialize(leaks)
      @leaks = leaks
      super("segregation deny tokens present in HTML: #{leaks.keys.map(&:inspect).join(', ')}")
    end
  end

  CSS = <<~CSS
    @page { size: Letter; margin: 0.5in; }
    * { box-sizing: border-box; }
    body { font-family: -apple-system, Arial, sans-serif; margin: 0; color: #222; font-size: 15px; }
    h1 { font-size: 24px; margin: 0 0 10px; }
    .intro { font-size: 15px; color: #444; line-height: 1.5; margin-bottom: 16px; }
    .preview-note { background: #fff3cd; border: 1px solid #e0c97f; border-radius: 6px;
                    padding: 10px 14px; font-size: 15px; font-weight: bold; line-height: 1.45;
                    margin: 0 0 16px; color: #6b4e00; }
    /* An example is one unit of meaning: its heading, its narrative and its
       tables have to be read together. Letting a page break fall inside one
       strands a total on the next page from the rows it sums, which is the
       single worst thing this document can do to a reader checking figures.
       break-inside only asks, though: a card taller than a page still breaks,
       so such an example belongs split in two. Only visible in the PDF --
       the HTML has no pages. */
    .card { border: 1px solid #ddd; border-radius: 8px; padding: 14px 18px; margin-bottom: 16px;
            break-inside: avoid; page-break-inside: avoid; }
    .card h2 { font-size: 19px; margin: 0 0 10px; }
    .totals-cmp, table.adj { break-inside: avoid; page-break-inside: avoid; }
    .block-title { font-size: 16px; font-weight: bold; margin: 8px 0 5px; }
    .totals-cmp { width: 100%; border-collapse: collapse; font-size: 15px; margin-bottom: 6px; }
    .totals-cmp th, .totals-cmp td { border: 1px solid #e2e2e2; padding: 6px 12px; text-align: right; }
    .totals-cmp th:first-child, .totals-cmp td:first-child { text-align: left; }
    .totals-cmp thead th { background: #f4f4f4; }
    .before-col { background: #fdecea; }
    .after-col  { background: #eafaf1; }
    .changed { font-weight: bold; }
    .nochange { font-size: 14px; color: #1c6b3c; font-style: italic; margin: 0 0 12px; }
    table.adj { width: 100%; border-collapse: collapse; font-size: 15px; }
    table.adj th, table.adj td { border: 1px solid #e2e2e2; padding: 5px 12px; text-align: right; }
    table.adj th:first-child, table.adj td:first-child { text-align: left; }
    table.adj thead th { background: #f4f4f4; }
    table.adj tr.totals th, table.adj tr.totals td { font-weight: bold; background: #fafafa; }
    .info { color: #888; font-style: italic; }
    .explain { background: #fff8e1; border: 1px solid #f0e0a8; border-radius: 6px;
               padding: 10px 14px; font-size: 15px; line-height: 1.5; margin: 10px 0; }
    .explain b { color: #1c6b3c; }
    figure { margin: 10px 0; }
    figure img { max-width: 100%; border: 1px solid #ddd; border-radius: 4px; display: block; }
    figcaption { font-size: 13px; color: #666; margin-top: 4px; }
    .image-row { display: flex; gap: 12px; margin: 10px 0; }
    .image-row figure { flex: 1; margin: 0; }
    .intro p, .explain p, .text p { margin: 0 0 8px; }
    .intro ul, .explain ul, .text ul { margin: 0 0 8px; padding-left: 20px; }
    .intro > :last-child, .explain > :last-child, .text > :last-child { margin-bottom: 0; }
    .text { line-height: 1.5; margin: 10px 0; }
  CSS

  DEFAULT_CURRENCY = '$'

  # The page forbids scripts, frames, fonts, and every other load except local
  # images and the renderer's own inline styles, so nothing a manifest supplies
  # can run or fetch anything while the page prints.
  CONTENT_SECURITY_POLICY = '<meta http-equiv="Content-Security-Policy" content="default-src ' \
                            "'none'; img-src file:; style-src 'unsafe-inline'\">"
  # The inline tags the renderer writes (bold text, a row's info note), so a
  # word split by one reads as one word (see displayed_texts).
  INLINE_TAG = %r{</?(?:b|span)\b[^>]*>}.freeze

  # Raw-HTML fields that manifests written for an earlier version of this
  # skill used. The renderer writes every tag itself now, so a manifest still
  # using one is refused, naming the replacement, rather than printed without
  # that content.
  RETIRED = {
    'intro_html' => 'intro', 'explanation_html' => 'explanation', 'html block' => 'text block'
  }.freeze

  module_function

  # Text an author supplies for the overview, an explanation, or a text block:
  # one paragraph as a string, or a list whose items are paragraphs and
  # {"list": [...]} bullet lists. The only markup is **bold**. Everything is
  # escaped and the renderer writes every tag, so the segregation gate reads
  # exactly the text the browser prints.
  def rich_text(value, field)
    (value.is_a?(Array) ? value : [value]).map do |item|
      case item
      when String then "<p>#{inline(item)}</p>"
      when Hash then bullet_list(item, field)
      else
        raise ManifestError, "#{field} must be text, or a list of paragraphs and {\"list\": [...]} items"
      end
    end.join
  end

  def bullet_list(item, field)
    entries = item['list']
    unless item.keys == ['list'] && entries.is_a?(Array) && entries.all?(String)
      raise ManifestError, "#{field} has an item that is not a paragraph or {\"list\": [text, ...]}"
    end

    "<ul>#{entries.map { |entry| "<li>#{inline(entry)}</li>" }.join}</ul>"
  end

  def inline(text)
    h(text).gsub(/\*\*(.+?)\*\*/m) { "<b>#{Regexp.last_match(1)}</b>" }
  end

  # The list at field, which must be a list of objects: examples, blocks, rows,
  # and images. A missing list is empty.
  def objects(value, field)
    return [] if value.nil?
    raise ManifestError, "#{field} must be a list of objects" unless value.is_a?(Array) && value.all?(Hash)

    value
  end

  def reject_retired!(manifest)
    retired = []
    retired << 'intro_html' if manifest.key?('intro_html')
    objects(manifest['examples'], 'examples').each do |example|
      retired << 'explanation_html' if example.key?('explanation_html')
      retired << 'html block' if objects(example['blocks'], 'blocks').any? { |block| block['type'] == 'html' }
    end
    return if retired.empty?

    replacements = retired.uniq.map { |old| "#{old} with #{RETIRED[old]}" }.join(', ')
    raise ManifestError, "raw HTML is no longer accepted: replace #{replacements} (plain text, **bold** for emphasis)"
  end

  def money(cents, symbol = DEFAULT_CURRENCY)
    cents ||= 0
    raise ManifestError, "amounts are whole cents, got #{cents.inspect}" unless cents.is_a?(Integer)

    whole, frac = cents.abs.divmod(100)
    grouped = whole.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse
    "#{cents.negative? ? '-' : ''}#{symbol}#{grouped}.#{format('%02d', frac)}"
  end

  def h(text)
    CGI.escapeHTML(text.to_s)
  end

  # The first bytes of every PNG file.
  PNG_SIGNATURE = "\x89PNG\r\n\x1a\n".b.freeze

  # The file:// URL of an image, built from the real file it names. The page
  # prints with no network, so a remote source (including a protocol-relative
  # "//host/x.png") is refused, as is a data: source, which gives the reviewer
  # no file to open. The file must be a PNG, judged by its first bytes and
  # after following any symlink: the browser renders an SVG's text as PDF text
  # the gate never reads, and copies a JPEG whole, comments and metadata
  # included. The browser also decodes the URL it is given, so each path
  # segment is percent-encoded: "Cont%6Fso.png" must not load Contoso.png.
  def image_url(src, manifest_dir)
    raise ManifestError, 'an image has an empty src' if src.strip.empty?
    if src.start_with?('//') || src.match?(%r{\Ahttps?://}i)
      raise ManifestError, "image src #{src.inspect} is remote: download it and use the local copy"
    end
    raise ManifestError, "image src #{src[0, 40].inspect}... is a data: URI: save the image as a file" if src.match?(/\Adata:/i)

    path = real_png_path(image_path(src, manifest_dir))
    "file://#{path.split('/', -1).map { |segment| ERB::Util.url_encode(segment) }.join('/')}"
  end

  # The absolute path src names. A file: URL drops its host, query, and
  # fragment and is decoded; it must name an absolute path. Anything else is
  # a path, relative ones resolving against the manifest's directory.
  def image_path(src, manifest_dir)
    return src if src.start_with?('/')
    return File.join(manifest_dir, src) unless src.match?(/\Afile:/i)

    path = percent_decode(src.sub(%r{\Afile:(//[^/]*)?}i, '').sub(/[?#].*\z/m, ''))
    raise ManifestError, "image src #{src.inspect} decodes to a name that is not UTF-8" unless path.valid_encoding?
    raise ManifestError, "image src #{src.inspect} names no absolute path: use file:///path/to/image.png" unless path.start_with?('/')

    path
  end

  def real_png_path(path)
    real = File.realpath(path)
    raise ManifestError, "image #{real} is not a file" unless File.file?(real)
    unless File.open(real, 'rb') { |file| file.read(PNG_SIGNATURE.bytesize) } == PNG_SIGNATURE
      raise ManifestError, "image #{real} is not a PNG: convert it to PNG (a screenshot already is)"
    end

    real
  rescue Errno::ENOENT, Errno::ENOTDIR
    raise ManifestError, "image not found: #{path}"
  rescue SystemCallError => e
    raise ManifestError, "cannot read image #{path}: #{e.message}"
  end

  def percent_decode(text)
    text.b.gsub(/%(\h\h)/n) { Regexp.last_match(1).hex.chr }.force_encoding(Encoding::UTF_8)
  end

  def comparison_table(block, symbol = DEFAULT_CURRENCY)
    before_label = block['before_label'] || 'BEFORE'
    after_label  = block['after_label']  || 'AFTER'
    out = +''
    out << %(<div class="block-title">#{h(block['title'])}</div>) if block['title']
    out << %(<table class="totals-cmp"><thead><tr><th>#{h(block['row_header'] || '')}</th>)
    out << %(<th class="before-col">#{h(before_label)}</th><th class="after-col">#{h(after_label)}</th></tr></thead><tbody>)
    objects(block['rows'], 'rows').each do |row|
      bv = row['before_cents']
      av = row['after_cents']
      changed = (bv || 0) == (av || 0) ? '' : ' changed'
      out << %(<tr><td>#{h(row['label'])}</td><td class="before-col">#{h(money(bv, symbol))}</td>)
      out << %(<td class="after-col#{changed}">#{h(money(av, symbol))}</td></tr>)
    end
    out << '</tbody></table>'
    out << %(<p class="nochange">#{h(block['no_change_note'])}</p>) if block['no_change_note']
    out
  end

  # The Total reconciles with the rows actually shown: it is the arithmetic sum of
  # the displayed amounts. Convey "this row does not affect your totals" via the
  # per-row `info` tag and a separate note, never by dropping a row from this sum.
  def amount_table(block, symbol = DEFAULT_CURRENCY)
    rows = objects(block['rows'], 'rows')
    out = +''
    out << %(<div class="block-title">#{h(block['title'])}</div>) if block['title']
    if rows.empty?
      out << %(<p class="info">#{h(block['empty_note'] || 'Nothing to show this period.')}</p>)
      return out
    end
    out << %(<table class="adj"><thead><tr><th>#{h(block['label_header'] || 'Description')}</th>)
    out << %(<th>#{h(block['amount_header'] || 'Amount')}</th></tr></thead><tbody>)
    rows.each do |row|
      info = row['info'] ? %( <span class="info">(#{h(row['info'])})</span>) : ''
      out << %(<tr><td>#{h(row['label'])}#{info}</td><td>#{h(money(row['amount_cents'], symbol))}</td></tr>)
    end
    shown_total = rows.sum { |r| r['amount_cents'] || 0 }
    out << %(<tr class="totals"><th>#{h(block['total_label'] || 'Total')}</th><td>#{h(money(shown_total, symbol))}</td></tr>)
    out << '</tbody></table>'
    out
  end

  def figure_html(image, manifest_dir)
    raise ManifestError, "an image has no src (caption #{image['caption'].inspect})" unless image['src'].is_a?(String)

    src = image_url(image['src'], manifest_dir)
    cap = image['caption'] ? %(<figcaption>#{h(image['caption'])}</figcaption>) : ''
    %(<figure><img src="#{h(src)}" alt="#{h(image['caption'])}">#{cap}</figure>)
  end

  def render_block(block, manifest_dir, symbol = DEFAULT_CURRENCY)
    case block['type']
    when 'comparison_table' then comparison_table(block, symbol)
    when 'amount_table'     then amount_table(block, symbol)
    when 'image'            then figure_html(block, manifest_dir)
    when 'image_row'
      figs = objects(block['images'], 'images').map { |img| figure_html(img, manifest_dir) }.join
      %(<div class="image-row">#{figs}</div>)
    when 'text' then %(<div class="text">#{rich_text(block['content'], 'text block')}</div>)
    else
      raise ManifestError, "unknown block type #{block['type'].inspect}: use comparison_table, amount_table, image, image_row, or text"
    end
  end

  def render_example(example, manifest_dir, symbol = DEFAULT_CURRENCY)
    out = +%(<div class="card">)
    out << %(<h2>#{h(example['heading'])}</h2>) if example['heading']
    out << %(<div class="explain">#{rich_text(example['explanation'], 'explanation')}</div>) if example['explanation']
    objects(example['blocks'], 'blocks').each { |block| out << render_block(block, manifest_dir, symbol) }
    out << '</div>'
    out
  end

  def render(manifest, manifest_dir)
    reject_retired!(manifest)
    title = manifest['title'] || "What's changing"
    symbol = manifest['currency_symbol'] || DEFAULT_CURRENCY
    html = +"<!DOCTYPE html><html><head><meta charset='utf-8'>#{CONTENT_SECURITY_POLICY}"
    html << "<title>#{h(title)}</title><style>#{CSS}</style></head><body>"
    html << %(<h1>#{h(title)}</h1>)
    html << %(<div class="intro">#{rich_text(manifest['intro'], 'intro')}</div>) if manifest['intro']
    html << %(<div class="preview-note">#{h(manifest['preview_caveat'])}</div>) if manifest['preview_caveat']
    objects(manifest['examples'], 'examples').each { |example| html << render_example(example, manifest_dir, symbol) }
    html << '</body></html>'
  end

  # Each deny token found in the HTML, mapped to its occurrence count.
  #
  # A token leaks when a reader would see it on the page, so the search covers
  # the page's text as displayed_texts gives it (the renderer's own stylesheet
  # aside) and attribute_values. Every text, and every token, is compared in
  # the form comparable gives it.
  def leaks(html, deny)
    page = html.sub(%r{<style>.*?</style>}m, '')
    haystacks = [*displayed_texts(page), comparable(CGI.unescapeHTML(attribute_values(page)))]
    deny.each_with_object({}) do |token, found|
      needle = comparable(token.to_s)
      count = haystacks.map { |text| text.scan(needle).size }.max
      found[token] = count if count.positive?
    end
  end

  # The values of the attributes the renderer writes that name files or carry
  # text: an image's src, decoded to the path it names, and its alt, which a
  # browser shows when the image fails to load. A file named for another
  # tenant is worth refusing even though its name never prints.
  def attribute_values(html)
    html.scan(/\s(src|alt)="([^"]*)"/).map { |name, value| name == 'src' ? percent_decode(value) : value }.join(' ')
  end

  # The page's text three ways: every tag joined, every tag a space, and as a
  # browser lays it out, inline tags joined and the rest a space, which is the
  # one that reads "Ac<b>me</b><br>Corp" as "Acme Corp".
  def displayed_texts(html)
    as_laid_out = html.gsub(INLINE_TAG, '').gsub(/<[^>]*>/, ' ')
    [html.gsub(/<[^>]*>/, ''), html.gsub(/<[^>]*>/, ' '), as_laid_out].map do |text|
      comparable(CGI.unescapeHTML(text))
    end
  end

  # The form two texts are compared in, so a name copied from app data matches
  # the one typed into a deny list: compatibility characters folded to plain
  # ones (full-width letters, decomposed accents), every character Unicode
  # marks default-ignorable dropped (soft hyphens, zero-width spaces, direction
  # overrides, combining grapheme joiners, variation selectors), every dash
  # and the minus sign made a hyphen, case folded (so "STRASSE" matches
  # "Straße"), and each run of whitespace, non-breaking included, one space.
  def comparable(text)
    text.unicode_normalize(:nfkc).gsub(/\p{Default_Ignorable_Code_Point}/, '').gsub(/[\p{Pd}\u2212]/, '-').downcase(:fold).gsub(/[[:space:]]+/, ' ')
  end

  # The recipient's own identifiers that do not appear. Non-fatal: a missing
  # one suggests the manifest is for the wrong recipient.
  def missing_allow(html, allow)
    found = leaks(html, allow)
    allow.reject { |token| found.key?(token) }
  end

  # Raises SegregationError when any deny token appears; otherwise returns the
  # allow tokens that are missing. A missing or empty deny list raises
  # ManifestError unless segregation.single_client is true: a page checked
  # against nothing looks the same as one whose author forgot the list.
  def check_segregation!(html, segregation)
    segregation ||= {}
    raise ManifestError, 'segregation must be an object with allow and deny lists' unless segregation.is_a?(Hash)

    deny = tokens(segregation, 'deny')
    if deny.empty? && segregation['single_client'] != true
      raise ManifestError, "segregation.deny is empty: list the other tenants' identifiers, " \
                           'or set segregation.single_client to true for a product with one client'
    end

    found = leaks(html, deny)
    raise SegregationError, found unless found.empty?

    missing_allow(html, tokens(segregation, 'allow'))
  end

  # The list under key, each token stripped of surrounding whitespace. A value
  # that is not a list of strings, or a blank token, raises: the first would
  # match nothing and the second every page.
  def tokens(segregation, key)
    list = segregation[key] || []
    unless list.is_a?(Array) && list.all?(String)
      raise ManifestError, "segregation.#{key} must be a list of strings, got #{list.inspect}"
    end

    stripped = list.map(&:strip)
    raise ManifestError, "segregation.#{key} has a blank token" if stripped.any? { |token| comparable(token).strip.empty? }

    stripped
  end

  class CLI
    # How every page this renderer writes begins, which is how discard tells an
    # earlier page from any other file at the output path.
    RENDERED_PREFIX = "<!DOCTYPE html><html><head><meta charset='utf-8'>".b.freeze

    USAGE = 'usage: ruby render_highlights.rb MANIFEST.json [OUT.html]'

    def self.run(argv)
      new.run(argv)
    end

    # Whatever stops a render -- a refusal, a manifest error, a crash -- also
    # removes any page an earlier run left at out_path, since a stale page may
    # carry the very name the run was stopped for.
    def run(argv)
      unless argv.size.between?(1, 2)
        warn USAGE
        exit 2
      end
      manifest_path = argv[0]
      out_path = argv[1] || "#{manifest_path.sub(/\.json\z/, '')}.html"
      raise ManifestError, "the output path is the manifest: #{out_path}" if same_file?(out_path, manifest_path)

      write(manifest_path, out_path)
    rescue ManifestError => e
      discard(out_path)
      abort "render_highlights: #{e.message}"
    rescue SegregationError => e
      discard(out_path)
      warn "REFUSING to write #{out_path}: segregation deny tokens present in HTML:"
      e.leaks.each { |token, count| warn "  - #{token.inspect} (#{count}x)" }
      warn 'Remove the leaked data or correct the manifest, then re-run.'
      exit 1
    rescue SystemCallError => e
      discard(out_path)
      abort "render_highlights: cannot write #{out_path}: #{e.message}"
    rescue StandardError
      discard(out_path)
      raise
    end

    private

    # The same path, or another name for the same file: a case alias on a
    # case-insensitive disk, a symlink, or a hard link.
    def same_file?(out_path, manifest_path)
      File.expand_path(out_path) == File.expand_path(manifest_path) ||
        (File.exist?(out_path) && File.identical?(out_path, manifest_path))
    end

    def write(manifest_path, out_path)
      manifest = load_manifest(manifest_path)
      html = ChangeHighlights.render(manifest, File.dirname(File.expand_path(manifest_path)))
      missing = ChangeHighlights.check_segregation!(html, manifest['segregation'])
      unless missing.empty?
        warn "NOTE: expected allow tokens not found in HTML (is this the right recipient?): #{missing.inspect}"
      end
      File.write(out_path, html)
      puts "wrote #{out_path}"
    end

    # The manifest as a Hash. A file that cannot be read or parsed, or JSON
    # that is not an object, raises ManifestError, which the CLI reports in one
    # line.
    def load_manifest(path)
      manifest = JSON.parse(File.read(path, encoding: 'UTF-8'))
      raise ManifestError, 'the manifest must be a JSON object' unless manifest.is_a?(Hash)

      manifest
    rescue Errno::ENOENT
      raise ManifestError, "manifest not found: #{path}"
    rescue SystemCallError => e
      raise ManifestError, "cannot read #{path}: #{e.message}"
    rescue JSON::ParserError => e
      raise ManifestError, "#{path} is not valid JSON: #{e.message.lines.first.to_s.strip}"
    end

    # Removes out_path only when it is a page this renderer wrote, so a
    # mistyped command cannot delete a manifest or anything else there. A file
    # that cannot be removed is reported without hiding why the render stopped.
    def discard(out_path)
      return unless out_path && File.file?(out_path)
      return unless File.open(out_path, 'rb') { |file| file.read(RENDERED_PREFIX.bytesize) } == RENDERED_PREFIX

      File.delete(out_path)
    rescue SystemCallError => e
      warn "NOTE: could not remove the earlier page at #{out_path}: #{e.message}"
    end
  end
end

ChangeHighlights::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
