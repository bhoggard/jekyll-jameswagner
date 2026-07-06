#!/usr/bin/env ruby
# frozen_string_literal: true

# Converts published entries from a Movable Type database into Jekyll posts
# under _posts/, preserving the original archive URLs as per-post `permalink:`
# overrides and rewriting internal cross-post links, image references, and
# known third-party CDN links (YouTube, Flickr) to https.
#
# Adapted from bloggy.com's tools/migrate-mt-to-jekyll.rb for jameswagner.com
# (entry_blog_id = 4 in the same shared `movable_type` database). Two
# significant differences from bloggy's version:
#
#   1. jameswagner.com does not use Textile at all (entry_convert_breaks is
#      '__default__' for essentially every entry) -- there is no RedCloth
#      step. Instead, MT's own "convert line breaks" behavior is replicated
#      directly: entry_text already contains real inline HTML tags (<a>,
#      <blockquote>, <img>, <em>, <br />, etc.) with paragraphs separated by
#      blank lines and single newlines meant to become <br />. See
#      convert_breaks below.
#   2. jameswagner.com's canonical permalink is /YYYY/MM/{entry_basename}.html
#      with underscores preserved as-is (NOT converted to dashes, unlike
#      bloggy). Also, unlike bloggy (which linked its own posts with
#      site-relative URLs), jameswagner.com's own posts always link to each
#      other with absolute, domain-prefixed URLs (with or without "www."),
#      never relative ones -- confirmed empirically (zero relative internal
#      hrefs found in the corpus).
#
# Usage:
#   bundle install --with migration   # installs mysql2, tzinfo
#   bundle exec ruby tools/migrate-mt-to-jekyll.rb
#
# Requires a local MySQL server with the MT database loaded, reachable with
# the credentials in ~/.my.cnf (a `[client]` section with `user`/`password`).
#
# After running, review MIGRATE_IMAGE_MAP (below) for the full list of
# referenced source-site images. Unlike bloggy (which downloaded over HTTP),
# jameswagner.com's full site backup already exists locally at
# ~/data/james-mt, so images should be copied from there at their listed
# paths rather than fetched from the live site. Known-dead source paths can
# be listed in tools/migrate-mt-dead-images.txt (one path per line) to leave
# them pointing at the original absolute URL instead of a local path that
# will never exist.
#
# BLOG_ID, SOURCE_DOMAIN, and SITE_TIMEZONE below are the only settings that
# should need changing to reuse this for a different Movable Type blog.

require 'mysql2'
require 'tzinfo'
require 'yaml'
require 'set'

BLOG_ID = 4
SOURCE_DOMAIN = 'jameswagner.com'
SITE_TIMEZONE = 'America/New_York'

REPO = File.expand_path('..', __dir__)
POSTS_DIR = File.join(REPO, '_posts')
DEAD_IMAGES_FILE = File.join(__dir__, 'migrate-mt-dead-images.txt')
IMAGE_MAP_OUTPUT = File.join(__dir__, 'migrate-mt-image-map.yml')

TZ = TZInfo::Timezone.get(SITE_TIMEZONE)
DEAD_IMAGES = File.exist?(DEAD_IMAGES_FILE) ? File.readlines(DEAD_IMAGES_FILE).map(&:chomp).to_set : Set.new

my_cnf = File.read(File.expand_path('~/.my.cnf'))
db_pass = my_cnf[/password="(.*)"/, 1]
client = Mysql2::Client.new(host: '127.0.0.1', username: 'root', password: db_pass, database: 'movable_type')

def offset_str(t)
  period = TZ.period_for_local(t, dst: false)
  secs = period.utc_total_offset
  sign = secs < 0 ? '-' : '+'
  secs = secs.abs
  format('%s%02d:%02d', sign, secs / 3600, (secs % 3600) / 60)
end

def yaml_scalar(str)
  str.to_s.gsub('"', '\\"')
end

# ---- MT-style line-break conversion ----
#
# entry_convert_breaks = '__default__' means MT applies its own "convert line
# breaks" pass at render time: blank lines (\n\n) become paragraph breaks and
# single newlines (\n) become <br />. The stored entry_text has no <p> tags of
# its own, but does contain real block-level HTML (chiefly <blockquote>, and
# occasionally <ul>/<div>/<table>/<form>/<pre>) written directly by hand.
#
# A naive "split the whole entry on blank lines, wrap each chunk in <p>"
# approach breaks as soon as a <blockquote> itself contains a blank line
# (very common -- e.g. multi-paragraph quoted reports), because the
# blockquote's opening and closing tags end up in different chunks. Instead,
# split_blocks below scans for these block-level containers and treats each
# one (matched by tag depth, so correctly handling entries with genuinely
# nested <blockquote><blockquote>...) as a single unit whose *inner* content
# recurses through the same paragraph/break conversion, while the surrounding
# top-level text is paragraph-wrapped normally. This preserves block
# boundaries exactly and still converts single newlines to <br /> inside
# quoted blocks (matching MT's actual behavior for e.g. Steve's multi-
# paragraph field report quoted inside a single <blockquote> in entry 2795).
BLOCK_TAGS = %w[blockquote ul ol table div form pre].freeze
BLOCK_TAG_RE = /<(\/?)(#{BLOCK_TAGS.join('|')})\b[^>]*>/i

def split_blocks(text)
  segments = []
  depth = 0
  block_start = nil
  last_pos = 0
  text.to_enum(:scan, BLOCK_TAG_RE).each do
    m = Regexp.last_match
    closing = !m[1].empty?
    if closing
      depth -= 1 if depth.positive?
      if depth.zero?
        segments << { type: :block, content: text[block_start...m.end(0)] }
        last_pos = m.end(0)
      end
    else
      if depth.zero?
        segments << { type: :text, content: text[last_pos...m.begin(0)] }
        block_start = m.begin(0)
      end
      depth += 1
    end
  end
  segments << { type: :text, content: text[last_pos..] }
  segments
end

def paragraphs_to_html(text)
  text.split(/\n\s*\n/).filter_map do |para|
    para = para.strip
    next nil if para.empty?

    "<p>#{para.gsub(/\n/, "<br />\n")}</p>"
  end.join("\n\n")
end

def convert_breaks(text)
  split_blocks(text).filter_map do |seg|
    if seg[:type] == :text
      html = paragraphs_to_html(seg[:content])
      html.empty? ? nil : html
    else
      content = seg[:content]
      m = content.match(/\A(<[^>]+>)(.*)(<\/[a-zA-Z]+>)\z/m)
      if m
        "#{m[1]}\n#{convert_breaks(m[2])}\n#{m[3]}"
      else
        content
      end
    end
  end.join("\n\n")
end

entries = client.query(<<~SQL, cache_rows: false).to_a
  SELECT entry_id, entry_title, entry_text, entry_text_more, entry_basename, entry_authored_on
  FROM mt_entry
  WHERE entry_blog_id = #{BLOG_ID} AND entry_status = 2 AND entry_class = 'entry'
  ORDER BY entry_authored_on
SQL

cat_stmt = client.prepare(<<~SQL)
  SELECT c.category_label, p.placement_is_primary, c.category_id
  FROM mt_placement p JOIN mt_category c ON c.category_id = p.placement_category_id
  WHERE p.placement_entry_id = ?
  ORDER BY p.placement_is_primary DESC, c.category_id ASC
SQL

# ---- Pass 1: build entry_id -> permalink and slug -> permalink maps for cross-post link resolution ----
id_to_permalink = {}
slug_to_permalink = {}
entries.each do |row|
  # .strip guards against at least one confirmed case of dirty source data:
  # entry 5106's entry_basename in the live DB begins with a literal embedded
  # "\r\n" (HEX 0D0A) before "anyone_care_w" -- caught by inspecting the full
  # migration's output, where it corrupted both the generated filename and the
  # `permalink:` YAML value. No other entries in the corpus have a basename
  # containing any character outside [a-zA-Z0-9_-] (verified via a `REGEXP
  # '[^a-zA-Z0-9_-]'` scan against all 3415 published entries), so .strip is
  # sufficient here rather than a broader sanitization pass.
  basename = row['entry_basename'].to_s.strip
  ym = row['entry_authored_on'].strftime('%Y/%m')
  permalink = "/#{ym}/#{basename}.html"
  id_to_permalink[row['entry_id']] = permalink
  slug_to_permalink["#{ym}/#{basename}"] = permalink
end

# ---- Pass 2: convert + rewrite links ----
image_map = {}
youtube_count = 0
flickr_count = 0
embed_count = 0
image_count = 0
id_link_count = 0
slug_link_count = 0
old_site_fallback_count = 0
written = 0
seen_filenames = {}

entries.each do |row|
  id = row['entry_id']
  title = row['entry_title'].to_s
  basename = row['entry_basename'].to_s.strip # see Pass 1 comment: guards against entry 5106's dirty basename
  authored = row['entry_authored_on']

  cats = cat_stmt.execute(id).to_a
  primary = cats.find { |c| c['placement_is_primary'] == 1 } || cats.first
  categories = primary ? [primary['category_label']] : []
  tags = cats.reject { |c| c.equal?(primary) }.map { |c| c['category_label'] }

  body_raw = [row['entry_text'], row['entry_text_more']].compact.reject(&:empty?).join("\n\n")
  html = convert_breaks(body_raw)
  html = html.gsub('<a>', '') # bare <a> with no attributes: typo for </a>
  html = html.gsub(/<p>\s*<br\s*\/?>\s*<\/p>/i, '') # empty paragraph left by a standalone <br>
  html = html.gsub(/\n{3,}/, "\n\n") # collapse runs of blank lines left behind by the above

  # Rewrite SOURCE_DOMAIN absolute image URLs (with or without "www."). Known-dead
  # ones (see DEAD_IMAGES_FILE) are left as absolute (dead) URLs so html-proofer's
  # --disable-external skips them instead of flagging a broken internal link;
  # everything else becomes root-relative and is tracked for download from the
  # local ~/data/james-mt backup.
  #
  # IMPORTANT: this must only match paths that actually end in an image
  # extension. jameswagner.com's own posts link to *each other* with absolute,
  # domain-prefixed URLs (unlike bloggy, which used relative internal links),
  # so a blanket "strip the domain off any SOURCE_DOMAIN href" rule here would
  # silently mangle cross-post links (e.g. .../mt_archives/NNNNNN.html) into
  # bare relative paths *before* the cross-post link resolution rules below
  # get a chance to look them up -- caught via test-scope inspection (entry
  # 3663's link to entry 3658 was left as an unresolved "/mt_archives/003658.html"
  # instead of its correct new permalink until this was scoped to images only).
  html = html.gsub(/(src|href)="https?:\/\/(?:www\.)?#{Regexp.escape(SOURCE_DOMAIN)}(\/[^"]*\.(?:jpe?g|png|gif|bmp|webp|pdf|svg))(\?[^"]*)?"/i) do
    attr = $1
    path = $2
    if DEAD_IMAGES.include?(path)
      %(#{attr}="https://#{SOURCE_DOMAIN}#{path}")
    else
      image_map[path] = "https://#{SOURCE_DOMAIN}#{path}"
      image_count += 1
      %(#{attr}="#{path}")
    end
  end

  # Track images already referenced via a relative path (plain <img>/<a> markup)
  # in either src= or href=, with or without a leading slash.
  html = html.gsub(/(src|href)="(\/?(?!\/)(?!https?:)[^"]*\.(?:jpe?g|png|gif|bmp|webp|pdf|svg))"/i) do
    attr = $1
    raw_path = $2
    path = raw_path.start_with?('/') ? raw_path : "/#{raw_path}"
    if DEAD_IMAGES.include?(path)
      %(#{attr}="https://#{SOURCE_DOMAIN}#{path}")
    else
      unless image_map.key?(path)
        image_map[path] = "https://#{SOURCE_DOMAIN}#{path}"
        image_count += 1
      end
      %(#{attr}="#{path}")
    end
  end

  # Replace old Flash <object>/<embed> video embeds with modern iframes. These
  # never play in any current browser (Flash was retired in 2021) regardless of
  # markup validity.
  html = html.gsub(%r{<object[^>]*>.*?</object>}im) do |block|
    if block =~ %r{youtube\.com/v/([a-zA-Z0-9_-]+)}
      embed_count += 1
      %(<iframe width="560" height="315" src="https://www.youtube.com/embed/#{$1}" title="YouTube video player" frameborder="0" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" referrerpolicy="strict-origin-when-cross-origin" allowfullscreen></iframe>)
    elsif block =~ %r{vimeo\.com/moogaloop\.swf\?clip_id=(\d+)}
      embed_count += 1
      %(<iframe src="https://player.vimeo.com/video/#{$1}" width="560" height="315" frameborder="0" allow="autoplay; fullscreen; picture-in-picture" allowfullscreen></iframe>)
    else
      block
    end
  end

  # Rewrite YouTube http -> https
  html = html.gsub(/http:\/\/(www\.)?youtube\.com/i) do
    youtube_count += 1
    "https://#{$1}youtube.com"
  end
  html = html.gsub('http://youtu.be', 'https://youtu.be')

  # Rewrite Flickr http -> https (image CDN hosts + main site)
  html = html.gsub(/http:\/\/((?:www\.|static\.|farm\d+\.static\.)?flickr\.com)/i) do
    flickr_count += 1
    "https://#{$1}"
  end

  # --- Cross-post link resolution ---
  # jameswagner.com's own posts always link to each other with absolute,
  # domain-prefixed URLs (confirmed empirically: zero relative internal hrefs
  # in the corpus), in one of two forms:

  # 1. https?://[www.]jameswagner.com/mt_archives/NNNNNN.html (legacy numeric
  #    archive form, still the *only* working URL for a minority of entries,
  #    e.g. entry 5954) -> resolved via numeric entry ID.
  html = html.gsub(%r{(href)="https?://(?:www\.)?#{Regexp.escape(SOURCE_DOMAIN)}/mt_archives/0*(\d+)\.html(?:#0*\d+)?"}i) do
    attr = $1
    target_id = $2.to_i
    if id_to_permalink[target_id]
      id_link_count += 1
      %(#{attr}="#{id_to_permalink[target_id]}")
    else
      $~[0]
    end
  end

  # 2. https?://[www.]jameswagner.com/YYYY/MM/basename.html (already the
  #    canonical current-site form, basename verbatim/underscored)
  #    -> resolved via the date+basename map.
  html = html.gsub(%r{(href)="https?://(?:www\.)?#{Regexp.escape(SOURCE_DOMAIN)}/(\d{4})/(\d{2})/([a-zA-Z0-9_-]+)\.html"}i) do
    attr = $1
    y = $2
    m = $3
    raw_basename = $4
    key = "#{y}/#{m}/#{raw_basename}"
    if slug_to_permalink[key]
      slug_link_count += 1
      %(#{attr}="#{slug_to_permalink[key]}")
    else
      $~[0]
    end
  end

  # 3. Any remaining SOURCE_DOMAIN link/src not resolved above -> normalize to
  #    a clean absolute https URL pointing at the legacy site. This covers:
  #      - the pre-2006 `index.php?m=YYYYMM#NNN` permalink scheme (~80 entries,
  #        2002-2003), whose fragment number is NOT the DB entry_id and could
  #        not be reverse-engineered from available data (see task report) --
  #        left as a working link to the still-live legacy site rather than
  #        guessed at incorrectly.
  #      - /gallery/*, /albums/* photo-gallery pages (no Jekyll equivalent)
  #      - numeric mt_archives IDs that don't map to a published entry (draft,
  #        deleted, or `page`-class content)
  html = html.gsub(/(src|href)="https?:\/\/(?:www\.)?#{Regexp.escape(SOURCE_DOMAIN)}(\/[^"]*)"/i) do
    attr = $1
    path = $2
    old_site_fallback_count += 1
    %(#{attr}="https://#{SOURCE_DOMAIN}#{path}")
  end

  date_str = authored.strftime('%Y-%m-%d')
  offset = offset_str(authored)
  ym = authored.strftime('%Y/%m')
  permalink = "/#{ym}/#{basename}.html"

  filename = "#{date_str}-#{basename}.md"
  if seen_filenames[filename]
    STDERR.puts "WARN: duplicate filename #{filename} (entry #{id}, previous entry #{seen_filenames[filename]})"
  end
  seen_filenames[filename] = id

  fm_lines = []
  fm_lines << "title: \"#{yaml_scalar(title)}\""
  fm_lines << "date: #{authored.strftime('%Y-%m-%d %H:%M:%S')} #{offset}"
  fm_lines << "categories: [#{categories.map { |c| yaml_scalar(c) }.join(', ')}]" unless categories.empty?
  fm_lines << "tags: [#{tags.map { |c| yaml_scalar(c) }.join(', ')}]" unless tags.empty?
  fm_lines << "permalink: #{permalink}"

  content = "---\n#{fm_lines.join("\n")}\n---\n\n#{html.strip}\n"
  File.write(File.join(POSTS_DIR, filename), content)
  written += 1
end

puts "Entries written: #{written}"
puts "Distinct #{SOURCE_DOMAIN} images referenced: #{image_map.size} (#{image_count} occurrences)"
puts "YouTube http:// links rewritten: #{youtube_count}"
puts "Flickr http:// links rewritten: #{flickr_count}"
puts "Old Flash object/embed video blocks converted to iframes: #{embed_count}"
puts "Cross-post links resolved via numeric ID: #{id_link_count}"
puts "Cross-post links resolved via date/basename match: #{slug_link_count}"
puts "Old-site resource links normalized to absolute legacy URL (unresolved): #{old_site_fallback_count}"
puts "Duplicate filenames: #{seen_filenames.size < written ? 'SEE WARNINGS ABOVE' : 0}"
puts "Image map written to #{IMAGE_MAP_OUTPUT} - download these into the repo at their listed paths."

File.write(IMAGE_MAP_OUTPUT, image_map.to_yaml)
