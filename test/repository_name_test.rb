#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests that the repository's name is stated consistently. The plugin
# manifest's `repository` URL is the one place the name is declared; every
# tracked skill template's first line (after any shebang) names it as
# provenance, and the repository's former name (FORMER_SLUG) appears only
# in the files FORMER_NAME_FILES lists, each time in a paragraph or list
# item that calls it the former name. GitHub redirects the former name
# only while no new repository in the org takes it, so a stray link to it
# can break without warning. FORMER_SLUG is assembled from its parts so
# this file never spells it out. Coverage records nothing here: the
# project measures only bin/*. Run: ruby test/repository_name_test.rb

require_relative 'cli_test_case'
require 'json'
require 'open3'

class RepositoryNameTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  FORMER_SLUG = %w[bendyworks claude-skills].join('/')
  FORMER_NAME_FILES = %w[README.md CLAUDE.md CONTRIBUTING.md].freeze
  TEMPLATE_PATH = %r{\Askills/([^/]+)/templates/}
  GITHUB_URL = %r{\Ahttps://github\.com/([^/?#]+/[^/?#]+?)(?:\.git)?/?\z}i
  # A list item (bulleted, numbered, or quoted) or a table row.
  BLOCK_START = /\A\s*(?:>\s*)*(?:[-*+]\s|\d+[.)]\s|\|)/
  FORMER_NAME = /(?<![\w.-])#{Regexp.escape(FORMER_SLUG)}(?![\w-])/i

  def slug
    url = JSON.parse(File.read(File.join(ROOT, '.claude-plugin/plugin.json'))).fetch('repository')
    match = url.match(GITHUB_URL)
    flunk "plugin.json repository is not a GitHub repository URL: #{url}" unless match
    match[1]
  end

  def tracked_files
    out, status = Open3.capture2('git', 'ls-files', '-z', chdir: ROOT)
    assert status.success?, 'git ls-files failed'
    files = out.split("\0")
    assert_includes files, 'test/repository_name_test.rb', 'git ls-files did not list this repository'
    files.select { |file| File.file?(File.join(ROOT, file)) }
  end

  # Blank lines end a paragraph, and each list item or table row starts a
  # new one, so the word "former" in one does not cover a link in the next.
  def paragraphs(text)
    text.each_line.with_index(1).slice_when do |(line, _), (following, _)|
      line.strip.empty? || following.match?(BLOCK_START)
    end
  end

  def test_a_header_naming_a_skill_with_non_ascii_letters_is_recognized
    assert template_header?('café', "# café template v1 (bendyworks/rules-that-bend)\n".b, 'bendyworks/rules-that-bend')
    refute template_header?('café', "\xff\xfe".b, 'bendyworks/rules-that-bend')
  end

  # Built as bytes so a skill name with non-ASCII letters and a binary
  # template's first line compare without an encoding error.
  def template_header?(skill, line, repository)
    header = "\\A(?:#|<!--) #{Regexp.escape(skill)} template v\\d+ \\(#{Regexp.escape(repository)}\\)"
    line.b.match?(Regexp.new(header.b))
  end

  def test_the_manifest_names_a_repository_other_than_the_former_one
    refute_equal FORMER_SLUG, slug.downcase, 'plugin.json repository still names the former repository'
  end

  def test_every_template_names_the_repository_on_its_first_line
    repository = slug
    templates = tracked_files.grep(TEMPLATE_PATH)
    refute_empty templates
    unmarked = templates.reject do |file|
      lines = File.binread(File.join(ROOT, file)).each_line.to_a
      lines.shift if lines.first&.start_with?('#!')
      template_header?(file[TEMPLATE_PATH, 1], lines.first.to_s, repository)
    end
    assert_empty unmarked, "These templates do not name #{repository} on their first line"
  end

  def test_the_former_name_appears_only_in_the_files_allowed_to_name_it
    naming = tracked_files.select { |file| File.binread(File.join(ROOT, file)).match?(FORMER_NAME) }
    assert_empty naming - FORMER_NAME_FILES,
                 "Only #{FORMER_NAME_FILES.join(', ')} may name #{FORMER_SLUG}"
  end

  def test_each_mention_of_the_former_name_calls_it_the_former_name
    stray = FORMER_NAME_FILES.flat_map do |file|
      paragraphs(File.binread(File.join(ROOT, file))).filter_map do |paragraph|
        mention = paragraph.find { |line, _| line.match?(FORMER_NAME) }
        "#{file}:#{mention.last}" if mention && !paragraph.map(&:first).join.match?(/\bformer/i)
      end
    end
    assert_empty stray, "These name #{FORMER_SLUG} in a paragraph that does not call it the former name"
  end
end
