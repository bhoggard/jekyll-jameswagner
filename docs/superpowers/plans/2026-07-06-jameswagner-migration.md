# jameswagner.com Movable Type → Jekyll Migration Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

## Status as of 2026-07-07 (for a fresh session picking this up, possibly on a different machine)

**Tasks 1-10 are complete and pushed to `origin/main`** (`github.com:bhoggard/jekyll-jameswagner`). The site is live at `https://jameswagner.pages.dev` (Cloudflare Pages project `jameswagner`, account "Tristan Media"). Domain/DNS: user explicitly chose NOT to move jameswagner.com to Cloudflare yet (still on Opalstack DNS) — the pages.dev subdomain is the only live URL for now.

**Only Task 11 (branding and content decisions) remains**, not yet started — the plan's own checkboxes below are still unchecked throughout, but reflect what was actually done via each task's `git log` on `main`, not the checkbox state (they were never ticked during execution). Task 11 needs the user asked fresh about: sharing platforms (currently Chirpy defaults: Twitter/Facebook/Telegram — bloggy went Bluesky-only, not assumed to carry over), CC-license notice removal, full-post vs excerpt homepage display, `h1` font-size override, and site title color. **Font family/size and the 2-column layout are already decided and done — that was Task 5, not Task 11** (matched to the *old jameswagner.com site's* own look, not bloggy's).

**Known accepted exceptions** (all deliberately left as-is, not oversights — see each task's commit messages on `main` for full detail, since the per-task investigation reports lived in the git-ignored `.superpowers/sdd/` workspace and may not exist on a different checkout):
- 4 files / 43 occurrences of a second, undocumented mojibake corruption mechanism that doesn't reverse with the standard fix (`2005-01-04-austrian_cultur.md`, `2006-05-11-on_the_brooklyn.md`, `2006-06-18-gulnara_kasmali_1.md`, `2006-06-21-gay_art_now_at.md`) — `tools/scan-mojibake.py` (uncommitted, still on the machine that ran it) documents the mechanism and a partially-working alternate recovery recipe if anyone wants to revisit it.
- ~86 entries (2002-2003 era, 2.3% of corpus) use an unresolvable legacy `index.php?m=YYYYMM#NNN` internal-link scheme that couldn't be mapped to a real entry_id; left as absolute links to the still-live legacy site.
- 27 `tools/test.sh` failures accepted as genuine pre-existing content errors (empty `href=""`, prose/captions mistakenly placed in `href` attributes) — see commit `8f85963`/`25f87e4` messages.
- The Cloudflare Pages build takes ~13 minutes (vs. bloggy's ~6) due to corpus size (3415 posts + 522 redirect stubs + ~5000 images) — confirmed via build log this is NOT a Ruby-version mismatch (`ruby@3.4.4` used directly, no source compile).

**Two files are intentionally never committed** (matching bloggy's own precedent): `tools/migrate-mt-image-map.yml` (regenerable byproduct of running the migration script) and `tools/scan-mojibake.py` (scratch tooling for the known encoding exceptions above). Both still exist in the working tree of whichever machine last ran this session but won't be present after a fresh `git clone` — regenerate the image map by re-running `tools/migrate-mt-to-jekyll.rb`; `scan-mojibake.py` would need to be rewritten from this doc's description if needed again (detection: cp1252-misread-as-UTF-8 signature `[Ãâ][continuation-bytes]+`, including 5 undefined-in-cp1252 byte values 0x81/0x8D/0x8F/0x90/0x9D via Latin-1 passthrough; fix: iteratively reverse `.encode('cp1252').decode('utf-8')` up to 3 passes).

**Goal:** Migrate jameswagner.com (a second, independent Movable Type blog co-owned by the user, `entry_blog_id=4` in the same `movable_type` MySQL database as bloggy) to a standalone Jekyll site on Cloudflare Pages, reusing the tooling and lessons from the bloggy.com migration but adapted for jameswagner.com's different URL scheme.

**Architecture:** Same overall approach as the bloggy migration (documented in this repo's git history and `tools/*.rb`) — a Ruby script queries the shared MT database directly and writes Jekyll `_posts/*.md` files with per-post `permalink:` overrides preserving the original URLs. This blog does not use Textile at all (unlike bloggy), so there is no RedCloth conversion step — Task 1 Step 3 determines what `entry_convert_breaks` value(s) are actually in use and what conversion, if any, the migration script needs to perform. Images are copied from the blog download at `~/data/james-mt` into the new repo at matching paths. The new site deploys via Cloudflare Pages Git integration, same as bloggy.

**Tech Stack:** Jekyll + jekyll-theme-chirpy gem, Ruby (pin to whatever Cloudflare's current build-image default is — was 3.4.4 at bloggy migration time, verify freshly), mysql2, tzinfo, Cloudflare Pages, GitHub. This blog does not use Textile, so the RedCloth gem is not needed.

## Global Constraints

- Do not assume jameswagner.com's URL scheme matches bloggy's. **This is the single most important divergence already discovered** — see "Known Architectural Difference" below. Verify empirically before writing any permalink-generation code.
- All destructive/irreversible actions (git push, Cloudflare zone/DNS changes, deleting files) require explicit user confirmation before executing, per standing instructions.
- Reuse bloggy's already-validated technical patterns (see "Reusable Patterns" below) rather than re-deriving them from scratch. Do not reuse bloggy's _personal branding choices_ (site title color, font, sharing platforms, CC-license removal) without asking the user fresh — those were bloggy-specific preferences, not necessarily James's.
- The MySQL database is shared across both blogs (`movable_type` database, `mt_entry.entry_blog_id` distinguishes them: bloggy=1, jameswagner.com=4). Always filter queries by `entry_blog_id = 4` for this migration.
- DB access: passwordless `root` via `mysql -h 127.0.0.1 -P 3306 -u root movable_type`, or via Ruby's `mysql2` gem reading the password from `~/.my.cnf` (see bloggy's `tools/migrate-mt-to-jekyll.rb` for the exact pattern — `my_cnf[/password="(.*)"/, 1]`).

---

## Background: What We Already Know About jameswagner.com

This section exists so a fresh session doesn't have to re-derive facts already established during the bloggy migration (2026-07-05/06 session). Everything below was empirically verified, not assumed.

### CORRECTED by Task 2: the canonical scheme is date/slug (underscore), not numeric

An earlier single-sample check (below, kept for record) concluded the numeric `/mt_archives/NNNNNN.html` form was canonical. **Task 2's full investigation (28 entries, spanning 2002-2020) found the opposite is true site-wide**, and this single sample was a rare exception, not the rule:

- **jameswagner.com's canonical permalink is `/YYYY/MM/{entry_basename}.html`, with underscores preserved as-is** (NOT converted to dashes — dashed slugs 404 whenever the basename contains an underscore). Confirmed live and content-verified (page `<title>` matched the DB's `entry_title`) across every tested year 2002-2020, in 27/28 cases.
- The numeric `/mt_archives/NNNNNN.html` form only resolves for a minority of entries clustered in a narrow window around December 2006 (5/19 entries tested in that window had both files; most of the site 404s on the numeric form entirely) — it appears to be an orphaned leftover from an early MT archive-type configuration (ID-based individual archives) that was switched to date-based archives around late 2006, with a few old files left behind after the switch.
- **Entry 5954 (the original single-sample check, basename `abstract_at_mit_1`, authored 2006-12-09) is the one confirmed exception** where only the numeric URL works and the date/slug URL 404s (out of 28 entries tested). It is not representative — do not generalize from it.
- No basename collisions exist within any (year-month, basename) pair across all 3,415 published entries — the date/slug scheme is safe to use as a unique migration key with no de-duplication needed.

**Conclusion:** build Jekyll permalinks as `/YYYY/MM/{entry_basename}.html` (underscore preserved) for all entries. Because a small number of entries (at least id 5954) don't have a working date/slug URL live, Task 4 should verify each constructed URL against the live site (or otherwise flag exceptions) rather than assume 100% of entries fit the pattern — see Task 4 Step 3. Full evidence: `/Users/barry/code/jekyll/james-wagner/.superpowers/sdd/task-2-report.md`.

<details>
<summary>Original single-sample check (superseded — kept for record)</summary>

On bloggy.com, `/mt/archives/NNNNNN.html` files were PHP stubs issuing a 301 redirect to a newer slug-based URL (`/YYYY/MM/dashed-slug.html`). The original check on jameswagner.com found: the backup at `/Users/barry/data/james-mt/mt_archives/*.html` (524 numeric files) contains zero PHP; every numeric file is a complete, real page (verified via `mt_archives/005954.html`); the live site returns 200 (not a redirect) for that same numeric URL; and no working slug-based alternate was found for that one entry. This was correctly observed, but wrongly generalized to the whole site — see the correction above.

</details>

### Backup and access details

- Full site backup: `/Users/barry/data/james-mt` (already a git repo — `git log` shows one commit, "initial import"; no remote configured).
- Database: same `movable_type` MySQL database as bloggy, `entry_blog_id = 4`.
- Cloudflare account: "Tristan Media" (`ecb9c2fe7c678b4be3630990211ef6b5`) — same account bloggy.com uses.
- Live site is still up and serving (confirmed throughout investigation), which is valuable for verifying the URL scheme (Task 2) and the visual layout/typography comparison (Task 5). Images do not need to be fetched from it — the full backup at `~/data/james-mt` already contains them (see Task 6).

---

## Reusable Patterns (from the bloggy.com migration)

These technical approaches were built, tested against thousands of real posts, and are safe to reuse as-is or with light adaptation. They live in the `bloggy-jekyll` repo (this repo) at these paths — copy and adapt, don't rebuild from scratch:

1. **`tools/migrate-mt-to-jekyll.rb`** — the main DB → Jekyll posts converter. Already parameterized via `BLOG_ID` and `SOURCE_DOMAIN` constants at the top specifically for reuse (see its header comment). Handles:
   - Textile → HTML via RedCloth (`RedCloth.new(body_raw).to_html`) — **does not apply to jameswagner.com**, which does not use Textile at all. Remove/replace this step; Task 1 Step 3 determines what jameswagner.com's `entry_convert_breaks` actually is and what (if any) conversion is needed instead.
   - Category/tag mapping: primary category → `categories:` (Chirpy only really supports a 1-2 level category hierarchy), all other categories → `tags:`
   - Timezone-correct `date:` frontmatter using `tzinfo` (critical: naive Jekyll front-matter dates are parsed as **literal UTC** with no site-timezone adjustment — verified empirically. Must compute the correct historical EST/EDT offset per entry via `TZInfo::Timezone.get('America/New_York').period_for_local(t, dst: false)`, accounting for the 2007 US DST rule change)
   - Image URL rewriting: absolute `SOURCE_DOMAIN` URLs → root-relative paths, tracked in an image map for downloading
   - Known HTML typos found in bloggy's source (`bref=`→`href=`, `hrer=`→`href=`, bare `<a>`→removed) — check whether jameswagner.com's source has its own typo patterns; don't assume the same ones
   - Old Flash `<object>`/`<embed>` video blocks (YouTube/Vimeo) converted to modern iframes; blip.tv/Last.fm left as-is (both defunct, no replacement)
   - YouTube/Flickr `http://` → `https://` rewriting

2. **Image copying workflow (adapted for jameswagner.com — see Task 6):** bloggy sourced images by checking reachability against the **live** legacy site and downloading over HTTP, because no full local backup existed. jameswagner.com is different: the full site backup at `~/data/james-mt` already contains the images, so this migration copies from disk instead of downloading. Reuse only the shape of the workflow:
   - Extract every image reference. Bloggy's source was Textile, so it needed both `src="https://domain/path"` absolute HTML AND relative Textile bang-image `!path!` syntax (the second form was significantly undercounted on first pass in the bloggy migration, causing a real bug). jameswagner.com does not use Textile, so the bang-image form likely doesn't apply — confirm what jameswagner.com's actual source format's image syntax looks like (Task 1 Step 3) before assuming plain `<img src=...>`/`src="..."` HTML is the only form to extract.
   - Check for the image's presence in `~/data/james-mt` at the matching relative path before copying — some old images may still be genuinely missing even from the backup
   - Copy present ones to the exact same relative path in the new repo (Jekyll copies plain files/directories through to `_site/` untouched)
   - For genuinely missing images, leave the `src=` pointing at the original absolute URL rather than a local path that will never exist — `--disable-external` in html-proofer then skips them instead of flagging a broken internal link

3. **Redirect-stub generation** (`tools/generate-mt-redirects.rb`, `tools/generate-underscore-redirects.rb`) — Task 2 confirmed the canonical scheme is `/YYYY/MM/{entry_basename}.html` (underscore preserved), the same *shape* as bloggy's date/slug scheme, just without the dash-normalization (bloggy converted underscores to dashes; jameswagner.com keeps underscores as-is). This means `generate-underscore-redirects.rb`'s specific purpose (bridging a dash/underscore mismatch) doesn't apply here. **The user has decided (2026-07-06) to preserve the legacy numeric `/mt_archives/NNNNNN.html` URLs** for the minority of entries that still have one — see Task 4 Step 7 (new) for the adapted redirect-generation approach. Unlike bloggy, where the numeric files were PHP 301-redirect stubs, jameswagner.com's numeric files are full duplicate content pages (per Task 2), so the adaptation must treat every numeric file found in the backup as "redirect this to the entry's new canonical permalink," not filter for `<?php` stubs like bloggy's script did.

4. **Encoding bug detection/fix** — bloggy had systemic UTF-8 mojibake (104 posts, 203 occurrences of single-pass corruption, plus 1 double-pass instance) baked into the _source database itself_, not introduced by migration. Detection pattern: `[Ãâ][continuation-byte-range]+` runs, fixed by iteratively reversing `text.encode('cp1252').decode('utf-8')` until no mojibake signature remains (some instances needed 2 passes). **Scan jameswagner.com's source for the same pattern** — given it's the same era/software/likely same original encoding mishap history, this is a near-certainty, not a maybe.

5. **`tools/test.sh` flags needed for legacy content:**
   - `--no-enforce-https` (era-appropriate `http://` links that can't reasonably be upgraded)
   - `--ignore-missing-alt` (old externally-hosted images predate alt-text conventions)

6. **Cloudflare Pages setup:**
   - Pin `.ruby-version` and `mise.toml` to match Cloudflare's build-image default Ruby version _exactly_ — mismatching it makes every build compile Ruby from source via `asdf`/`ruby-build` (5+ minutes added per build). Was `3.4.4` at bloggy's migration time; **check what Cloudflare's current default is**, it may have changed.
   - Enable `build_caching: true` on the Pages project (cheap insurance, though the Ruby-version match was bloggy's actual bottleneck fix, not caching)
   - Git integration requires the user to manually authorize Cloudflare's GitHub App (`https://github.com/apps/cloudflare-workers-and-pages`) in their browser — cannot be automated via API
   - `wrangler`'s OAuth token (via `wrangler login`) has broader write scope than the `cloudflare-api` MCP connector's token, which is read-only for many operations. Extract it from `~/.config/.wrangler/config/default.toml` (`oauth_token` field) for raw API calls the MCP tool can't perform — but note even wrangler's token lacks `zone:create` and DNS-record write scope (discovered when setting up bloggy.com's custom domain); those specific operations need the user to act in the dashboard directly.

---

## Task 1: Investigate the database structure for blog_id=4

**Files:** None (read-only investigation, output informs later tasks)

- [ ] **Step 1: Confirm entry count and status distribution**

Run:

```bash
mysql -h 127.0.0.1 -P 3306 -u root movable_type -N -B -e "
SELECT entry_status, entry_class, COUNT(*) as cnt FROM mt_entry WHERE entry_blog_id = 4 GROUP BY entry_status, entry_class;
"
```

Expected: a breakdown showing published entry count (status=2, class='entry') — this is the migration scope, same as bloggy's `2753` published posts.

- [ ] **Step 2: Check category/tag usage**

Run:

```bash
mysql -h 127.0.0.1 -P 3306 -u root movable_type -N -B -e "
SELECT COUNT(DISTINCT ot.objecttag_object_id) FROM mt_objecttag ot JOIN mt_entry e ON e.entry_id = ot.objecttag_object_id AND ot.objecttag_object_datasource = 'entry' WHERE e.entry_blog_id = 4;
SELECT MAX(cat_count) FROM (SELECT p.placement_entry_id, COUNT(*) as cat_count FROM mt_placement p JOIN mt_entry e ON e.entry_id = p.placement_entry_id WHERE e.entry_blog_id = 4 GROUP BY p.placement_entry_id) t;
"
```

Bloggy had 0 real MT tags (categories only) and up to 6 categories per entry. Confirm whether jameswagner.com is similar or different — affects the categories/tags mapping logic.

- [ ] **Step 3: Check `entry_convert_breaks` to determine the actual source format**

Run:

```bash
mysql -h 127.0.0.1 -P 3306 -u root movable_type -N -B -e "
SELECT entry_convert_breaks, COUNT(*) FROM mt_entry WHERE entry_blog_id = 4 GROUP BY entry_convert_breaks;
"
```

Bloggy was uniformly `textile_2`, requiring RedCloth to convert to HTML. **The user has confirmed jameswagner.com does not use Textile at all** — RedCloth does not apply and should not be added to this migration. Use this query to determine the actual `entry_convert_breaks` value(s) in use (e.g. `__default__`, `richtext`, `0`/none) and inspect a few raw `entry_text` values directly to confirm what format the source is actually in (plain HTML, HTML with line-break conversion, Markdown, etc.) and what conversion — if any — the migration script needs to perform instead.

---

## Task 2: Determine the actual canonical URL scheme

**Files:** None (read-only investigation)

**Interfaces:**

- Consumes: nothing
- Produces: the confirmed permalink pattern, which Task 4 (migration script) depends on entirely

- [ ] **Step 1: Cross-reference a specific entry against both possible URL forms**

Pick an entry_id from `mt_entry` (blog_id=4), get its `entry_basename` and `entry_authored_on`, then check:

```bash
# Replace NNNNN, YYYY, MM, slug with real values
curl -s -o /dev/null -w "%{http_code}\n" "https://jameswagner.com/mt_archives/NNNNNN.html"
curl -s -o /dev/null -w "%{http_code}\n" "https://jameswagner.com/YYYY/MM/slug-with-dashes.html"
curl -s -o /dev/null -w "%{http_code}\n" "https://jameswagner.com/YYYY/MM/slug_with_underscores.html"
```

Do this for at least 5-8 entries spanning different years (the bloggy migration found the URL pattern was consistent 2003-2009 but didn't test every year; don't assume jameswagner.com is uniform across its full 2002-2017+ range without checking).

- [ ] **Step 2: Check for basename collisions if a date/slug scheme is confirmed**

Only relevant if Step 1 finds a working date/slug pattern. Run (adapting bloggy's collision check):

```bash
mysql -h 127.0.0.1 -P 3306 -u root movable_type -N -B -e "
SELECT DATE_FORMAT(entry_authored_on, '%Y-%m') AS ym, REPLACE(entry_basename, '_', '-') AS slug, COUNT(*) AS cnt
FROM mt_entry WHERE entry_blog_id = 4 AND entry_status = 2 AND entry_class = 'entry'
GROUP BY ym, slug HAVING cnt > 1;
"
```

- [ ] **Step 3: Document the confirmed scheme before proceeding**

Write a short note (in this plan file or a scratch file) stating definitively: "jameswagner.com's canonical permalink is X" with the evidence from Steps 1-2. Do not proceed to Task 4 without this confirmed.

---

## Task 3: Set up the new Jekyll repository

**Files:**

- Create: new repository (location/name TBD with user — likely `~/code/jekyll/jameswagner` or similar, sibling to this `bloggy` repo)

**Interfaces:**

- Consumes: nothing
- Produces: a working Jekyll site skeleton that Task 4's generated posts will populate

- [ ] **Step 1: Scaffold from the Chirpy starter**

Follow the same approach as this repo (`bloggy`) — check `README.md` here for the chirpy-starter provenance, or start fresh from `https://github.com/cotes2020/chirpy-starter`.

- [ ] **Step 2: Check Cloudflare's current build-image default Ruby version**

Search Cloudflare docs (`developers.cloudflare.com/pages/configuration/build-image/`) for the current default Ruby version under the active build image version. Do not assume it's still `3.4.4` — check fresh, since Cloudflare updates these periodically.

- [ ] **Step 3: Pin `.ruby-version` and `mise.toml` to match**

```
# .ruby-version
<confirmed version from Step 2>
```

```toml
# mise.toml
[tools]
ruby = "<confirmed version from Step 2>"
```

- [ ] **Step 4: Verify `bundle install` and a trivial `jekyll build` work locally before proceeding**

Run:

```bash
bundle install
bundle exec jekyll build
```

Expected: clean build with the starter's placeholder content.

- [ ] **Step 5: Commit the scaffold**

```bash
git init
git add -A
git commit -m "Initial Chirpy starter scaffold for jameswagner.com migration"
```

---

## Task 4: Adapt and run the migration script

**Files:**

- Create: `tools/migrate-mt-to-jekyll.rb` (copy from bloggy repo, adapt)
- Create: `tools/generate-jameswagner-legacy-redirects.rb` (adapt from bloggy's `tools/generate-mt-redirects.rb` — see Step 7)
- Create: `Gemfile` group addition for `mysql2`, `tzinfo` (copy bloggy's `:migration` optional group pattern; omit `RedCloth` — this blog does not use Textile)

**Interfaces:**

- Consumes: the confirmed URL scheme from Task 2, the DB structure facts from Task 1
- Produces: `_posts/*.md` files, plus an image-map YAML file listing images to download (same output contract as bloggy's script: `tools/migrate-mt-image-map.yml`)

- [ ] **Step 1: Copy bloggy's migration script as a starting point**

```bash
cp /Users/barry/code/jekyll/bloggy/tools/migrate-mt-to-jekyll.rb tools/migrate-mt-to-jekyll.rb
```

- [ ] **Step 2: Update the constants at the top**

```ruby
BLOG_ID = 4
SOURCE_DOMAIN = 'jameswagner.com'
SITE_TIMEZONE = 'America/New_York' # confirm this is still correct for jameswagner.com specifically
```

- [ ] **Step 3: Rewrite the permalink-generation logic to match Task 2's confirmed scheme**

Task 2 confirmed the canonical scheme is `/YYYY/MM/{entry_basename}.html`, with underscores preserved as-is (not converted to dashes, unlike bloggy). This is the same *shape* as bloggy's logic, minus the dash-normalization step:

```ruby
permalink = entry_authored_on.strftime("/%Y/%m/") + "#{entry_basename}.html"
```

Adjust the `id_to_permalink`/`slug_to_permalink` maps and cross-post link resolution logic (bloggy's rules 1-3 in the script) accordingly — reuse rule 3's shape but drop the dash-conversion (jameswagner.com's basenames are used verbatim). Also verify how jameswagner.com's own posts link to each other internally (old-style relative links, e.g. `href="005954.html"` or similar) so cross-post links get rewritten to the new permalink form, the same way bloggy's script did.

**Known exception:** Task 2 found entry_id 5954 (and possibly other rare cases — spot-check was not exhaustive) has no working `/YYYY/MM/{basename}.html` URL live; only its legacy `/mt_archives/005954.html` file resolves. This does not need special-casing here: every entry still gets the uniform `/YYYY/MM/{basename}.html` permalink (entry 5954 simply gets a URL that didn't previously resolve, which is fine for a newly-built site), and Step 7 (new, below) separately generates a legacy-numeric-URL redirect stub for any entry whose old numeric file exists in the backup — including entry 5954, so its old link keeps working too.

- [ ] **Step 4: Add a Gemfile migration group**

```ruby
# Only needed for tools/migrate-mt-to-jekyll.rb. Not installed by a plain
# `bundle install`; opt in with `bundle install --with migration`.
group :migration, optional: true do
  gem "mysql2", "~> 0.5"
  gem "tzinfo", "~> 2.0"
end
```

- [ ] **Step 5: Run the migration on a small test scope first**

Temporarily add an `entry_id IN (...)` filter (pick 5-10 entries spanning different years/content types) to the SQL query, run, and manually inspect the output before running the full migration — this caught real bugs in the bloggy migration (undercounted image references, category/tag mapping issues) that would have been expensive to fix after the fact.

```bash
bundle install --with migration
bundle exec ruby tools/migrate-mt-to-jekyll.rb
```

**Stop here and do Task 5 (appearance exploration) before continuing to Step 6** — the user wants to use this small set of real migrated posts to explore matching the old site's look before scaling up to the full migration.

- [ ] **Step 6: Remove the test filter and run the full migration**

- [ ] **Step 7: Generate redirect stubs for legacy numeric URLs**

The user has decided to preserve the legacy `/mt_archives/NNNNNN.html` URLs for entries that still have one, rather than letting them 404. Adapt bloggy's `tools/generate-mt-redirects.rb` into a new `tools/generate-jameswagner-legacy-redirects.rb`:

- Build the same `id_to_permalink` map as the main migration script (Step 3's logic: `/YYYY/MM/{entry_basename}.html`, underscore preserved, for all published entries).
- Scan `~/data/james-mt/mt_archives/*.html` (524 files) for files matching `NNNNNN.html`. Unlike bloggy's version, **do not** filter for `<?php`-stub content — every numeric file found here is a legacy duplicate content page (per Task 2's finding) that should become a redirect stub, not a PHP redirect already.
- For every numeric file whose ID maps to a published entry, generate a static redirect stub at `/mt_archives/{id}.html` (meta refresh + JS redirect + plain link, same as bloggy's stub format) pointing at that entry's new `/YYYY/MM/{basename}.html` permalink.
- This covers entry 5954 (Task 4 Step 3's known exception) automatically, since its numeric file exists in the backup — no special-casing needed beyond this general scan.
- Note any numeric files that do NOT map to a published entry (e.g. drafts, deleted entries, the 3 `page`-class entries) and report them rather than silently skipping.

- [ ] **Step 8: Commit the migration script and redirect generator (not the generated content yet)**

```bash
git add tools/migrate-mt-to-jekyll.rb tools/generate-jameswagner-legacy-redirects.rb Gemfile
git commit -m "Add jameswagner.com migration script and legacy URL redirect generator"
```

---

## Task 5: Explore matching the existing site's appearance (2-column layout, fonts)

**Files:**

- Modify: `assets/css/jekyll-theme-chirpy.scss` (or equivalent Chirpy override point) if CSS-level customization is the chosen direction
- Possibly: new/replacement theme or layout files, only if Step 2 concludes Chirpy customization can't reasonably achieve the target look
- Uses: the small set of `_posts/*.md` files generated by Task 4 Step 5 as preview content (do not wait for the full migration to do this exploration)

**Interfaces:**

- Consumes: the test-scope posts from Task 4 Step 5, and jameswagner.com's current live site as the visual reference to match
- Produces: a design direction (Chirpy customization vs. from-scratch theme) plus, if pursued now, implemented layout/font changes. Feeds into Task 11, which should not re-decide the items this task settles.

- [ ] **Step 1: Capture the old site's actual layout and typography**

Inspect the live jameswagner.com site (view source / browser dev tools) and note concretely: the 2-column structure (what's in each column, at what breakpoint it collapses, if ever), and the actual font-family stack in use (check for `@font-face` rules, Google Fonts/Typekit `<link>` tags, or plain web-safe font stacks in inline/external CSS). Do not assume — record what's actually there.

- [ ] **Step 2: Decide Chirpy customization vs. from-scratch theme, based on a concrete comparison**

Build and serve the Chirpy-based test-scope site locally, view it alongside the live old site, and compare against Step 1's findings. Chirpy already ships a sidebar+content layout — determine whether that structure can reasonably be pushed (via SCSS overrides) into matching the old site's 2-column layout, or whether the two are structurally different enough that a custom theme would be less work overall. This is a real fork in approach (raised and discussed with the user already) — present the concrete comparison and get the user's decision before investing further, rather than assuming Chirpy customization is the answer.

- [ ] **Step 3: If proceeding with Chirpy customization, implement the layout and font changes**

Override column widths/breakpoints and the font-family declarations in `assets/css/jekyll-theme-chirpy.scss` to match Step 1's findings — the user wants the fonts kept the same as the existing site, not Chirpy's (or bloggy's) defaults. If the old site used a webfont, pull in the same font (self-hosted or via its original CDN, per the user's preference — ask if unclear) rather than substituting a similar-looking system font.

- [ ] **Step 4: If Step 2 concludes a custom theme is warranted instead, escalate to the user**

Do not silently start a from-scratch theme build — confirm scope and direction with the user first, since it's a substantially larger effort than Chirpy customization.

- [ ] **Step 5: Visually verify against the test-scope posts before proceeding**

Use the dev server and browser to confirm the result before returning to Task 4 Step 6 to run the full migration.

- [ ] **Step 6: Cross-reference with Task 11**

Task 11's branding checklist includes items (site title color, font choice) that overlap with this task's font-matching goal — this task's font decision governs for jameswagner.com. Task 11's remaining items (sharing platforms, CC-license notice, homepage display mode) are independent and still to be asked about separately when that task runs.

---

## Task 6: Copy images from the local backup

**Files:**

- Uses: `tools/migrate-mt-image-map.yml` (generated by Task 4)
- Uses: `~/data/james-mt` (full site backup — already contains the images; do not download from the live site)
- Creates: copied image files at their mirrored paths throughout the repo

**Interfaces:**

- Consumes: the image map YAML from Task 4
- Produces: local image files Jekyll will copy through to `_site/` untouched

- [ ] **Step 1: Check presence of every image in the map within `~/data/james-mt`**

For each path in the image map, check whether the matching relative path exists under `~/data/james-mt` (a plain file-existence check, not a network call — the whole point of using the local backup is that no live-site requests are needed here).

- [ ] **Step 2: Copy all present images from `~/data/james-mt` to their mapped paths in the new repo**

- [ ] **Step 3: Note any genuinely missing images for the migration script's `DEAD_IMAGES_FILE` mechanism**

Create `tools/migrate-mt-dead-images.txt` (one path per line) listing image paths that are not found anywhere in `~/data/james-mt`, matching bloggy's pattern — this makes the migration script leave those `src=` attributes pointing at the original absolute URL rather than a local path that will never exist. Expect this list to be much shorter than bloggy's (a live-site 404 can be transient or path-mangled; a missing file in a static backup is closer to a real absence), but don't assume it's empty without checking.

- [ ] **Step 4: Re-run Task 4's migration script** (it reads `DEAD_IMAGES_FILE` if present) and verify the missing ones are now correctly left as absolute URLs.

---

## Task 7: Encoding bug scan and fix

**Files:**

- Modify: affected `_posts/*.md` files

- [ ] **Step 1: Scan for the mojibake signature**

Write (or adapt bloggy's) a Python script scanning all `_posts/*.md` for the pattern `[Ãâ][continuation-byte-range]+`. See bloggy's session history for the exact regex and iterative-fix approach (encode as `cp1252`, decode as `utf-8`, repeat until no signature remains, capped at 3 passes for safety).

- [ ] **Step 2: Dry-run the fix and manually review every proposed change**

Do not apply blindly — bloggy's fix script printed every `original -> fixed` pair for review before writing anything.

- [ ] **Step 3: Apply the fix and re-scan to confirm zero remaining instances**

---

## Task 8: Build verification and test suite

**Files:**

- Create/modify: `tools/test.sh` (adapt from bloggy's)

- [ ] **Step 1: Copy and adapt bloggy's `tools/test.sh`**

Include `--no-enforce-https` and `--ignore-missing-alt` from the start (both were needed for bloggy's legacy content and jameswagner.com is the same era/kind of content).

- [ ] **Step 2: Run the full build and test suite**

```bash
bash tools/test.sh
```

- [ ] **Step 3: Triage every failure**

For each html-proofer failure, determine root cause (broken cross-post link needing a rewrite rule, dead image, genuine content typo predating migration, etc.) rather than assuming it matches a bloggy failure pattern exactly. Bloggy ended with exactly 2 unfixable edge cases (a footnote definition that never existed in the source, and one author typo with trailing garbage in a URL) — jameswagner.com will have its own distinct long tail, not necessarily the same ones.

---

## Task 9: Cloudflare Pages deployment

**Files:** None (infrastructure, not repo files)

- [ ] **Step 1: Push the repo to GitHub**

Requires explicit user confirmation before pushing (per standing instructions) — confirm the repo/org name with the user first.

- [ ] **Step 2: Create the Cloudflare Pages project with Git integration**

This requires the user to manually authorize Cloudflare's GitHub App in their browser (`https://github.com/apps/cloudflare-workers-and-pages`) — cannot be automated. Once authorized, create the project via the Cloudflare API using the `wrangler`-derived OAuth token (see bloggy's session history for the exact `curl` pattern hitting `POST /accounts/{account_id}/pages/projects` with `source.type: "github"`).

- [ ] **Step 3: Trigger and verify the first build**

Same pattern as bloggy: POST to `.../pages/projects/{name}/deployments` with `branch=main` to trigger an ad-hoc build for the current HEAD (Cloudflare doesn't auto-build retroactively when a project is first connected).

- [ ] **Step 4: Verify build time is reasonable**

If the build takes 5+ minutes, suspect a Ruby-version mismatch first (bloggy's exact bug — check the build log for `asdf`/`ruby-build` compiling Ruby from source, which indicates `.ruby-version` doesn't match Cloudflare's pre-baked default).

---

## Task 10: Domain and DNS (if applicable)

**Files:**

- Modify: `_config.yml` (`url:` field)

- [ ] **Step 1: Ask the user whether jameswagner.com's domain should move to Cloudflare DNS**

Do not assume — this is a real infrastructure decision with consequences (nameserver changes affect the live site immediately once propagated). Bloggy.com's domain was already on Namecheap with Opalstack DNS; jameswagner.com's current registrar/DNS setup is unknown and must be checked first (`dig +short NS jameswagner.com`, `dig +short A jameswagner.com`, `dig +short MX jameswagner.com`) before proposing any change.

- [ ] **Step 2: If moving to Cloudflare, follow bloggy's exact process**

Zone creation and DNS record writes need to happen via the dashboard (the `wrangler` OAuth token lacks `zone:create` and DNS-write scope — discovered during bloggy's domain setup). Cloudflare's automatic DNS-record import on zone creation was **empty** for bloggy (despite existing A/MX/TXT records) — don't rely on it; manually add the necessary CNAME records pointing at the Pages project afterward.

---

## Task 11: Branding and content decisions (ask the user fresh)

**Files:**

- Create: `assets/css/jekyll-theme-chirpy.scss` (custom style overrides, if wanted)
- Create: `_data/locales/en.yml` (if CC-license removal or other locale text changes are wanted)
- Modify: `_data/share.yml` (sharing platforms)
- Modify: `_layouts/home.html` (only if full-post homepage display is wanted — this was a deliberate bloggy preference, not a default)

**None of bloggy's branding choices should be assumed to apply to jameswagner.com.** These were Barry's personal preferences for his own blog:

- Site title color (extracted from an ArtCat logo — irrelevant to jameswagner.com)
- Sans-serif font choice
- Bluesky-only sharing links
- CC license notice removal
- Full-post (vs excerpt) homepage display
- `h1` font-size override

Ask the user explicitly whether any of these should carry over, rather than silently copying bloggy's `assets/css/jekyll-theme-chirpy.scss` and `_data/share.yml` wholesale.

---

## Self-Review Notes

- **Spec coverage:** Tasks 1-2 cover the critical unknowns (DB structure, URL scheme) that must be resolved before any code is written. Tasks 3-4 and 6-10 mirror bloggy's actual migration sequence. Task 5 is a deliberate insertion (per user request) between the test-scope migration run and the full migration run, so appearance work happens against real content early rather than at the end. Task 11 explicitly separates reusable technical patterns from bloggy-specific preferences, since this plan will be executed by a fresh session with no memory of _why_ bloggy looks the way it does.
- **Placeholder scan:** Task 4 Step 3's permalink logic is conditional on Task 2's findings since the actual scheme isn't yet confirmed — this is a genuine open question flagged prominently, not a placeholder for something knowable now. Task 5 Step 2's Chirpy-vs-custom-theme decision is similarly a genuine open fork, deliberately left for a concrete side-by-side comparison rather than decided in advance.
- **Known risk:** the single biggest risk to this plan is assuming jameswagner.com's URL scheme mirrors bloggy's. Task 2 exists specifically to prevent that mistake; do not skip it.
