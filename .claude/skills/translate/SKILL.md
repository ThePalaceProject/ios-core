---
name: translate
description: Translate untranslated Palace iOS keys into French, Italian, German, and Spanish, or re-check the translations for specific source files. Runs `python3 scripts/palace_strings.py status` and writes values into `Palace/<lang>.lproj/Localizable.strings` and `Localizable.stringsdict` using the project's library-lending termbase. Use when asked to translate a locale, fill in missing translations, finish a language, localize new strings, or verify the translations for a view, file, or directory. Does not add `NSLocalizedString(...)` call sites, edit `Strings.swift`, or run string extraction — those stay with the developer.
tools: Bash, Read, Edit, Grep, Glob
---

# /translate — fill in the non-English localization tables

Palace ships **en, fr, it, de, es**. English is the source of truth and lives in the
`NSLocalizedString` call sites themselves; the other four are translated from it into
`Palace/<lang>.lproj/`.

This skill writes translated values. That is all it does.

## Scope

- It **never** edits `Palace/Utilities/Localization/Strings.swift` or any other `.swift` file.
  Adding an `NSLocalizedString` call site, choosing a key, and writing the `comment:` are the
  developer's job.
- It **never** edits `Palace/en.lproj/`. English is the source, not a target. (There is no
  `en.lproj/Localizable.strings` at all — for the flat keys the key *is* the English string.
  `en.lproj/Localizable.stringsdict` exists because plural rules have nowhere else to live, and
  it is still English source, still off limits.)
- It **never** runs `genstrings`, `xcodebuild -exportLocalizations`, or a Transifex push/pull.
- A key that is **absent from the code** is a signal to hand back to the developer, not a thing
  to invent.

`python3 scripts/palace_strings.py` decides what work exists. Nothing else does.

## Step 1 — Parse the arguments

Two independent dimensions, both optional, freely combined. An argument matching a supported
language code (`fr`, `it`, `de`, `es`) is a language; anything else is a path.

| Invocation                                        | Meaning                         |
| ------------------------------------------------- | ------------------------------- |
| `/translate`                                      | Language mode, all four         |
| `/translate de` / `/translate de es`              | Language mode, narrowed         |
| `/translate Palace/Holds/HoldsView.swift`         | File mode, all four languages   |
| `/translate de Palace/MyBooks/`                   | File mode, German only          |
| `/translate Palace/Holds/ Palace/SignInLogic/`    | File mode, several paths        |

`en` is never a target. A directory argument recurses over `.swift`, `.m`, and `.h`, skipping
`PalaceTests/`, `PalaceUITests/`, and `*.generated.swift`.

## Step 2 — Build the work list

```bash
python3 scripts/palace_strings.py status                    # every language
python3 scripts/palace_strings.py status --langs de         # one language
python3 scripts/palace_strings.py status --langs de,es      # several
python3 scripts/palace_strings.py status --langs de --json  # machine-readable
```

`status` reports, per language, which keys the code declares and which of them the language's
tables answer. `check` is the CI form of the same question — it is silent when everything is
complete and non-zero when it is not:

```bash
python3 scripts/palace_strings.py check
```

`inventory` is the third subcommand: it lists the keys the code declares, with no language
comparison. Use it only to answer "does this key exist at all"; it is not a work list.

The whole interface is three subcommands — `inventory`, `status`, `check` — and four flags:
`--langs` (comma-separated, default `en,de,es,fr,it`), `--source` (repeatable; restricts the scan
to a path), `--lproj-root` (default `Palace`), and `--json`. Do not guess at anything beyond
those; run `--help` if a command rejects what you passed, and do the narrowing yourself (Step 2b)
rather than inventing an option.

**`status` is the single source of truth for what work exists.** Do not derive a work list by
grepping `Strings.swift`, by diffing two `.strings` files, or by reading a previous run's report.
A key can be missing for reasons none of those see.

**A non-zero exit from `status` is the normal case here, not a failure.** Incomplete is what you
were invoked to fix. Do not abort on it.

### Step 2b — File mode only: narrow to the file's keys

`--source` does most of this for you — it restricts the scan to the paths you name, and it is
repeatable:

```bash
python3 scripts/palace_strings.py status --source Palace/Holds --source Palace/MyBooks
```

Note that a key reached through `Strings.<Struct>.<member>` has its literal in `Strings.swift`,
not in the view file, so scoping `--source` to a view alone will miss it. Resolve those members to
their literals and intersect by hand with a whole-tree `status` run when the targets are views.

**Report, but do not act on**, any key you cannot resolve to a literal (a key built by string
interpolation, or one read from a constant the file does not own). Those are the developer's call.

## Step 3 — Act on the key states

| State                                | Action                                                                                                 |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------ |
| Declared in code, absent from table  | Translate it.                                                                                           |
| Present but empty                    | Translate it. An empty value is a defect, never a placeholder — see [No fallback](#step-4a--there-is-no-per-key-fallback). |
| Present in table, absent from code   | **Do not delete it.** Report it; a dead key is cheap and the developer decides.                          |
| Translated                           | Language mode: skip. File mode: audit it (Step 3c).                                                     |

### Step 3c — File mode only: auditing an already-translated key

The default is to leave it alone. Rewrite **only** when the existing value has a real defect:

- a format specifier whose set, count, or type differs from the English key;
- bare `%@` specifiers reordered relative to the English, without switching to positional form;
- a glossary term rendered differently from the termbase, or inconsistently with the same term
  elsewhere in the same table;
- wrong register — informal where the glossary requires formal, or the Italian
  buttons-take-imperative rule violated;
- a progress form identical to its idle label plus `...`;
- a borrow-vs-lend inversion, where the string tells the patron the library is lending;
- a `.stringsdict` entry missing the `other` category, or a French `one` category that reads
  wrong at zero;
- an accessibility label left as an identifier or abbreviated into a UI fragment;
- drift from a changed English source — compare against the current key text.

Anything that is merely "could be phrased better" is **not** a defect. Report it as confirmed and
move on; a quiet diff is worth more than a marginally nicer string.

Finish with a per-language tally — `N confirmed, M corrected, K reported` — and for each
correction show the before, the after, and which rule it broke.

## Step 4 — Write the values

Read `references/glossary.md` before writing anything. It fixes the register, the domain
termbase, the do-not-translate list, and the length policy, and consistency across ~410 strings
depends on it.

### Step 4a — There is no per-key fallback

This is the rule that decides file layout, so it comes first.

`NSLocalizedString` resolves against **one** table — the one for the user's chosen localization.
If `fr.lproj/Localizable.strings` **exists** but does not contain the key, the lookup returns
**the key itself**. It does not fall through to English. Only a **wholly absent** table
(no `fr.lproj` at all, or no `Localizable.strings` in it) sends the lookup to the development
language.

Two consequences, both non-negotiable:

- **Never leave a key out of one language's table.** Finishing a file in German and not in
  Italian does not leave Italian "still English" — it leaves Italian *partly broken*.
- **Never write an empty value.** `"Borrow" = "";` renders a blank button. It is strictly worse
  than the untranslated English.

Palace survives most misses because its keys *are* the English text: a missing `"Borrow"` renders
`Borrow`, which is wrong but readable. That mercy does not extend to the identifier-shaped keys
the glossary lists — a missing `CarPlay.Error.offline` renders the literal string
`CarPlay.Error.offline` on a dashboard screen while the patron is driving. Live proof already in
the tree: `fr.lproj/Localizable.stringsdict` has no `year_suffix_short`, so French renders that
key verbatim wherever the short duration form is used.

### Step 4b — Format specifiers are printf, and a mismatch is a crash

Palace uses C format specifiers, not named tokens: `%@` (an object, usually a `String`), `%d` and
`%ld` (integers), `%f` (a float), `%%` (a literal percent sign), and the positional forms
`%1$@`, `%2$@`, `%3$@`.

**The target must carry the identical SET, COUNT, and TYPE of specifiers as the English key.**

- Identical set: every specifier in the key appears in the value. `%d%% read` has two — a `%d`
  and an escaped percent. Dropping one `%` of `%%` turns the rest of the string into a
  specifier.
- Identical count: if the key has two `%@`, the value has two. Not one, not three.
- Identical type: `%@` stays `%@`. Substituting `%d` for `%@` makes `String(format:)` read an
  object pointer as an integer.

**A mismatched specifier is a CRASH, not a cosmetic bug.** `String(format:)` walks the varargs
list by what the format string claims, not by what was passed. An extra specifier reads past the
end of the argument list; a wrong type reads the right memory at the wrong width. Both are
undefined behavior that in practice segfaults or prints garbage, in release builds, on a patron's
device. There is no compiler check and no test that catches it for you — the format string is
data.

**When a language must reorder the arguments, switch to positional form.** German, French,
Spanish, and Italian all put constituents in a different order from English, and bare `%@`
specifiers bind to arguments **by position in the format string**. Swapping two bare `%@` does
not swap the values — it silently puts the author's name where the title belongs:

```
"Downloading %@ from %@"   →  WRONG: "Lade von %@ %@ herunter"     ← the two values are now swapped
                              RIGHT: "Lade %2$@ von %1$@ herunter"  ← positional, explicit binding
```

Rules for positional form:

- **Convert the whole string or none of it.** Mixing `%1$@` and bare `%@` in one format string is
  not reliable; once one specifier is positional, number all of them.
- Number by the **English** argument order: the first specifier in the English key is `%1$`, the
  second `%2$`, regardless of where they land in the target.
- The type suffix stays: `%1$@`, `%2$d`. Not `%1$`.
- The English source may already be positional (`"%1$@, by %2$@, narrated by %3$@"`). Keep it
  positional and keep the same numbers bound to the same roles.

Reordering is the only reason to go positional. A string whose arguments stay in English order
keeps its bare specifiers.

### Step 4c — `.strings` file format

`Palace/<lang>.lproj/Localizable.strings`, UTF-8, one entry per line:

```
/* Announced by VoiceOver when a download finishes. */
"Download completed for %@." = "Download für %@ abgeschlossen.";
```

- The **key is the English source string verbatim** — every character of it, including the
  trailing period, the `...`, and the specifiers. A key that differs from the literal in
  `NSLocalizedString` by one character is a key that is never found.
- Every entry ends in a **semicolon**. A missing one silently truncates the rest of the file at
  parse time; the entries after it are simply not there.
- Inside a value, escape `"` as `\"`, a literal backslash as `\\`, and a newline as `\n`.
  Palace has multi-line English keys (`Strings.HoldsView.emptyMessage`) — those arrive as one
  logical string with real spaces, not `\n`, because the Swift literal uses line continuations.
  Match what the key actually contains.
- Carry the `comment:` argument across as a `/* ... */` comment above the entry. It is the only
  context the next translator gets.
- **Never write a key twice.** Duplicate keys do not error; the last one silently wins.
- Keep the file sorted by key, so a diff shows changes rather than churn.

### Step 4d — `.stringsdict` and plural categories

Count-bearing strings live in `Palace/<lang>.lproj/Localizable.stringsdict`, an XML plist. One
entry per key:

```xml
<key>day_suffix_long</key>
<dict>
    <key>NSStringLocalizedFormatKey</key>
    <string>%#@day@</string>
    <key>day</key>
    <dict>
        <key>NSStringFormatSpecTypeKey</key>
        <string>NSStringPluralRuleType</string>
        <key>NSStringFormatValueTypeKey</key>
        <string>d</string>
        <key>one</key>
        <string>%d jour</string>
        <key>other</key>
        <string>%d jours</string>
    </dict>
</dict>
```

The categories Foundation supplies are CLDR's: `zero`, `one`, `two`, `few`, `many`, `other`.
Foundation selects among whichever ones you write and falls back to `other` for any category you
omit. For Palace's integer counts:

| Language   | Categories to write | Notes                                                       |
| ---------- | ------------------- | ----------------------------------------------------------- |
| en, de     | `one`, `other`      |                                                              |
| fr, es, it | `one`, `other`      | **Do not add `many`.** See below.                            |

- **`other` is mandatory in every language.** It is the fallback; without it a count with no
  matching category has nowhere to land.
- **Do not write a `many` category for fr/it/es.** CLDR does define one for those languages, but
  it applies to compact-decimal and large-magnitude forms that Palace never renders — days,
  weeks, books, chapters, applied filters. Foundation resolves those counts to `other` already.
  Writing `many` adds an arm that is never selected and that the next reader has to re-derive.
- **French treats 0 as `one`.** French's `one` category is `i = 0 or 1`, so zero days renders the
  `one` string. Therefore the French `one` value must read correctly at both 0 and 1, which means
  it must keep its `%d` rather than hard-coding the numeral: `%d jour` gives `0 jour` and
  `1 jour`; the hard-coded `1 journée` renders **`1 journée` for a zero-day count**. That defect
  is in the tree today across every `_suffix_long` entry in `fr.lproj/Localizable.stringsdict` —
  do not copy the pattern, and fix it if a task brings you into that file.
  Note also that French agrees with this at zero and the other three languages do not: German,
  Spanish, and Italian put 0 in `other` (`0 Tage`, `0 días`, `0 giorni`).
- The `NSStringFormatValueTypeKey` (`d`) and the variable name (`day`) are structure, not
  content. Copy them from the English entry unchanged; only the category strings are translated.

## Step 5 — VoiceOver strings are translations too

A large share of Palace's localized strings are accessibility labels, hints, and announcements —
the whole `Strings.Accessibility` struct, the `// Accessibility` blocks in `Strings.Generic`, and
every `*Announcements` struct. They are spoken aloud, and that changes what a good translation is:

- **Write a natural spoken phrase, not a UI fragment.** `Clear search` is a button name in
  English and reads as an instruction; the target should read as one too
  (`Suche löschen`, not `Suche klar`). Announcements are whole sentences and stay whole sentences.
- **Never abbreviate an accessibility string for length.** The length policy in the glossary
  applies to visible chrome. A label nobody sees has no layout to overflow, and a shortened one
  is simply less information spoken.
- **Never leave one as an identifier.** `Strings.Accessibility` holds bare identifier constants
  (`navigationTitle`, `librarySwitchButton`) that are SwiftUI accessibility *identifiers*, not
  labels — those are not translated at all. Anything in that struct built with
  `NSLocalizedString` **is** announced and must be translated.
- **Punctuation is prosody.** A period ends the utterance; a comma is a pause. Keep the English
  sentence boundaries. A trailing `...` is read as a pause, which is what a progress string wants.
- **Read the interpolated result aloud.** `"%1$@, by %2$@, narrated by %3$@"` becomes one spoken
  line; check that the target's connectives still parse when the three values are substituted.

## Step 6 — Verify

```bash
python3 scripts/palace_strings.py status --langs <code>
```

for each language you touched.

- **Language mode**: expect the language complete.
- **File mode**: expect no remaining untranslated key among the file's keys. Other keys may still
  be untranslated — that is fine and not your concern.

Then confirm by hand, because `status` cannot see either of these:

- **Specifier parity.** For every value you wrote that contains a `%`, compare its specifier list
  against the English key's — same set, same count, same type, and positional if reordered.
- **Plist well-formedness**, if you touched a `.stringsdict`:
  `plutil -lint Palace/<lang>.lproj/Localizable.stringsdict`.

Finally report: any dead keys left in place, any unresolvable key literals from Step 2b, any
identifier-shaped key you translated by meaning and are flagging for a human, and the file-mode
audit tally from Step 3c.
