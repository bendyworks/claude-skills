#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for the change-highlights skill's renderer,
# skills/change-highlights/render_highlights.rb. The file guards its CLI
# behind $PROGRAM_NAME == __FILE__, so loading it here exposes the
# ChangeHighlights module without running the CLI; the CLI tests run it
# as a subprocess, since a refusal ends in exit. The in-process tests put
# the renderer in coverage reports; the project requires coverage only of
# bin/*.
# Run: ruby test/change_highlights_test.rb

require_relative 'cli_test_case'
require 'json'
require 'open3'
require 'tmpdir'

RENDERER = File.expand_path('../skills/change-highlights/render_highlights.rb', __dir__)
load RENDERER

class ChangeHighlightsRenderTest < Minitest::Test
  CH = ChangeHighlights
  PNG = "\x89PNG\r\n\x1a\n\0\0\0\rIHDR".b

  # A temporary directory holding a PNG at each relative path given, yielded
  # as its real path (macOS temp directories sit behind a symlink).
  def with_pngs(*names)
    Dir.mktmpdir do |dir|
      real = File.realpath(dir)
      names.each do |name|
        FileUtils.mkdir_p(File.dirname(File.join(real, name)))
        File.binwrite(File.join(real, name), PNG)
      end
      yield real
    end
  end

  def image(src, dir) = CH.render_block({ 'type' => 'image', 'src' => src }, dir)

  def test_money_groups_thousands_and_signs_negatives
    assert_equal '$1,234,567.89', CH.money(123_456_789)
    assert_equal '-$12.05', CH.money(-1205)
    assert_equal '$0.00', CH.money(nil)
  end

  # Behind the renderer writing every tag itself, the page allows nothing to run
  # and loads nothing but local images.
  def test_the_page_forbids_scripts_and_every_load_but_local_images
    head = CH.render({ 'title' => 'x' }, '/tmp')[%r{<head>.*</head>}m]

    policy = head[/<meta http-equiv="Content-Security-Policy" content="([^"]*)">/, 1]
    assert_equal "default-src 'none'; img-src file:; style-src 'unsafe-inline'", policy
  end

  # discard removes only files that begin this way, so a rendered page that
  # stopped beginning with RENDERED_PREFIX would never be cleaned up.
  def test_every_rendered_page_begins_with_the_prefix_discard_recognizes
    assert CH.render({ 'title' => 'x' }, '/tmp').b.start_with?(CH::CLI::RENDERED_PREFIX)
  end

  def test_examples_blocks_rows_and_images_must_be_lists_of_objects
    [{ 'examples' => ['x'] }, { 'examples' => { 'a' => 1 } }, { 'examples' => [{ 'blocks' => [5] }] },
     { 'examples' => [{ 'blocks' => [{ 'type' => 'amount_table', 'rows' => ['x'] }] }] },
     { 'examples' => [{ 'blocks' => [{ 'type' => 'image_row', 'images' => 'a.png' }] }] }].each do |manifest|
      error = assert_raises(CH::ManifestError, manifest.inspect) { CH.render(manifest, '/m') }
      assert_match(/must be a list of objects/, error.message, manifest.inspect)
    end
  end

  def test_a_lone_bullet_list_is_text
    assert_includes CH.render({ 'intro' => { 'list' => %w[a b] } }, '/tmp'), '<div class="intro"><ul><li>a</li><li>b</li></ul></div>'
  end

  # Amounts are whole cents: a string or a fraction would otherwise crash or
  # be rounded without a word.
  def test_an_amount_that_is_not_whole_cents_is_refused
    ['1250', 12.5, true].each do |cents|
      assert_raises(CH::ManifestError, cents.inspect) { CH.money(cents) }
    end
  end

  def test_an_image_without_a_src_is_refused
    [{ 'type' => 'image', 'caption' => 'x' }, { 'type' => 'image_row', 'images' => [{ 'caption' => 'x' }] }].each do |block|
      error = assert_raises(CH::ManifestError, block.inspect) { CH.render_block(block, '/m') }
      assert_match(/image has no src/, error.message)
    end
  end

  def test_all_manifest_text_is_escaped_and_bold_is_the_only_markup
    html = CH.render({ 'title' => 'A < B', 'intro' => "x <b>y</b> **z** & AT&T, **two\nlines**, a ** alone" }, '/tmp')

    assert_includes html, '<h1>A &lt; B</h1>'
    assert_includes html, "<p>x &lt;b&gt;y&lt;/b&gt; <b>z</b> &amp; AT&amp;T, <b>two\nlines</b>, a ** alone</p>"
  end

  def test_comparison_table_bolds_only_the_cells_that_changed
    html = CH.comparison_table('rows' => [
                                 { 'label' => 'Same', 'before_cents' => 100, 'after_cents' => 100 },
                                 { 'label' => 'Moved', 'before_cents' => 100, 'after_cents' => 250 }
                               ])

    assert_includes html, '<td class="after-col">$1.00</td>'
    assert_includes html, '<td class="after-col changed">$2.50</td>'
  end

  def test_amount_table_total_sums_every_row_shown_including_informational_ones
    html = CH.amount_table('rows' => [
                             { 'label' => 'Fee', 'amount_cents' => 1000 },
                             { 'label' => 'Credit', 'amount_cents' => -300, 'info' => 'not billed' }
                           ])

    assert_includes html, '<span class="info">(not billed)</span>'
    assert_includes html, '<tr class="totals"><th>Total</th><td>$7.00</td></tr>'
  end

  def test_amount_table_column_headers_come_from_the_block
    html = CH.amount_table('label_header' => 'Charge', 'amount_header' => 'Cost',
                           'rows' => [{ 'label' => 'Fee', 'amount_cents' => 1 }])

    assert_includes html, '<thead><tr><th>Charge</th><th>Cost</th></tr></thead>'
  end

  def test_amount_table_column_headers_default_to_description_and_amount
    html = CH.amount_table('rows' => [{ 'label' => 'Fee', 'amount_cents' => 1 }])

    assert_includes html, '<thead><tr><th>Description</th><th>Amount</th></tr></thead>'
  end

  def test_currency_symbol_comes_from_the_manifest
    html = CH.render({ 'currency_symbol' => '€', 'examples' => [{ 'blocks' => [
                       { 'type' => 'comparison_table',
                         'rows' => [{ 'label' => 'Due', 'before_cents' => 100_000, 'after_cents' => -50 }] },
                       { 'type' => 'amount_table', 'rows' => [{ 'label' => 'Fee', 'amount_cents' => 250 }] }
                     ] }] }, '/tmp')

    assert_includes html, '€1,000.00'
    assert_includes html, '-€0.50'
    assert_includes html, '<td>€2.50</td>'
    refute_includes html, '$'
  end

  def test_amount_table_with_no_rows_shows_the_empty_note
    assert_includes CH.amount_table('rows' => [], 'empty_note' => 'None yet.'), '<p class="info">None yet.</p>'
  end

  def test_an_image_row_puts_its_images_side_by_side
    with_pngs('a.png', 'b.png') do |dir|
      html = CH.render_block({ 'type' => 'image_row', 'images' => [{ 'src' => 'a.png', 'caption' => 'Before' },
                                                                   { 'src' => 'b.png', 'caption' => 'After' }] }, dir)

      assert_equal %(<div class="image-row"><figure><img src="file://#{dir}/a.png" alt="Before"><figcaption>Before</figcaption></figure>) +
                   %(<figure><img src="file://#{dir}/b.png" alt="After"><figcaption>After</figcaption></figure></div>), html
    end
  end

  def test_image_src_resolves_against_the_manifest_directory
    with_pngs('shots/after.png') do |dir|
      assert_includes image('shots/after.png', dir), %(src="file://#{dir}/shots/after.png")
    end
  end

  # The browser decodes a file:// URL, so a path written into the page as
  # is would load "Cont%6Fso.png" as Contoso.png, a different file from the
  # one the gate and the review list name. Each segment is encoded, and a
  # file: source is decoded to its path first, without its host, query, or
  # fragment.
  def test_an_image_source_becomes_a_percent_encoded_file_url
    with_pngs('shots/Cont%6Fso.png', 'abs/a b#1?.png', 'aA.png', 'b.png', '~/x.png', 'c.png', 'd.png') do |dir|
      { 'shots/Cont%6Fso.png' => "file://#{dir}/shots/Cont%256Fso.png",
        "#{dir}/abs/a b#1?.png" => "file://#{dir}/abs/a%20b%231%3F.png",
        "file://#{dir}/a%41.png" => "file://#{dir}/aA.png",
        "FILE://#{dir}/b.png" => "file://#{dir}/b.png",
        '~/x.png' => "file://#{dir}/~/x.png",
        "file://localhost#{dir}/c.png" => "file://#{dir}/c.png",
        "file://#{dir}/d.png?v=2#top" => "file://#{dir}/d.png" }.each do |src, url|
        assert_includes image(src, dir), %(src="#{url}"), src
      end
    end
  end

  # The file the browser loads is the one checked: symlinks are followed,
  # and only a PNG, by its first bytes, is accepted. An SVG's text would
  # print as PDF text the gate never reads; a JPEG is copied into the PDF
  # whole, metadata included; a data: source leaves no file to review.
  def test_only_a_real_png_file_is_accepted
    with_pngs('ok.png') do |dir|
      File.write(File.join(dir, 'logo.svg'), '<svg xmlns="http://www.w3.org/2000/svg"><text>Rival</text></svg>')
      File.symlink(File.join(dir, 'logo.svg'), File.join(dir, 'link.png'))
      File.binwrite(File.join(dir, 'photo.png'), "\xFF\xD8\xFF\xE0".b)
      FileUtils.mkdir(File.join(dir, 'folder.png'))
      { 'logo.svg' => /not a PNG/, 'link.png' => /logo\.svg is not a PNG/, 'photo.png' => /not a PNG/,
        'folder.png' => /not a file/, 'missing.png' => /image not found/, 'file:ok.png' => /no absolute path/,
        "file://#{dir}/%FF.png" => /not UTF-8/, ' ' => /empty src/, 'data:image/png;base64,iVBORw0KGgo=' => /data: URI/,
        'DATA:image/svg+xml,%3Csvg%3E' => /data: URI/ }.each do |src, message|
        error = assert_raises(CH::ManifestError, src) { image(src, dir) }
        assert_match(message, error.message, src)
      end
      assert_includes image('ok.png', dir), %(src="file://#{dir}/ok.png")
    end
  end

  # A mistyped block type would otherwise drop a whole table from a client's
  # PDF with only a line of build output to say so.
  def test_an_unknown_block_type_is_refused
    error = assert_raises(CH::ManifestError) { CH.render_block({ 'type' => 'comparision_table' }, '/tmp') }
    assert_match(/unknown block type "comparision_table"/, error.message)
  end

  def test_deny_tokens_match_case_insensitively_with_counts
    assert_equal({ 'Rival Co' => 2 }, CH.leaks('<p>RIVAL CO and rival co</p>', ['Rival Co', 'Absent']))
  end

  # Matching is by substring, so a short deny token also matches inside
  # longer words. Authors choose distinctive tokens; the gate does not
  # guess at word boundaries.
  def test_a_short_deny_token_matches_inside_a_longer_word
    assert_equal({ 'Ace' => 1 }, CH.leaks('<p>Replace</p>', ['Ace']))
  end

  # A deny token counts as leaked when a reader would see it on the page,
  # whatever markup carries it there.
  def test_a_token_with_html_special_characters_leaks_after_escaping
    html = CH.render({ 'title' => "A&B Motors and O'Brien Co" }, '/tmp')

    assert_equal ['A&B Motors', "O'Brien Co"], CH.leaks(html, ['A&B Motors', "O'Brien Co"]).keys
  end

  def test_a_token_split_by_inline_tags_leaks
    assert_equal({ 'Rival Co' => 1 }, CH.leaks('<p>Riv<b>al</b> Co</p>', ['Rival Co']))
  end

  def test_a_token_split_by_a_line_break_tag_leaks
    assert_equal({ 'Rival Co' => 1 }, CH.leaks('<p>Rival<br>Co</p>', ['Rival Co']))
  end

  def test_a_token_split_by_an_inline_tag_and_a_line_break_at_once_leaks
    assert_equal({ 'Acme Corp' => 1 }, CH.leaks('<p>Ac<b>me</b><br>Corp</p>', ['Acme Corp']))
  end

  def test_a_token_written_with_character_entities_leaks
    assert_equal({ 'Rival Co' => 1 }, CH.leaks('<p>&#82;ival&#x20;Co</p>', ['Rival Co']))
  end

  def test_a_token_joined_by_a_non_breaking_space_leaks
    assert_equal({ 'Rival Co' => 1 }, CH.leaks("<p>Rival\u00A0Co</p>", ['Rival Co']))
  end

  def test_a_token_wrapped_across_lines_leaks
    assert_equal({ 'Rival Co' => 1 }, CH.leaks("<p>Rival\n   Co</p>", ['Rival Co']))
  end

  def test_a_deny_list_that_is_not_a_list_of_strings_is_refused
    [{ 'a' => 'Rival' }, [['Rival Co']], 'Rival Co', [42]].each do |deny|
      assert_raises(CH::ManifestError, deny.inspect) do
        CH.check_segregation!('<p>Rival Co</p>', 'deny' => deny)
      end
    end
  end

  def test_a_blank_token_is_refused_rather_than_matching_every_page
    ['', '   '].each do |token|
      error = assert_raises(CH::ManifestError) { CH.check_segregation!('<p>x</p>', 'deny' => ['Rival', token]) }
      assert_match(/blank/, error.message)
    end
    assert_raises(CH::ManifestError) { CH.check_segregation!('<p>x</p>', 'allow' => ['']) }
  end

  def test_a_token_of_only_invisible_characters_is_blank
    ["\u200B", "\u00A0", "\u00AD", " \u200D "].each do |token|
      error = assert_raises(CH::ManifestError, token.inspect) { CH.check_segregation!('<p>x</p>', 'deny' => [token]) }
      assert_match(/blank/, error.message)
    end
  end

  def test_segregation_that_is_not_an_object_is_refused
    [['Rival Co'], 'Rival Co'].each do |segregation|
      assert_raises(CH::ManifestError, segregation.inspect) { CH.check_segregation!('<p>Rival Co</p>', segregation) }
    end
  end

  def test_surrounding_whitespace_on_a_token_is_ignored
    assert_raises(CH::SegregationError) do
      CH.check_segregation!('<p>Signed, Rival Co.</p>', 'deny' => [' Rival Co '])
    end
  end

  # A manifest written for the raw-HTML fields would otherwise print without
  # that content.
  def test_retired_raw_html_fields_are_refused_with_their_replacements
    { { 'intro_html' => '<p>x</p>' } => /intro_html with intro/,
      { 'examples' => [{ 'explanation_html' => '<p>x</p>' }] } => /explanation_html with explanation/,
      { 'examples' => [{ 'blocks' => [{ 'type' => 'html', 'content' => '<p>x</p>' }] }] } => /html block with text block/ }
      .each do |manifest, message|
        error = assert_raises(CH::ManifestError) { CH.render(manifest, '/tmp') }
        assert_match(message, error.message)
      end
  end

  def test_several_retired_fields_are_named_once_each
    manifest = { 'examples' => [{ 'explanation_html' => 'a' }, { 'explanation_html' => 'b' },
                                { 'blocks' => [{ 'type' => 'html' }, { 'type' => 'html' }] }] }
    error = assert_raises(CH::ManifestError) { CH.render(manifest, '/tmp') }

    assert_equal 1, error.message.scan('explanation_html with explanation').size
    assert_equal 1, error.message.scan('html block with text block').size
  end

  def test_text_takes_paragraphs_and_bullet_lists
    html = CH.render({ 'intro' => ['one', { 'list' => ['a', '**b**'] }],
                       'examples' => [{ 'explanation' => 'why', 'blocks' => [{ 'type' => 'text', 'content' => 'more' }] }] },
                     '/tmp')

    assert_includes html, '<div class="intro"><p>one</p><ul><li>a</li><li><b>b</b></li></ul></div>'
    assert_includes html, '<div class="explain"><p>why</p></div>'
    assert_includes html, '<div class="text"><p>more</p></div>'
  end

  def test_text_that_is_not_paragraphs_or_lists_is_refused
    [42, [{ 'list' => 'a' }], [{ 'list' => ['a'], 'style' => 'x' }], [['a']]].each do |value|
      assert_raises(CH::ManifestError, value.inspect) { CH.render({ 'intro' => value }, '/tmp') }
    end
  end

  # Names copied from app data or a database often carry invisible or
  # compatibility characters a reader never notices.
  def test_a_token_disguised_by_invisible_or_look_alike_characters_leaks
    {
      "<p>Ri­val Co</p>" => 'Rival Co',          # soft hyphen
      "<p>Ri​val Co</p>" => 'Rival Co',          # zero-width space
      '<p>Ri&#8203;val Co</p>' => 'Rival Co',
      "<p>Rival\u2002Co</p>" => 'Rival Co',          # en space
      "<p>Rival\u2009Co</p>" => 'Rival Co',          # thin space
      "<p>Société Rivale</p>" => "Société Rivale", # decomposed accent
      "<p>Ｒｉｖａｌ Co</p>" => 'Rival Co', # full-width letters
      '<p>North&#8209;West Co</p>' => 'North-West Co', # non-breaking hyphen
      "<p>North\u2013West Co</p>" => 'North-West Co', # en dash
      "<p>North\u2212West Co</p>" => 'North-West Co', # minus sign
      "<p>‮Rival Co‬</p>" => 'Rival Co',    # bidi override
      "<p>Ri\u034Fval Co</p>" => 'Rival Co',          # combining grapheme joiner
      "<p>Ri\uFE0Fval Co</p>" => 'Rival Co',          # variation selector
      "<p>Ri\u{E0100}val Co</p>" => 'Rival Co',       # supplementary variation selector
      "<p>Straße Holdings</p>" => 'STRASSE Holdings'
    }.each do |html, token|
      assert_equal [token], CH.leaks(html, [token]).keys, html.inspect
    end
  end

  def test_an_allow_token_with_html_special_characters_is_found
    html = CH.render({ 'title' => "AT&T and O'Brien Co" }, '/tmp')

    assert_empty CH.missing_allow(html, ['AT&T', "O'Brien Co"])
  end

  def test_a_token_in_a_file_url_is_found_decoded
    with_pngs('Rival Co.png') do |dir|
      html = CH.render({ 'examples' => [{ 'blocks' => [{ 'type' => 'image', 'src' => "file://#{dir}/Rival%20Co.png" }] }] }, dir)

      assert_equal ['Rival Co'], CH.leaks(html, ['Rival Co']).keys
    end
  end

  # A remote image can change between review and print, and fetching it
  # tells its host when a recipient's page was built.
  def test_remote_and_protocol_relative_sources_are_refused
    ['https://cdn.example.com/a.png', 'http://cdn.example.com/a.png', 'HTTPS://cdn.example.com/a.png',
     '//cdn.example.com/a.png'].each do |src|
      error = assert_raises(CH::ManifestError, src) { CH.render_block({ 'type' => 'image', 'src' => src }, '/m') }
      assert_match(/download/, error.message)
    end
  end

  # The renderer's own stylesheet and class names are not page text.
  def test_the_built_in_stylesheet_matches_no_token
    assert_empty CH.leaks(CH.render({ 'title' => 'x' }, '/tmp'), %w[Apple Block Arial Letter Flex])
  end

  def test_the_renderers_class_names_match_no_token
    html = CH.render({ 'title' => 'x', 'examples' => [{ 'explanation' => 'e', 'blocks' => [
                       { 'type' => 'comparison_table', 'rows' => [{ 'label' => 'r', 'before_cents' => 1, 'after_cents' => 2 }] }
                     ] }] }, '/tmp')

    assert_empty CH.leaks(html, %w[Changed Explain Card Intro])
  end

  def test_the_title_is_searched
    assert_equal ['Apple'], CH.leaks(CH.render({ 'title' => 'Apple' }, '/tmp'), ['Apple']).keys
  end

  def test_a_missing_amount_and_zero_are_not_marked_changed
    html = CH.comparison_table('rows' => [{ 'label' => 'r', 'before_cents' => nil, 'after_cents' => 0 }])

    refute_includes html, 'changed'
  end

  # An image path never prints, but a file named for another tenant is worth
  # refusing.
  def test_a_token_in_an_image_path_leaks
    with_pngs('shots/rival-co.png') do |dir|
      html = CH.render({ 'examples' => [{ 'blocks' => [{ 'type' => 'image', 'src' => 'shots/rival-co.png' }] }] }, dir)

      assert_equal ['rival-co'], CH.leaks(html, ['rival-co']).keys
    end
  end

  def test_check_segregation_raises_with_every_leaked_token
    error = assert_raises(CH::SegregationError) do
      CH.check_segregation!('<p>Rival and Other</p>', 'deny' => %w[Rival Other])
    end
    assert_equal({ 'Rival' => 1, 'Other' => 1 }, error.leaks)
  end

  def test_check_segregation_returns_missing_allow_tokens_without_raising
    assert_equal ['Own Co'], CH.check_segregation!('<p>nothing</p>', 'allow' => ['Own Co'], 'deny' => ['Rival Co'])
  end

  # A manifest without a deny list looks the same as one whose author forgot
  # it, so only an explicit single_client: true lets a page through unchecked.
  def test_a_missing_or_empty_deny_list_is_refused_unless_single_client
    [nil, {}, { 'deny' => [] }, { 'allow' => ['Own Co'] }, { 'single_client' => 'yes' }, { 'single_client' => false }].each do |segregation|
      error = assert_raises(CH::ManifestError, segregation.inspect) { CH.check_segregation!('<p>x</p>', segregation) }
      assert_match(/single_client/, error.message)
    end
    assert_empty CH.check_segregation!('<p>x</p>', 'single_client' => true)
  end
end

# The renderer runs under whatever `ruby` is on the installer's PATH,
# which on macOS without a version manager is the system Ruby 2.6.
class ChangeHighlightsRubyVersionTest < Minitest::Test
  SYSTEM_RUBY = '/usr/bin/ruby'

  def test_the_renderer_uses_no_endless_method_definitions
    endless = File.readlines(RENDERER, encoding: 'UTF-8').grep(/^\s*def [\w.!?]+(\([^)]*\))? =[^=~]/)

    assert_empty endless, 'endless defs need Ruby 3.0; the system Ruby on macOS is 2.6'
  end

  # Renders a manifest using every block type, not just a syntax check, so a
  # newer core method on any of those paths fails here too.
  def test_the_renderer_renders_under_the_macos_system_ruby
    skip 'no Ruby 2.x at /usr/bin/ruby' unless File.executable?(SYSTEM_RUBY) && `#{SYSTEM_RUBY} -e 'print RUBY_VERSION'`.start_with?('2.')

    Dir.mktmpdir do |dir|
      path = File.join(dir, 'm.json')
      ['a b.png', 'd.png'].each { |name| File.binwrite(File.join(dir, name), "\x89PNG\r\n\x1a\n".b) }
      File.write(path, JSON.dump('title' => "Soci\u00E9t\u00E9", 'intro' => ['a **b**', { 'list' => ['c'] }],
                                 'segregation' => { 'deny' => ["Stra\u00DFe Rival"] },
                                 'examples' => [{ 'explanation' => 'why', 'blocks' => [
                                   { 'type' => 'amount_table', 'rows' => [{ 'label' => 'x', 'amount_cents' => 125_000, 'info' => 'i' }] },
                                   { 'type' => 'comparison_table', 'rows' => [{ 'label' => 'y', 'before_cents' => 1, 'after_cents' => 2 }] },
                                   { 'type' => 'image', 'src' => 'a b.png', 'caption' => 'c' },
                                   { 'type' => 'image_row', 'images' => [{ 'src' => "file://#{File.join(dir, 'd.png')}" }] },
                                   { 'type' => 'text', 'content' => ['t', { 'list' => ['u'] }] }
                                 ] }]))
      _out, err, status = Open3.capture3(SYSTEM_RUBY, RENDERER, path)

      assert_predicate status, :success?, err
      assert_includes File.read(File.join(dir, 'm.html'), encoding: 'UTF-8'), '$1,250.00'
    end
  end
end

class ChangeHighlightsCliTest < Minitest::Test
  def run_renderer(manifest)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'recipient.json')
      File.write(path, JSON.dump(manifest))
      _out, err, status = Open3.capture3('ruby', RENDERER, path)
      yield err, status, File.join(dir, 'recipient.html')
    end
  end

  def test_a_wrong_argument_count_prints_usage_and_exits_2
    [[], %w[a.json b.html c]].each do |args|
      _out, err, status = Open3.capture3('ruby', RENDERER, *args)

      assert_equal 2, status.exitstatus, args.inspect
      assert_match(/usage: ruby render_highlights\.rb MANIFEST\.json \[OUT\.html\]/, err)
    end
  end

  def test_a_missing_or_unreadable_manifest_ends_in_one_line_not_a_backtrace
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'bad.json'), '{ not json')
      File.write(File.join(dir, 'list.json'), '["not", "an object"]')
      { File.join(dir, 'missing.json') => /\Arender_highlights: manifest not found: .*missing\.json/,
        File.join(dir, 'bad.json') => /\Arender_highlights: .*bad\.json is not valid JSON/,
        File.join(dir, 'list.json') => /\Arender_highlights: the manifest must be a JSON object/ }.each do |path, message|
        _out, err, status = Open3.capture3('ruby', RENDERER, path)

        assert_equal 1, status.exitstatus, path
        assert_match(message, err)
        refute_match(/\.rb:\d+:in /, err)
      end
    end
  end

  def test_a_leak_writes_no_file_and_exits_non_zero
    run_renderer('title' => 'For Own Co', 'intro' => 'Compared with Rival Co',
                 'segregation' => { 'deny' => ['Rival Co'] }) do |err, status, html_path|
      assert_equal 1, status.exitstatus
      assert_match(/REFUSING to write .*recipient\.html/, err)
      assert_match(/"Rival Co" \(1x\)/, err)
      refute_path_exists html_path
    end
  end

  def test_a_refusal_removes_the_html_an_earlier_run_wrote
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'recipient.json')
      html_path = File.join(dir, 'recipient.html')
      File.write(html_path, "<!DOCTYPE html><html><head><meta charset='utf-8'><title>earlier run</title></head></html>")
      File.write(path, JSON.dump('title' => 'Rival Co', 'segregation' => { 'deny' => ['Rival Co'] }))
      _out, _err, status = Open3.capture3('ruby', RENDERER, path)

      assert_equal 1, status.exitstatus
      refute_path_exists html_path
    end
  end

  # A refused manifest and a crash in the middle of a render both remove the
  # page an earlier run left. The crash is forced by a preloaded file that
  # makes JSON.parse raise, since every manifest problem is a ManifestError.
  def test_a_manifest_error_or_crash_removes_the_html_an_earlier_run_wrote
    Dir.mktmpdir do |dir|
      crash = File.join(dir, 'crash.rb')
      File.write(crash, "require 'json'\nmodule JSON; def self.parse(*) = raise('boom'); end\n")
      { 'refused' => [JSON.dump('title' => 'x', 'intro_html' => '<p>x</p>'), []],
        'crashed' => [JSON.dump('title' => 'x'), ['-r', crash]] }.each do |label, (contents, preload)|
        path = File.join(dir, "#{label}.json")
        html_path = File.join(dir, "#{label}.html")
        File.write(html_path, ChangeHighlights.render({ 'title' => 'earlier run' }, dir))
        File.write(path, contents)
        _out, err, status = Open3.capture3('ruby', *preload, RENDERER, path)

        assert_equal 1, status.exitstatus, label
        refute_path_exists html_path, label
        assert_match(/boom/, err) if label == 'crashed'
      end
    end
  end

  # Only an earlier page is removed: a mistyped command must never delete
  # the author's manifest or anything else at the output path.
  def test_a_failed_render_never_deletes_a_file_that_is_not_an_earlier_page
    Dir.mktmpdir do |dir|
      manifest = File.join(dir, 'm.json')
      page = File.join(dir, 'm.html')
      File.write(manifest, JSON.dump('title' => 'x'))
      File.write(page, "<!DOCTYPE html><html><head><meta charset='utf-8'><title>x</title></head></html>")
      swapped = Open3.capture3('ruby', RENDERER, page, manifest)
      File.write(File.join(dir, 'bad.json'), '{ not json')
      same = Open3.capture3('ruby', RENDERER, File.join(dir, 'bad.json'),
                            File.join(dir, 'bad.json'))

      refute_predicate swapped[2], :success?
      assert_path_exists manifest
      refute_predicate same[2], :success?
      assert_match(/output path is the manifest/, same[1])
      assert_path_exists File.join(dir, 'bad.json')
    end
  end

  def test_a_refusal_is_reported_even_when_the_old_page_cannot_be_removed
    skip 'root can remove files from a read-only directory' if Process.uid.zero?

    Dir.mktmpdir do |dir|
      path = File.join(dir, 'm.json')
      File.write(path, JSON.dump('title' => 'Rival Co', 'segregation' => { 'deny' => ['Rival Co'] }))
      locked = File.join(dir, 'locked')
      FileUtils.mkdir(locked)
      File.write(File.join(locked, 'out.html'), ChangeHighlights.render({ 'title' => 'earlier run' }, dir))
      File.chmod(0o555, locked)
      begin
        _out, err, status = Open3.capture3('ruby', RENDERER, path, File.join(locked, 'out.html'))
      ensure
        File.chmod(0o755, locked)
      end

      assert_equal 1, status.exitstatus
      assert_match(/could not remove the earlier page/, err)
      assert_match(/REFUSING to write/, err)
      refute_match(/\.rb:\d+:in /, err)
    end
  end

  # Scheduled jobs and minimal CI shells often run with no locale, where
  # Ruby's default encoding is US-ASCII.
  def test_a_utf8_manifest_renders_under_a_c_locale
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'm.json')
      File.write(path, JSON.dump('title' => "Soci\u00E9t\u00E9 \u2014 changes", 'segregation' => { 'deny' => ["Caf\u00E9 Rival"] }))
      _out, err, status = Open3.capture3({ 'LANG' => 'C', 'LC_ALL' => 'C' },
                                         'ruby', RENDERER, path)

      assert_predicate status, :success?, err
      assert_includes File.read(File.join(dir, 'm.html'), encoding: 'UTF-8'), "Soci\u00E9t\u00E9"
    end
  end

  def test_an_output_path_that_is_the_manifest_under_another_name_is_refused
    Dir.mktmpdir do |dir|
      manifest = File.join(dir, 'm.json')
      File.write(manifest, JSON.dump('title' => 'x'))
      File.symlink(manifest, File.join(dir, 'link.html'))
      _out, err, status = Open3.capture3('ruby', RENDERER, manifest, File.join(dir, 'link.html'))

      assert_equal 1, status.exitstatus
      assert_match(/output path is the manifest/, err)
      assert_equal JSON.dump('title' => 'x'), File.read(manifest)
    end
  end

  def test_an_unwritable_output_path_ends_in_one_line
    Dir.mktmpdir do |dir|
      manifest = File.join(dir, 'm.json')
      File.write(manifest, JSON.dump('title' => 'x', 'segregation' => { 'single_client' => true }))
      FileUtils.mkdir(File.join(dir, 'out.html'))
      _out, err, status = Open3.capture3('ruby', RENDERER, manifest, File.join(dir, 'out.html'))

      assert_equal 1, status.exitstatus
      assert_match(/^render_highlights: cannot write .*out\.html/, err)
      refute_match(/\.rb:\d+:in /, err)
    end
  end

  # The earlier page may carry the very name the new run was refused for.
  def test_a_failed_write_removes_the_page_an_earlier_run_left
    Dir.mktmpdir do |dir|
      manifest = File.join(dir, 'm.json')
      page = File.join(dir, 'm.html')
      File.write(page, ChangeHighlights.render({ 'title' => 'For Rival Co' }, dir))
      File.chmod(0o444, page)
      File.write(manifest, JSON.dump('title' => 'Clean', 'segregation' => { 'deny' => ['Rival Co'] }))
      _out, err, status = Open3.capture3('ruby', RENDERER, manifest)

      assert_equal 1, status.exitstatus
      assert_match(/cannot write/, err)
      refute_path_exists page
    end
  end

  def test_a_malformed_deny_list_writes_no_file_and_exits_non_zero
    run_renderer('title' => 'Rival Co', 'segregation' => { 'deny' => { 'tenant' => 'Rival Co' } }) do |err, status, html_path|
      assert_equal 1, status.exitstatus
      assert_match(/segregation\.deny must be a list of strings/, err)
      refute_path_exists html_path
    end
  end

  def test_a_retired_field_writes_no_file_and_exits_non_zero
    run_renderer('title' => 'Hello', 'intro_html' => '<p>x</p>', 'segregation' => { 'deny' => ['Rival Co'] }) do |err, status, html_path|
      assert_equal 1, status.exitstatus
      assert_match(/\Arender_highlights: raw HTML is no longer accepted: replace intro_html with intro/, err)
      refute_path_exists html_path
    end
  end

  def test_a_manifest_without_a_deny_list_writes_no_file_and_exits_non_zero
    run_renderer('title' => 'Hello') do |err, status, html_path|
      assert_equal 1, status.exitstatus
      assert_match(/\Arender_highlights: segregation\.deny is empty/, err)
      refute_path_exists html_path
    end
  end

  def test_a_single_client_manifest_writes_its_page_without_a_warning
    run_renderer('title' => 'Hello', 'segregation' => { 'single_client' => true }) do |err, status, html_path|
      assert_predicate status, :success?, err
      assert_empty err
      assert_path_exists html_path
    end
  end

  def test_a_clean_manifest_writes_the_file_and_notes_missing_allow_tokens
    run_renderer('title' => 'Hello', 'segregation' => { 'allow' => ['Own Co'], 'deny' => ['Rival Co'] }) do |err, status, html_path|
      assert_predicate status, :success?
      assert_match(/expected allow tokens not found.*Own Co/, err)
      assert_path_exists html_path
    end
  end
end
