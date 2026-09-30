#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for the change-highlights skill's shell scripts: find_chrome.sh
# (the sourced browser-discovery helper) and build_highlights_pdf.sh.
# Candidate browsers are passed explicitly or placed on PATH as fakes,
# so the results never depend on which browsers the machine has.
# Coverage records nothing here: the project measures only bin/*.
# Run: ruby test/change_highlights_builder_test.rb

require_relative 'cli_test_case'
require 'erb'
require 'json'
require 'open3'
require 'tmpdir'

class FindChromeTest < Minitest::Test
  HELPER = File.expand_path('../skills/change-highlights/find_chrome.sh', __dir__)

  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def fake_browser(name)
    path = File.join(@dir, name)
    File.write(path, "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, path)
    path
  end

  def find_chrome(*candidates, env: {})
    script = %(. "$1"; shift; CHROME_CANDIDATES=("$@"); find_chrome)
    Open3.capture3({ 'CHROME' => nil }.merge(env), 'bash', '-c', script, 'bash', HELPER, *candidates)
  end

  def test_returns_the_first_executable_candidate
    browser = fake_browser('cs-fake-browser')
    out, _err, status = find_chrome(File.join(@dir, 'missing'), browser)

    assert_predicate status, :success?
    assert_equal browser, out.chomp
  end

  def test_finds_a_candidate_named_on_path
    fake_browser('brave-browser')
    out, _err, status = find_chrome('no-such-browser', 'brave-browser', env: { 'PATH' => "#{@dir}:/usr/bin:/bin" })

    assert_predicate status, :success?
    assert_equal 'brave-browser', out.chomp
  end

  def test_chrome_env_wins_over_candidates
    chosen = fake_browser('chosen')
    out, _err, status = find_chrome(fake_browser('other'), env: { 'CHROME' => chosen })

    assert_predicate status, :success?
    assert_equal chosen, out.chomp
  end

  def test_a_chrome_env_that_is_not_executable_fails_instead_of_falling_back
    plain_file = File.join(@dir, 'not-a-browser')
    File.write(plain_file, "#!/bin/sh\n")
    File.chmod(0o644, plain_file)
    out, err, status = find_chrome(fake_browser('other'), env: { 'CHROME' => plain_file })

    refute_predicate status, :success?
    assert_empty out
    assert_match(/CHROME is set but not executable/, err)
  end

  # "/Applications/Google Chrome.app" is a directory; the runnable file is
  # inside it.
  def test_a_chrome_env_naming_a_directory_is_rejected
    _out, err, status = find_chrome(fake_browser('other'), env: { 'CHROME' => @dir })

    refute_predicate status, :success?
    assert_match(/CHROME is set but not executable/, err)
  end

  # A bare name is looked up on PATH when the browser runs, so a file of
  # that name in the working directory does not make it runnable.
  def test_a_bare_name_found_only_in_the_working_directory_is_skipped
    fake_browser('cs-fake-browser')
    script = %(. "$1"; CHROME_CANDIDATES=(cs-fake-browser); cd "$2" && find_chrome)
    _out, err, status = Open3.capture3({ 'CHROME' => nil, 'PATH' => '/usr/bin:/bin' }, 'bash', '-c', script, 'bash', HELPER, @dir)

    refute_predicate status, :success?
    assert_match(/set CHROME=/, err)
  end

  # The browser runs as a program, so a shell function of the same name
  # does not count.
  def test_a_shell_function_named_like_a_candidate_is_not_a_browser
    script = %(. "$1"; cs-fake-browser() { :; }; CHROME_CANDIDATES=(cs-fake-browser); find_chrome)
    _out, err, status = Open3.capture3({ 'CHROME' => nil, 'PATH' => '/usr/bin:/bin' }, 'bash', '-c', script, 'bash', HELPER)

    refute_predicate status, :success?
    assert_match(/set CHROME=/, err)
  end

  def test_no_browser_found_fails_with_a_hint
    out, err, status = find_chrome(File.join(@dir, 'missing'), 'no-such-browser')

    refute_predicate status, :success?
    assert_empty out
    assert_match(/set CHROME=/, err)
  end
end

class BuildHighlightsPdfTest < Minitest::Test
  BUILDER = File.expand_path('../skills/change-highlights/build_highlights_pdf.sh', __dir__)
  # Writes a PDF with $FAKE_PDF_PAGES page objects (none at all when the
  # variable is "missing") and logs each run's arguments, one per line,
  # after a "== run" line. FAKE_CHROME_FAILS=all fails every run;
  # FAKE_CHROME_FAILS=new fails the --headless=new run, so the builder
  # retries.
  FAKE_CHROME = <<~'SH'
    #!/bin/sh
    { echo '== run'; printf '%s\n' "$@"; } >> "$FAKE_CHROME_LOG"
    [ "$FAKE_CHROME_FAILS" = all ] && exit 1
    for arg in "$@"; do
      [ "$FAKE_CHROME_FAILS" = new ] && [ "$arg" = --headless=new ] && exit 1
    done
    for arg in "$@"; do
      case "$arg" in --print-to-pdf=*) out="${arg#--print-to-pdf=}" ;; esac
    done
    [ "$FAKE_PDF_PAGES" = missing ] && exit 0
    { printf '<< /Type /Pages /Count %s >>\n' "$FAKE_PDF_PAGES"
      i=0; while [ "$i" -lt "${FAKE_PDF_PAGES#unreadable-}" ]; do printf '<< /Type /Page >>\n'; i=$((i + 1)); done
    } > "$out"
    case "$FAKE_PDF_PAGES" in unreadable-*) chmod 000 "$out" ;; esac
  SH

  def setup
    @dir = Dir.mktmpdir
    @real = File.realpath(@dir)
    @chrome = File.join(@dir, 'fake-chrome')
    File.write(@chrome, FAKE_CHROME)
    File.chmod(0o755, @chrome)
    @log = File.join(@dir, 'chrome.log')
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  # Tests that are not about the segregation gate declare a single-client
  # manifest, which the renderer accepts in place of a deny list.
  def write_manifest(name, manifest)
    path = File.join(@dir, "#{name}.json")
    File.write(path, JSON.dump({ 'segregation' => { 'single_client' => true } }.merge(manifest)))
    path
  end

  def build(*args, pages: 1, fails: nil)
    Open3.capture3(env_for(pages: pages, fails: fails), 'bash', BUILDER, *args)
  end

  def chrome_args = chrome_runs.flatten

  # A PNG at each path, relative ones under the test directory; the renderer
  # accepts only real PNG files.
  def png(*paths)
    paths.each do |path|
      full = File.expand_path(path, @dir)
      FileUtils.mkdir_p(File.dirname(full))
      File.binwrite(full, "\x89PNG\r\n\x1a\n".b)
    end
  end

  # Each browser run's arguments, in order.
  def chrome_runs
    return [] unless File.exist?(@log)

    File.read(@log).split("== run\n").reject(&:empty?).map { |run| run.split("\n") }
  end

  def env_for(pages: 1, fails: nil)
    { 'CHROME' => @chrome, 'FAKE_CHROME_LOG' => @log, 'FAKE_PDF_PAGES' => pages.to_s, 'FAKE_CHROME_FAILS' => fails }
  end

  def test_without_arguments_prints_only_the_header_as_usage_to_stderr
    out, err, status = build

    assert_equal 2, status.exitstatus
    assert_empty out
    assert_match(/build_highlights_pdf\.sh MANIFEST\.json/, err)
    refute_match(/shellcheck|Page count/, err)
  end

  def test_builds_an_html_and_a_pdf_beside_each_manifest
    first = write_manifest('first', 'title' => 'One')
    second = write_manifest('second', 'title' => 'Two')
    out, err, status = build(first, second, pages: 2)

    assert_predicate status, :success?, err
    %w[first second].each do |name|
      assert_path_exists File.join(@dir, "#{name}.html")
      assert_path_exists File.join(@dir, "#{name}.pdf")
    end
    assert_includes chrome_args, "--print-to-pdf=#{File.join(@dir, 'first.pdf')}"
    assert_includes chrome_args, "file://#{@dir}/second.html"
    assert_match(/first\.pdf \(2 pages\)/, out)
  end

  def test_a_segregation_leak_stops_before_the_browser_runs
    manifest = write_manifest('leaky', 'title' => 'For Rival Co', 'segregation' => { 'deny' => ['Rival Co'] })
    _out, err, status = build(manifest)

    refute_predicate status, :success?
    assert_match(/REFUSING to write/, err)
    assert_empty chrome_args
    refute_path_exists File.join(@dir, 'leaky.pdf')
  end

  def test_a_refused_build_removes_the_pdf_and_html_an_earlier_run_wrote
    manifest = write_manifest('leaky', 'title' => 'For Rival Co', 'segregation' => { 'deny' => ['Rival Co'] })
    %w[leaky.pdf leaky.html].each { |name| File.write(File.join(@dir, name), 'from an earlier run') }
    _out, _err, status = build(manifest)

    refute_predicate status, :success?
    refute_path_exists File.join(@dir, 'leaky.pdf')
    refute_path_exists File.join(@dir, 'leaky.html')
  end

  def test_a_refusal_partway_through_removes_every_manifests_earlier_output
    first = write_manifest('first', 'title' => 'One')
    leaky = write_manifest('leaky', 'title' => 'For Rival Co', 'segregation' => { 'deny' => ['Rival Co'] })
    last = write_manifest('last', 'title' => 'Three')
    File.write(File.join(@dir, 'last.pdf'), 'from an earlier run')
    File.write(File.join(@dir, 'last.html'), 'from an earlier run')
    _out, _err, status = build(first, leaky, last)

    refute_predicate status, :success?
    refute_path_exists File.join(@dir, 'last.pdf')
    refute_path_exists File.join(@dir, 'last.html')
  end

  def test_a_manifest_name_starting_with_a_dash_builds_and_is_checked
    png('shot.png')
    write_manifest('-dash', 'title' => 'Dash', 'examples' => [{ 'blocks' => [{ 'type' => 'image', 'src' => 'shot.png' }] }])
    out, err, status = Open3.capture3(env_for(pages: 2), 'bash', BUILDER, '-dash.json', chdir: @dir)

    assert_predicate status, :success?, err
    assert_path_exists File.join(@dir, '-dash.pdf')
    assert_match(/wrote -dash\.pdf \(2 pages\)/, out)
    assert_includes out, File.join(@real, 'shot.png')
    refute_match(/Usage/i, out + err)
  end

  # Run by a relative path, the builder finds its own directory with cd,
  # which an exported CDPATH could send to a same-named directory elsewhere.
  def test_an_exported_cdpath_does_not_move_the_builder
    decoy = File.join(@dir, 'decoy', 'skills', 'change-highlights')
    FileUtils.mkdir_p(decoy)
    File.write(File.join(decoy, 'find_chrome.sh'), "find_chrome() { echo decoy >&2; return 7; }\n")
    manifest = write_manifest('m', 'title' => 'M')
    repo = File.expand_path('..', __dir__)
    _out, err, status = Open3.capture3(env_for.merge('CDPATH' => File.join(@dir, 'decoy')),
                                       'bash', 'skills/change-highlights/build_highlights_pdf.sh', manifest, chdir: repo)

    assert_predicate status, :success?, err
    refute_match(/decoy/, err)
  end

  # The browser decodes a file:// URL, so an unencoded "%41" would print a
  # different file, rA.html, from the one the gate checked.
  def test_the_page_url_is_percent_encoded
    write_manifest('r%41 x', 'title' => 'R')
    File.write(File.join(@dir, 'rA x.html'), '<p>a different page</p>')
    _out, err, status = build(File.join(@dir, 'r%41 x.json'))

    assert_predicate status, :success?, err
    assert_includes chrome_args, "file://#{@dir}/r%2541%20x.html"
  end

  def test_a_page_with_non_ascii_text_builds_under_a_c_locale
    png("Soci\u00E9t\u00E9.png")
    manifest = write_manifest('u', 'title' => "Soci\u00E9t\u00E9 \u2014 changes",
                                   'examples' => [{ 'blocks' => [{ 'type' => 'image', 'src' => "Soci\u00E9t\u00E9.png" }] }])
    out, err, status = Open3.capture3(env_for.merge('LANG' => 'C', 'LC_ALL' => 'C'), 'bash', BUILDER, manifest)

    assert_predicate status, :success?, err
    assert_includes out.b, File.join(@real, "Soci\u00E9t\u00E9.png").b
  end

  # Images are local copies and the page loads nothing else, so the browser
  # prints with a proxy that goes nowhere: no request can leave the machine.
  def test_the_browser_prints_with_no_network
    _out, err, status = build(write_manifest('net', 'title' => 'Net'))

    assert_predicate status, :success?, err
    assert_includes chrome_args, '--proxy-server=127.0.0.1:9'
    assert_includes chrome_args, '--proxy-bypass-list=<-loopback>'
  end

  def test_an_older_browser_prints_with_plain_headless
    out, err, status = build(write_manifest('old', 'title' => 'Old'), fails: 'new')

    assert_predicate status, :success?, err
    assert_equal ['--headless=new', '--headless'], chrome_args.grep(/\A--headless/)
    assert_match(/old\.pdf \(1 page\)/, out)
  end

  def test_a_browser_that_fails_both_ways_fails_the_build
    _out, err, status = build(write_manifest('broken', 'title' => 'Broken'), fails: 'all')

    refute_predicate status, :success?
    assert_equal 2, chrome_args.grep(/\A--headless/).size
    assert_match(/broken\.pdf has no pages/, err)
  end

  # The first manifest passed its own check, so its PDF stands; nothing
  # after the refused one is built.
  def test_a_refusal_partway_keeps_earlier_pdfs_and_builds_nothing_after
    first = write_manifest('first', 'title' => 'One')
    leaky = write_manifest('leaky', 'title' => 'For Rival Co', 'segregation' => { 'deny' => ['Rival Co'] })
    last = write_manifest('last', 'title' => 'Three')
    _out, _err, status = build(first, leaky, last)

    refute_predicate status, :success?
    assert_path_exists File.join(@dir, 'first.pdf')
    refute_path_exists File.join(@dir, 'last.pdf')
  end

  def test_every_print_run_gets_the_network_block_and_the_page
    _out, err, status = build(write_manifest('runs', 'title' => 'Runs'), fails: 'new')

    assert_predicate status, :success?, err
    assert_equal 2, chrome_runs.size
    chrome_runs.each do |run|
      assert_includes run, '--proxy-server=127.0.0.1:9'
      assert_includes run, '--proxy-bypass-list=<-loopback>'
      assert_includes run, '--no-pdf-header-footer'
      assert_includes run, '--print-to-pdf-no-header'
      assert_equal "file://#{@dir.split('/').map { |segment| ERB::Util.url_encode(segment) }.join('/')}/runs.html", run.last
    end
  end

  # The builder deletes MANIFEST's .html and .pdf; a name without .json
  # could make that the manifest itself.
  def test_a_manifest_not_named_json_is_refused_before_anything_is_deleted
    notes = File.join(@dir, 'notes.html')
    File.write(notes, '{"title":"x"}')
    _out, err, status = build(notes)

    assert_equal 1, status.exitstatus
    assert_match(/must end in \.json/, err)
    assert_path_exists notes
    assert_empty chrome_args
  end

  # A PDF whose pages cannot be counted fails like one with none.
  def test_a_pdf_that_cannot_be_read_fails_and_is_removed
    skip 'root can read an unreadable file' if Process.uid.zero?

    _out, err, status = build(write_manifest('locked', 'title' => 'Locked'), pages: 'unreadable-1')

    assert_equal 1, status.exitstatus
    assert_match(/locked\.pdf has no pages/, err)
    refute_path_exists File.join(@dir, 'locked.pdf')
  end

  def test_a_pdf_with_no_pages_fails_and_is_removed
    _out, err, status = build(write_manifest('blank', 'title' => 'Blank'), pages: 0)

    refute_predicate status, :success?
    assert_match(/blank\.pdf has no pages/, err)
    refute_path_exists File.join(@dir, 'blank.pdf')
  end

  def test_a_browser_that_writes_no_pdf_fails
    _out, err, status = build(write_manifest('lost', 'title' => 'Lost'), pages: 'missing')

    refute_predicate status, :success?
    assert_match(/lost\.pdf has no pages/, err)
  end

  # The list names the file the browser loads, as a path a reviewer can
  # open: the page's file:// URLs are decoded back to paths.
  def test_lists_every_image_by_the_path_the_browser_loads
    png('before%41 x.png', 'shots/local.png', 'abs/after.png')
    manifest = write_manifest('shots', 'title' => 'Shots', 'examples' => [{
                                'blocks' => [{ 'type' => 'image', 'src' => 'before%41 x.png' },
                                             { 'type' => 'image', 'src' => "file://#{@real}/shots/local.png" },
                                             { 'type' => 'image_row', 'images' => [{ 'src' => File.join(@dir, 'abs/after.png') }] }]
                              }])
    out, err, status = build(manifest)

    assert_predicate status, :success?, err
    assert_match(/not scanned by the segregation gate/i, out)
    listed = out.lines.map(&:strip)
    ['before%41 x.png', 'shots/local.png', 'abs/after.png'].each do |path|
      assert_includes listed, File.join(@real, path)
    end
  end

  def test_a_missing_manifest_fails_before_the_browser_runs
    _out, err, status = build(File.join(@dir, 'nope.json'))

    refute_predicate status, :success?
    assert_match(/Manifest not found/, err)
    assert_empty chrome_args
  end
end

class SampleManifestTest < Minitest::Test
  SAMPLE = File.expand_path('../skills/change-highlights/examples/sample_manifest.json', __dir__)

  RENDERER = File.expand_path('../skills/change-highlights/render_highlights.rb', __dir__)

  # Through the renderer's CLI, which is where the missing-allow note and a
  # missing-deny refusal come from.
  def test_the_sample_renders_without_warnings_and_passes_its_own_segregation_check
    Dir.mktmpdir do |dir|
      copy = File.join(dir, 'sample.json')
      FileUtils.cp(SAMPLE, copy)
      _out, err, status = Open3.capture3('ruby', RENDERER, copy)

      assert_predicate status, :success?, err
      assert_empty err
      assert_includes File.read(File.join(dir, 'sample.html')), '<tr class="totals"><th>Invoice total</th><td>$450.00</td></tr>'
    end
  end
end
