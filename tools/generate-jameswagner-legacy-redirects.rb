#!/usr/bin/env ruby
# frozen_string_literal: true

# Generates client-side redirect stubs for jameswagner.com's legacy numeric
# archive URLs (/mt_archives/NNNNNN.html). Adapted from bloggy.com's
# tools/generate-mt-redirects.rb, with one key difference:
#
# On bloggy.com, the numeric /mt/archives/NNNNNN.html files were PHP stubs
# that issued a 301 redirect to the slug-based URL -- bloggy's script filtered
# out any numeric file that *wasn't* a "<?php" stub (leftover static pages for
# deleted entries). On jameswagner.com, Task 2's investigation found the
# numeric files are full duplicate CONTENT pages, not redirect stubs -- there
# is no "<?php" prefix to filter on, and every numeric file that maps to a
# published entry should become a redirect stub here, unconditionally.
#
# The user has decided (2026-07-06) to preserve these legacy numeric URLs
# rather than let them 404, including entry 5954 -- the one entry (per Task 2)
# with NO working date/slug URL at all, for which this redirect is the *only*
# way its old link keeps working.
#
# Usage:
#   bundle install --with migration   # if not already done for migrate-mt-to-jekyll.rb
#   bundle exec ruby tools/generate-jameswagner-legacy-redirects.rb
#
# SOURCE_BACKUP_DIR should contain the old site's mt_archives/*.html files
# (the full static backup of the original site).

require 'mysql2'
require 'fileutils'
require 'json'

BLOG_ID = 4
SOURCE_BACKUP_DIR = '/Users/barry/data/james-mt/mt_archives'
REPO = File.expand_path('..', __dir__)
OUTPUT_DIR = File.join(REPO, 'mt_archives')

# Entries with a confirmed old-style /mt_archives/NNNNNN.html reference
# (found linked from within other jameswagner.com posts, from bloggy.com's
# own posts via a full DB cross-reference, and at least one confirmed
# external site -- calendar.artcat.com/exhibits/2661.html links to 5664)
# but whose numeric HTML file is missing from SOURCE_BACKUP_DIR, so the
# Dir.glob scan below would otherwise silently skip them. Confirmed
# published with a working canonical permalink -- add here to force a stub
# even without a backup file. (2727, 4872, 6576 are NOT included: those
# numeric IDs belong to unpublished drafts with no canonical target to
# redirect to.)
EXTRA_IDS_MISSING_BACKUP_FILE = [
  2504, 2519, 2642, 2672, 2699, 2750, 2838, 2859, 2860, 2900,
  2906, 2923, 2924, 2927, 2928, 2966, 2981, 2983, 3018, 3030,
  3071, 3094, 3100, 3126, 3135, 3138, 3143, 3154, 3167, 3217,
  3223, 3224, 3233, 3250, 3254, 3289, 3332, 3333, 3334, 3343,
  3365, 3386, 3392, 3422, 3446, 3466, 3513, 3529, 3537, 3548,
  3638, 3665, 3704, 3714, 3740, 3844, 3895, 3926, 3928, 3960,
  4006, 4011, 4028, 4072, 4116, 4193, 4303, 4308, 4315, 4351,
  4601, 4611, 4663, 4680, 4705, 4725, 4765, 4767, 4782, 4821,
  4835, 4927, 5036, 5127, 5240, 5244, 5255, 5312, 5329, 5331,
  5332, 5446, 5475, 5545, 5560, 5574, 5647, 5664, 5732, 5745,
  5764, 5791, 5958, 6016, 6018, 6045, 6052, 6065, 6085, 6086,
  6167, 6348, 6367, 6431, 6562, 6682, 6786, 6827, 6857, 6898,
  6904, 6932,
].freeze

my_cnf = File.read(File.expand_path('~/.my.cnf'))
db_pass = my_cnf[/password="(.*)"/, 1]
client = Mysql2::Client.new(host: '127.0.0.1', username: 'root', password: db_pass, database: 'movable_type')

entries = client.query(<<~SQL, cache_rows: false)
  SELECT entry_id, entry_basename, entry_authored_on
  FROM mt_entry
  WHERE entry_blog_id = #{BLOG_ID} AND entry_status = 2 AND entry_class = 'entry'
SQL

# Same permalink logic as migrate-mt-to-jekyll.rb Step 3: /YYYY/MM/basename.html,
# basename used verbatim (no dash conversion), .strip guards against the one
# confirmed dirty-basename case (entry 5106, see migrate-mt-to-jekyll.rb).
id_to_permalink = {}
entries.each do |row|
  basename = row['entry_basename'].to_s.strip
  ym = row['entry_authored_on'].strftime('%Y/%m')
  id_to_permalink[row['entry_id']] = "/#{ym}/#{basename}.html"
end

FileUtils.mkdir_p(OUTPUT_DIR)

written = 0
skipped_no_target = []

backup_basenames = Dir.glob(File.join(SOURCE_BACKUP_DIR, '*.html')).map { |path| File.basename(path) }
extra_basenames = EXTRA_IDS_MISSING_BACKUP_FILE.map { |id| format('%06d.html', id) }

(backup_basenames + extra_basenames).uniq.each do |basename|
  next unless basename =~ /\A(\d+)\.html\z/

  id = $1.to_i

  target = id_to_permalink[id]
  unless target
    skipped_no_target << basename
    next
  end

  html = <<~HTML
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta http-equiv="refresh" content="0; url=#{target}">
    <link rel="canonical" href="#{target}">
    <title>Redirecting&hellip;</title>
    <script>location.replace(#{target.to_json});</script>
    </head>
    <body>
    <p>This page has moved. If you are not redirected automatically, <a href="#{target}">click here</a>.</p>
    </body>
    </html>
  HTML

  File.write(File.join(OUTPUT_DIR, basename), html)
  written += 1
end

puts "Redirect stubs written: #{written}"
puts "Skipped (numeric file present but entry_id not found among published entries): #{skipped_no_target.size}"
skipped_no_target.each { |f| puts "  #{f}" }
