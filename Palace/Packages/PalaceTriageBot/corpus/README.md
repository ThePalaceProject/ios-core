# Triage-bot ticket corpus

The measurements that justify the classifier's thresholds, the per-category
remedy priors, and the ladder ordering all come from real HelpSpot tickets. This
directory holds the pipeline. It does not hold the corpus.

## Where the corpus lives, and why not here

`~/harness/corpora/palace-triage/` on a maintainer machine.

The tickets are real patron support messages. They are PII-stripped — names,
addresses, phone numbers, card and patron numbers, and book titles are removed
rather than substituted, and each mining pass runs a regex sweep over its own
output to confirm it. Even so, several hundred verbatim patron messages are not
something to publish in an open repository without an explicit decision by the
project, and that decision has not been made. The curated subset that the test
suite actually needs is committed, at
`Tests/TriageBotCoreTests/Fixtures/MatchCorpus.json`.

Mining requires HelpSpot access, so an outside contributor could not reproduce it
regardless of where the data sat. Nothing in the build or the test suite depends
on this directory.

## Rebuilding it

1. Mine each id range through the `helpspot_multi_get` MCP tool into
   `mined-<from>-<to>.json`, keeping only patron-facing iOS reports and recording
   for each: the patron's verbatim words, support's actual diagnosis, a category,
   and the device block. A rate limit is a stop-and-report signal. Do not seek
   credentials by any other route — an earlier run did, and it was a security
   incident.
2. `python3 consolidate.py` — deduplicates, then splits deterministically.

## The split is the point

`id % 3 == 0` goes to a sealed holdout. The rule is mechanical so it cannot drift
toward whichever tickets would flatter a score, and stable so a lost corpus
rebuilds identically from the same id ranges — which is exactly what happened
once already.

Only `authoring.json` may be read while writing keywords, copy, or priors.
`holdout.json` stays sealed until that work is frozen and is then read once.

## Two traps when re-deriving the priors

Both were hit on the first re-derivation and both would have loosened a correct
rule. They are also recorded next to the table in `CatalogValidator.swift`.

**A keyword scan counts mentions, not prescriptions.** Re-deriving naively put
"sign out and back in" at 7% for sign-in, appearing to contradict a shipped
suppression. Reading the three tickets showed none of them prescribed it: one
patron was already signed out and was walked to the login screen, one resolution
merely explained that credentials persist until you sign out, and one described
replacing a library card. Read the tickets before moving a cell.

**Absence is only evidence for remedies support would write down.**
Pull-to-refresh appears in 3 of 135 resolutions, so it reads 0% everywhere — not
because it never helps but because it is too small to record. The <=3%
suppression rule applies only to substantive remedies: update, reinstall,
sign-out, switch-library.
