#!/usr/bin/env python3
"""Scan _posts/*.md for cp1252-misread-as-UTF-8 mojibake signatures.

Background: a UTF-8-encoded accented/typographic character (e.g. u-umlaut,
em-dash, curly quote) got its raw bytes re-interpreted as Windows-1252 (or
Latin-1) at some point in the Movable Type -> export pipeline, and the
resulting garbled text was re-saved as UTF-8. Three UTF-8 lead-byte values are
involved:

  - 0xC2 (decodes to "Â" in cp1252) is the lead byte of every 2-byte UTF-8
    sequence for U+0080-U+00BF (nbsp, currency/section/copyright/degree
    symbols, fractions, etc).
  - 0xC3 (decodes to "Ã" in cp1252) is the lead byte of every 2-byte UTF-8
    sequence for Latin-1 Supplement letters U+00C0-U+00FF (e.g. e-acute,
    u-umlaut, n-tilde, etc).
  - 0xE2 (decodes to "â" in cp1252) is the lead byte of most 3-byte UTF-8
    sequences used for "smart" typographic punctuation in the General
    Punctuation block (curly quotes, em/en dash, ellipsis, bullet -- all
    U+2000-U+206F).

Each lead byte is then followed by one or two UTF-8 continuation bytes
(0x80-0xBF), which -- when misread as cp1252 -- decode to a *specific* set of
characters. We build that exact character set from the codec itself rather
than guessing a Unicode range, so the detector can't accidentally match
unrelated, correctly-encoded accented characters (e.g. a lone, correct "à" in
a French loanword does NOT match, because it is not preceded by "Ã"/"Â"/"â").

Fix: iteratively apply text.encode('cp1252').decode('utf-8'), up to a small
cap (3 passes), until no mojibake signature remains in that run.

Safety: after fixing, each run is re-verified against a *broader* leftover-
corruption signature (any of Ã/Â/â immediately followed by another non-ASCII
character). If a run still trips that broader check after MAX_PASSES, it is
NOT auto-fixed -- it is reported separately as NEEDS MANUAL REVIEW, since
that means the corruption does not cleanly resolve via the documented
single-mechanism reversal (this happened for a small number of runs that
appear to have gone through additional/different mangling).

Usage:
    python3 tools/scan-mojibake.py            # dry run, report only
    python3 tools/scan-mojibake.py --apply     # apply fixes to files on disk
"""
import glob
import re
import sys

MAX_PASSES = 3


def _continuation_chars():
    """The set of characters that result from decoding UTF-8 continuation
    bytes (0x80-0xBF) as cp1252. This is what a genuine continuation byte
    looks like *after* being misread -- i.e. exactly what follows "Ã"/"Â"/"â"
    in real mojibake.

    cp1252 leaves exactly 5 byte values in this range undefined: 0x81, 0x8D,
    0x8F, 0x90, 0x9D (Windows-1252 remaps most of 0x80-0x9F to printable
    characters, but not these). Naively decoding with cp1252 raises on them,
    which silently dropped them from this set -- a real bug: any mojibake
    run whose continuation byte was one of these five was invisible to the
    scanner from the start (not a different corruption mechanism, just an
    unhandled gap in the byte-to-character mapping). Evidence from the
    corpus (e.g. "Ã" + a raw C1 control character where "Á"/"Í"/etc. should
    be) shows the actual corruption pipeline passed these 5 bytes through
    as Latin-1 codepoints (Latin-1 defines *all* of 0x80-0x9F as identity
    byte-value-equals-codepoint, unlike cp1252 which remaps most of that
    range but leaves these 5 undefined) -- so they're added here the same
    way: byte value b -> chr(b).
    """
    chars = set()
    for b in range(0x80, 0xC0):
        try:
            chars.add(bytes([b]).decode('cp1252'))
        except UnicodeDecodeError:
            UNDEFINED_CP1252_BYTES.add(b)
            chars.add(chr(b))  # Latin-1 passthrough, matching the observed corruption
    return chars


UNDEFINED_CP1252_BYTES = set()  # populated by _continuation_chars(), below
CONT_CHARS = _continuation_chars()
CONT_CLASS = ''.join(re.escape(c) for c in sorted(CONT_CHARS))
UNDEFINED_CP1252_CHARS = {chr(b) for b in UNDEFINED_CP1252_BYTES}


def encode_mixed(s):
    """Like s.encode('cp1252'), except the 5 codepoints undefined in cp1252
    (chr(0x81), chr(0x8D), chr(0x8F), chr(0x90), chr(0x9D)) are passed
    through as their raw byte value instead of raising UnicodeEncodeError --
    matching how the actual corruption pipeline evidently handled them
    (Latin-1 passthrough) rather than cp1252's mapping (which has no answer
    for them at all). Everything else still goes through real cp1252
    encoding, so this only changes behavior for those 5 specific characters.
    """
    out = bytearray()
    for ch in s:
        if ch in UNDEFINED_CP1252_CHARS:
            out.append(ord(ch))
        else:
            out += ch.encode('cp1252')  # may raise UnicodeEncodeError; let it propagate
    return bytes(out)

# A run must START with Ã or â (per the documented signature -- deliberately
# excluding "Â" as a match-start, since "Â" also arises from an unrelated,
# out-of-scope pattern: a correctly-encoded NBSP (U+00A0) whose UTF-8 bytes
# (0xC2 0xA0) get misread as cp1252, producing "Â" immediately before
# otherwise-correct punctuation like em-dashes/curly quotes (e.g. "Â—",
# "Â'"). That is a different bug with different provenance and is out of
# scope here -- see task report for details.
#
# Once a run legitimately starts with Ã or â, though, a *multi-pass*
# corruption of the same run can re-introduce "Â" mid-chain (each corruption
# pass re-encodes the previous result, and Â is exactly what a re-corrupted
# Ã/Â/â lead byte turns into). So "Â" is allowed as a continuation character
# for runs that already started with Ã/â, letting the whole multi-generation
# chain be captured and fixed as a single unit instead of being split into
# fragments that each look independently "resolved" while the combined
# result is still broken.
MOJIBAKE_RE = re.compile(r'[Ãâ][' + CONT_CLASS + r'Â]+')

# Broader post-fix sanity check: any lead-like char immediately followed by
# another non-ASCII character. A genuinely-clean fix should never leave this.
RESIDUAL_RE = re.compile(r'[ÃÂâ][^\x00-\x7F]')


def fix_run(s, trailing_context=''):
    """Try to fix a single mojibake run, iterating up to MAX_PASSES times.

    `trailing_context` is a few characters of *original* source text that
    immediately follow the run in the file. It is not part of the match
    (it didn't satisfy MOJIBAKE_RE), but it matters for verification: a
    "poison" character sitting right after a match (e.g. the stray "Å" in
    "GÃƒÅ'nther Domenig", which should be "Günther Domenig") would silently
    look fine if we only checked the isolated fixed substring in isolation,
    while the combined result ("GÃÅ'nther") is still visibly broken. So the
    residual check runs against fixed-run-plus-trailing-context, not just
    the fixed run alone.

    Returns (fixed_string, passes_used) if the run resolves to something
    with no residual corruption signature (including with its trailing
    context), else (None, passes_tried) to signal "do not auto-apply --
    flag for manual review".
    """
    current = s
    for i in range(1, MAX_PASSES + 1):
        try:
            candidate = encode_mixed(current).decode('utf-8')
        except (UnicodeEncodeError, UnicodeDecodeError):
            return None, i - 1
        current = candidate
        if not RESIDUAL_RE.search(current + trailing_context):
            return current, i
    return None, MAX_PASSES


def context(text, start, end, pad=25):
    lo = max(0, start - pad)
    hi = min(len(text), end + pad)
    return text[lo:hi].replace('\n', '\\n')


def scan_file(path):
    with open(path, encoding='utf-8') as f:
        text = f.read()
    matches = []
    for m in MOJIBAKE_RE.finditer(text):
        run = m.group(0)
        # Only 1 char of trailing context: enough to catch a poison
        # character glued directly onto this match (e.g. Å in
        # "GÃƒÅ'nther"), but not so much that it reaches into the START of
        # a *separate*, independently-matched-and-fixed run further along
        # (e.g. a distinct "Ã " match two characters later, separated by a
        # space, would otherwise get pulled into this window and produce a
        # false "still corrupted" verdict for an unrelated match).
        trailing = text[m.end():m.end() + 1]
        fixed, passes = fix_run(run, trailing)
        matches.append({
            'start': m.start(),
            'end': m.end(),
            'original_run': run,
            'fixed_run': fixed,
            'passes': passes,
        })

    # Two matches can sit back-to-back with zero gap (e.g. "Ãƒ" immediately
    # followed by "â‚¬" inside one corrupted word like "KÃƒâ‚¬rnten" ->
    # "Kärnten"). If one half of such a touching pair is unresolved, do NOT
    # apply the other half in isolation -- that would silently rewrite part
    # of a word we already know is still broken (e.g. turning "KÃƒâ‚¬rnten"
    # into "KÃƒ€rnten": still garbled, just reshuffled). Exclude both.
    matches.sort(key=lambda x: x['start'])
    for i, m in enumerate(matches):
        if m['fixed_run'] is None:
            continue
        touches_unresolved = False
        if i > 0 and matches[i - 1]['end'] == m['start'] and matches[i - 1]['fixed_run'] is None:
            touches_unresolved = True
        if i + 1 < len(matches) and matches[i + 1]['start'] == m['end'] and matches[i + 1]['fixed_run'] is None:
            touches_unresolved = True
        if touches_unresolved:
            m['fixed_run'] = None
            m['passes'] = 0

    return text, matches


def apply_fixes(text, matches):
    # apply from the end so earlier offsets stay valid
    new_text = text
    for m in sorted(matches, key=lambda x: x['start'], reverse=True):
        if m['fixed_run'] is None:
            continue
        new_text = new_text[:m['start']] + m['fixed_run'] + new_text[m['end']:]
    return new_text


def main():
    apply = '--apply' in sys.argv
    files = sorted(glob.glob('_posts/*.md'))
    total_occurrences = 0
    total_fixed = 0
    affected_files = 0
    unresolved = []
    pass_counts = {}

    for path in files:
        text, matches = scan_file(path)
        if not matches:
            continue
        affected_files += 1
        total_occurrences += len(matches)
        print(f"\n=== {path} ({len(matches)} match(es)) ===")
        for m in matches:
            before_ctx = context(text, m['start'], m['end'])
            if m['fixed_run'] is None:
                unresolved.append((path, before_ctx, m['original_run']))
                print(f"  NEEDS MANUAL REVIEW (unresolved after {m['passes']} pass(es)):")
                print(f"    run={m['original_run']!r} context={before_ctx!r}")
                continue
            total_fixed += 1
            pass_counts[m['passes']] = pass_counts.get(m['passes'], 0) + 1
            fixed_ctx = before_ctx.replace(m['original_run'], m['fixed_run'])
            print(f"  passes={m['passes']}")
            print(f"    BEFORE: ...{before_ctx}...")
            print(f"    AFTER:  ...{fixed_ctx}...")

        if apply:
            new_text = apply_fixes(text, matches)
            with open(path, 'w', encoding='utf-8') as f:
                f.write(new_text)

    print(f"\n\nSUMMARY: {affected_files} file(s), {total_occurrences} occurrence(s) matched")
    print(f"  Auto-fixable: {total_fixed} occurrence(s); pass distribution: {pass_counts}")
    if unresolved:
        print(f"  NEEDS MANUAL REVIEW: {len(unresolved)} occurrence(s) left untouched")
        for path, ctx, run in unresolved:
            print(f"    {path}: {run!r}  context={ctx!r}")
    if apply:
        print("Fixes APPLIED to disk (auto-fixable ones only).")
    else:
        print("DRY RUN only -- no files modified. Re-run with --apply to write changes.")


if __name__ == '__main__':
    main()
