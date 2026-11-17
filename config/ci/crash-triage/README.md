# Pre-GA crash-triage ledger

The **Release Gates** workflow (`.github/workflows/release-gates.yml`, gate 2)
runs `scripts/check-pre-ga-crash-triage.py` on every PR into `main`. It pulls
the release version's FATAL Crashlytics signatures (via
`scripts/crashlytics-triage-export.py`, reusing the sentinel's Firebase access)
and BLOCKS the release if a signature that FIRST appeared in this release is
still un-triaged.

This closes the 3.2.0 gap: the saveSync-deadlock crash had events on the pre-GA
RC builds, but nobody triaged them until a week after GA.

## When the gate fires

A FATAL signature whose `firstSeenVersion` equals the release version is
un-triaged. Look at it on the Crashlytics board and decide, then record it:

- **Fix it** — cut/adjust the release to carry the fix.
- **Triage it** — you've assessed it and are shipping anyway (known, low-volume,
  a fix is already riding the next release, etc.). Record it here.

## Triage file format

One file per version: `<version>.txt` (e.g. `3.2.0.txt`). One entry per line:

```
<issue-id>   <ticket-or-reason>
# lines beginning with '#' are comments
8afb1c66ce5dde59b8774424240af778   PP-4819 — fixed in 3.2.1 hotfix
```

A signature is triaged if its Crashlytics issue id (full, or as a prefix) is the
first token of a line here.

## Firebase-outage contract

If the Firebase service account is missing or the fetch fails, the export is
empty and the gate PASSES — a Crashlytics outage must not block a release. The
manual maintainer triage is the backstop for that window.
