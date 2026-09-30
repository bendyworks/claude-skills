# change-highlights template v1 (bendyworks/claude-skills)
# frozen_string_literal: true

# Capture strategy 1: data snapshot, for numeric and report changes.
#
# Writes a JSON file of computed values for a set of example records. Run it
# once under the "before" code and once under the "after" code over the SAME
# data (a development database loaded from a production copy), so the two
# files differ only by the code change being shown:
#
#   OUT=tmp/after.json  bin/rails runner path/to/capture_snapshot.rb
#   git switch --detach <pre-change-commit>
#   OUT=tmp/before.json bin/rails runner path/to/capture_snapshot.rb
#
# This file is a TEMPLATE. Copy it somewhere outside the skill (tmp/ is
# conventional), then edit the three marked sections: which records, how to
# find and name them, and what to compute for each. There is no detecting "the
# change" automatically; the choices here are yours.
#
# Fold before.json and after.json into one highlights manifest per recipient
# (see SKILL.md).

require 'json'

# === (1) EDIT: the example records =========================================
# A small, representative set: [id, note]. Lead with the recipient's own
# records; each recipient's manifest later keeps only theirs.
TARGETS = [
  [101, 'Recipient A -- the case they reported'],
  [202, 'Recipient B -- an ordinary month for comparison']
].freeze

# === (2) EDIT: how to find a record, and the name to show for it ==========
def find_record(id)
  Account.find_by(id: id)
end

def display_name(record)
  record.name
end

# === (3) EDIT: what to record for each ======================================
# Return a plain Hash. Keep the keys the same in the before and after runs so
# the two files line up.
def capture(record)
  period = Date.new(2026, 5, 1).all_month
  report = MonthlyReport.new(record, period)
  {
    'period' => period.first.iso8601,
    'total_cents' => report.total_cents,
    'line_items' => report.line_items.map { |item| { 'label' => item.label, 'cents' => item.amount_cents } }
  }
end

# === Generic below here =====================================================
# Read OUT first, so a forgotten one fails before the slow capture rather
# than after it.
path = ENV.fetch('OUT') { abort 'Set OUT to the JSON file to write, e.g. OUT=tmp/after.json' }

out = TARGETS.map do |id, note|
  record = find_record(id)
  unless record
    warn "  skipped #{id} (not found)"
    next
  end

  { 'id' => id, 'name' => display_name(record), 'note' => note, 'data' => capture(record) }
end.compact

File.write(path, JSON.pretty_generate(out))
puts "wrote #{out.size} snapshot#{'s' unless out.size == 1} to #{path}"
