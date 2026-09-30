#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for the change-highlights skill's snapshot template,
# skills/change-highlights/templates/capture_snapshot.rb. A project copies
# the template and runs it under `rails runner`; here a copy runs under
# plain ruby after a stand-in for the Rails pieces it touches (a model's
# find_by, Date#all_month, and the report class the template's edit
# section names). Coverage records nothing here: the project measures only
# bin/*. Run: ruby test/change_highlights_template_test.rb

require_relative 'cli_test_case'
require 'json'
require 'open3'
require 'tmpdir'

class CaptureSnapshotTemplateTest < Minitest::Test
  TEMPLATE = File.expand_path('../skills/change-highlights/templates/capture_snapshot.rb', __dir__)
  # Written for Ruby 2.6, so the system-Ruby test runs the template, not a
  # stand-in that needs a newer Ruby.
  STAND_IN = <<~'RUBY'
    require 'date'

    class Date
      def all_month
        Date.new(year, month, 1)..Date.new(year, month, -1)
      end
    end

    Account = Struct.new(:id, :name) do
      def self.find_by(id:)
        { 101 => new(101, 'Northwind'), 202 => new(202, 'Contoso') }[id]
      end
    end

    LineItem = Struct.new(:label, :amount_cents)

    MonthlyReport = Struct.new(:record, :period) do
      def total_cents
        50_000
      end

      def line_items
        [LineItem.new('Subscription', 50_000)]
      end
    end
  RUBY
  SYSTEM_RUBY = '/usr/bin/ruby'

  def setup
    @dir = Dir.mktmpdir
    FileUtils.cp(TEMPLATE, File.join(@dir, 'capture_snapshot.rb'))
    File.write(File.join(@dir, 'rails_stand_in.rb'), STAND_IN)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def run_copy(env, ruby: 'ruby')
    Open3.capture3(env, ruby, '-r./rails_stand_in', 'capture_snapshot.rb', chdir: @dir)
  end

  def test_the_first_line_marks_the_file_as_a_template
    assert_equal '# change-highlights template v1 (bendyworks/claude-skills)', File.readlines(TEMPLATE).first.chomp
  end

  def test_a_copy_writes_one_snapshot_per_record_found
    out_path = File.join(@dir, 'after.json')
    out, err, status = run_copy({ 'OUT' => out_path })

    assert_predicate status, :success?, err
    assert_match(/wrote 2 snapshots/, out)
    snapshots = JSON.parse(File.read(out_path))
    assert_equal [[101, 'Northwind'], [202, 'Contoso']], snapshots.map { |s| [s['id'], s['name']] }
    assert_equal({ 'period' => '2026-05-01', 'total_cents' => 50_000,
                   'line_items' => [{ 'label' => 'Subscription', 'cents' => 50_000 }] }, snapshots.first['data'])
  end

  def test_a_record_that_is_not_found_is_skipped_with_a_note
    File.write(File.join(@dir, 'rails_stand_in.rb'), STAND_IN.sub("202 => new(202, 'Contoso')", ''))
    out, err, status = run_copy({ 'OUT' => File.join(@dir, 'after.json') })

    assert_predicate status, :success?, err
    assert_match(/skipped 202 \(not found\)/, err)
    assert_match(/wrote 1 snapshot\b/, out)
  end

  # A project may still run Rails on the Ruby macOS ships (2.6).
  def test_a_copy_runs_under_the_macos_system_ruby
    skip 'no Ruby 2.x at /usr/bin/ruby' unless File.executable?(SYSTEM_RUBY) && `#{SYSTEM_RUBY} -e 'print RUBY_VERSION'`.start_with?('2.')

    _out, err, status = run_copy({ 'OUT' => File.join(@dir, 'after.json') }, ruby: SYSTEM_RUBY)
    assert_predicate status, :success?, err
  end

  # A forgotten OUT fails before the capture, which on a real database can
  # take minutes.
  def test_without_out_it_stops_before_capturing
    File.write(File.join(@dir, 'rails_stand_in.rb'), "#{STAND_IN}\nclass MonthlyReport; def initialize(*)\n abort('captured')\n end; end\n")
    _out, err, status = run_copy({ 'OUT' => nil })

    refute_predicate status, :success?
    assert_match(/Set OUT/, err)
    refute_match(/captured/, err)
  end
end
