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

Dir.glob(File.join(SOURCE_BACKUP_DIR, '*.html')).each do |path|
  basename = File.basename(path)
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
