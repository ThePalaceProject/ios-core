# Adding or changing a user-facing string

Palace ships its translations from the repo. There is no translation service to
push to and nothing fetches strings at runtime, so a string you add is English
in German, Spanish, French and Italian until someone fills the tables.

CI will not let that reach a release. This is how you clear it.

## The shape of it

Translation needs judgement; **detecting** that a translation is missing does
not. So the two halves live in different places:

| | where it runs | what it needs |
| --- | --- | --- |
| Detecting drift | CI, and your machine | nothing but Python |
| Producing translations | **your machine only** | a translator — an agent, a person, a vendor |

CI never translates. It compares two sets and fails if one is short. That is
why the loop works without any AI in the pipeline, and why it keeps working for
a contributor who has none.

## The loop

```bash
# 1. What is missing?
python3 scripts/palace_strings.py status

# 2. Write the gaps into a work file
python3 scripts/palace_strings.py export --file l10n-work.json

# 3. Fill the de/es/fr/it fields in that file.  <-- the only step that varies

# 4. Validate and write the tables
python3 scripts/palace_strings.py import --file l10n-work.json

# 5. Confirm, then commit the .strings files with your code
python3 scripts/palace_strings.py check --require-complete
```

Step 4 refuses the whole batch if anything is wrong and writes nothing. It
rejects a format specifier that does not match the English, an empty value, a
value that is really a symbol name, and a key that is not in the source. A
half-applied batch would leave the tables in a state nobody chose.

`l10n-work.json` is scratch. Do not commit it.

## The status document, and getting a review

`docs/Operations/localization-status.md` reports current coverage. It is
GENERATED — never hand-edit it:

```bash
python3 scripts/palace_strings.py report
```

`check` fails when it does not describe the current tables, so it cannot drift:
change a translation without regenerating and you get
`stale_report ... run: python3 scripts/palace_strings.py report`. Commit the
regenerated document with the translations that changed it.

To send the strings for outside linguistic review:

```bash
python3 scripts/palace_strings.py packet --file /tmp/review-packet
```

That writes one CSV per language with empty `REVIEW_` columns, the glossary the
translations follow, and a brief stating plainly what was and was not checked —
mechanics only, no native speaker. The brief is generated, so the packet is
complete without anyone writing a covering note.

Coverage is not quality. The status document says how many strings have a
translation; it says nothing about whether any of them are good.

## Step 3, three ways

**With Claude Code.** Run `/translate`. It reads
`.claude/skills/translate/references/glossary.md` — the library-lending
termbase, the formal-register rules, the do-not-translate list — fills the work
file and reports what it was unsure about.

**With a person.** `l10n-work.json` is a flat list of
`{key, english, comment, de, es, fr, it}`. Send it to whoever translates. The
`comment` field is the only context they get, so write a real one at the call
site: *"Button that extends a loan"* beats *"button"*. Point them at the
glossary for terminology, and at one rule that is not obvious — **every format
specifier must survive verbatim**, identical in set, count and type. A dropped
`%@` is undefined behaviour in `String(format:)`, not a cosmetic slip.

**Not at all.** If a string genuinely should not be translated — a debug
placeholder, a brand name — add it to
`scripts/l10n-untranslated-allowlist.json` **with a reason**. The reason is the
point: it is reviewed in the PR, and without it the list becomes a place to put
work someone skipped.

## Things that will bite you

**English lives in the code, not in a file.** There is no `en.lproj/Localizable.strings`
and there should not be: it is not in the Xcode project, so a file there would
never ship while looking authoritative. The key IS the English.

**Changing an English string changes the key**, which orphans its translations.
`status` will show the old key as no-longer-in-source and the new one as
untranslated. If the change was cosmetic — a recase, a specifier switched
between `%d` and `%1$d` — record it in `scripts/l10n-key-migrations.json` so
the existing translation carries across instead of being paid for twice.

**A key that is missing renders as the key**, not as English. Foundation has no
per-key fallback. For most strings the key *is* the English, so a gap degrades
to readable English. For an identifier-shaped key (`CarPlay.Error.offline`) it
renders raw — pass a `value:` argument so the miss degrades to that instead.

**SwiftUI builds a different key than you typed.** `Text("\(n) items")` where
`n` is an `Int` looks up `"%lld items"`, not `"%@ items"`, and a literal `%`
inside an interpolated string is escaped to `%%`. `palace_strings.py` reports
every interpolated key as needing confirmation for this reason; `genstrings`
gets it wrong in the same direction, so agreement between them proves nothing.

**Translating an unreachable screen costs real money.** Before adding strings to
a new view, check something constructs it outside its own file. Two parked
prototypes were translated into four languages before anyone asked.
