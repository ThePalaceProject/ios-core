---
date: 2026-09-21
source: near-miss
walls: [mutation]
severity: high
wall_status: open
detector_script: ""
---

# mutation-cache-replays-stale-verdict

## Finding

`palace_mutate.py` reported a mutation verdict it did not measure. Asked to
re-measure `LibraryRegistryCrawler.swift` after adding a test written specifically
to kill the one survivor:

    [1/2] line 430 cmp: '>=' -> '>'
      SURVIVED (cached)
    killed: 1  survived: 1  kill rate: 50.0%

Re-run with `--no-cache`, same tree, same tests:

    [1/2] line 430 cmp: '>=' -> '>'
      KILLED  (55.5s)
    killed: 2  survived: 0  errored: 0  kill rate: 100.0%

The cached verdict predated the test. `CACHE_VERSION = 2` documents that keys
include test CONTENT (`palace_mutate.py:78`, `:575`), and the discriminating fact
is that the content HAD changed: `--tests CrawlerCompletenessTests` is declared in
`PalaceTests/Crawl/CrawlerCompletenessTests.swift`, and
`git diff --name-only 615952ed4 cbf0e2a62 -- PalaceTests/Crawl/CrawlerCompletenessTests.swift`
returns that file. The boundary test was present in the committed file before the
cached run (`git show cbf0e2a62:… | grep -c reachingExactlyTheDeclaredTotal` = 1).
So the key should have missed and did not.

`:587-592` documents a known bound — the fingerprint covers the declaring file of
the named class — which is exactly the case that failed here, so this is a v2
regression rather than the bound working as designed.

## What actually happened

A cached SURVIVED costs a wasted investigation: it sends you looking for a coverage
gap that no longer exists. **The dangerous direction is the other one.** The same
staleness can replay a KILLED for a test that has since been weakened or deleted —
and that is a green mutation score standing in for a measurement never taken, which
is the strongest single piece of evidence this repo's TDD policy asks for.

It was caught only because the number contradicted a test written minutes earlier
for exactly that mutant. Had the cached verdict AGREED with expectation — the usual
case — it would have been reported as measured, and CLAUDE.md explicitly treats a
mutation score as the answer to "would the tests notice if the code were wrong".

Sibling of `2026-09-21-guard-refusal-renders-as-success.md`: same family, different
layer. That entry is about guards whose refusal renders as success; this is about a
measurement tool whose non-measurement renders as a measurement. The related note
in that entry — `palace_mutate` reporting `0/36 mutation points on changed lines`
for `AccountRegistryLoader.swift`, which reads exactly like a clean pass — is the
third instance in one changeset.

## Walls that should have caught it

- **mutation** — is the wall here, and it reported a number it had not measured.
  Nothing in the output distinguishes "measured this tree" from "replayed an older
  one" except the parenthetical `(cached)`, which sits beside the verdict rather
  than qualifying the summary line or the kill rate.
- **the summary line** — `killed: 1  survived: 1  kill rate: 50.0%` carries no
  indication that either figure came from cache. A reader quoting the score into a
  commit body or a review reply quotes it as measurement.

## Proposed permanent fix

**NOT YET WRITTEN** — `wall_status` stays `open` and `detector_script` empty until
it exists, per this catalog's README.

1. **Propagate cache provenance to the summary.** `killed: N survived: M` must
   state how many verdicts were replayed, e.g. `killed: 1 survived: 1 (2 of 2 from
   cache)`. A score that cannot say whether it was measured should not be quotable.
2. **Fix or narrow the v2 key.** Either the test-content fingerprint genuinely
   covers the declaring file (and this is a bug to fix), or it does not (and
   `:575`'s "keys include test CONTENT" overstates it and should be corrected).
   Establish which with the two keys before changing behaviour.
3. **Default to `--no-cache` for any run whose result will be reported**, with the
   cache reserved for iteration. The cache exists to make local loops fast; a
   number that reaches a commit body, a review, or a PR should be measured.

Not mechanizable as a detector in the usual sense: nothing greppable distinguishes
a stale cache hit from a fresh one. The fix is in the tool's own output contract,
which is why items 1-3 are behavioural rather than a `check-*.py`.

## Application log

- 2026-09-21 — opened from the PP-5191 crawler re-measurement. Discriminating
  command recorded above. No fix applied yet; the affected number was corrected by
  re-running with `--no-cache` and the commit body records that it needed it.
