# Equivalent-mutant suppressions

`palace_mutate.py` flips operators in production Swift and checks that some test
fails (the mutant is "killed"). A mutant that no test kills usually means a
coverage gap — but occasionally the mutant is **equivalent**: it changes the
source text without changing any observable behavior, so *no* test can ever kill
it. Re-flagging an equivalent mutant every run is noise. This directory lets a
human suppress one **once, with a reason**, after review.

Suppress sparingly. A surviving mutant is far more often a missing test than a
true equivalence. Only add an entry after you have convinced yourself (and ideally
a reviewer) that the two operators are provably interchangeable on that line.

## File naming

One JSON file per source file, named by the source **leaf without `.swift`**:

| Source file                                   | Suppressions file                                  |
| --------------------------------------------- | -------------------------------------------------- |
| `Palace/Audiobooks/AudiobookLoader.swift`     | `.forgeos/mutation-suppressions/AudiobookLoader.json` |
| `Palace/Book/Models/TPPBookState.swift`       | `.forgeos/mutation-suppressions/TPPBookState.json`    |

`load_suppressions(repo_root, source_relpath)` derives the leaf from
`source_relpath`, so a file named `EXAMPLE.json` (this directory's sample) is
**never** loaded for any real source file — there is no `EXAMPLE.swift`.

## Format

A JSON **list** of objects. Each object:

```json
{
  "line_text": "for i in 0 ..< count {",
  "original": "<",
  "mutated": "<=",
  "reason": "count is the array length; i never reaches it, so < vs <= on the loop bound is equivalent here"
}
```

Field semantics (must match the mutation's fields in `palace_mutate.py`):

- `line_text` — the full source line the mutation sits on. Compared **stripped**
  of leading/trailing whitespace on both sides, so a re-indent does not silently
  un-suppress a reviewed mutant. (A change to the line's actual content WILL
  un-suppress it — which is correct: the line you reviewed no longer exists.)
- `original` — the operator token as it appears in source (e.g. `>=`, `&&`,
  `return true`, `+= 1`). Matched **exactly**.
- `mutated` — the operator token the mutator would substitute (e.g. `>`, `||`).
  Matched **exactly**.
- `reason` — free text. Required by convention (this is the whole point of a
  reviewed suppression); ignored by the matcher.

A suppression matches a discovered mutant iff all three of
`(line_text.strip(), original, mutated)` match. A malformed or non-list file is
treated as empty (suppresses nothing) — a broken suppressions file must never
crash a mutation run.

See `EXAMPLE.json` for a complete sample.
