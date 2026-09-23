# Release fix-reconciliation waivers

The **Release Gates** workflow (`.github/workflows/release-gates.yml`, gate 1)
runs `scripts/check-release-fix-reconciliation.py` on every PR into `main`. It
diffs the release branch against `origin/develop` (by patch-id, via `git
cherry`) and BLOCKS the release if a crash / critical-path fix on develop has no
equivalent on the release and is not waived here.

## When the gate fires

It found a commit on develop that (a) touches a critical-path file AND (b) reads
as a fix, that is NOT on the release you're promoting. For each one, decide:

- **Cherry-pick it into the release** — it belongs in this ship. (Preferred for
  anything crash-related.)
- **Waive it** — it is intentionally held for a later release. Record it here so
  the exclusion is a deliberate, audited decision, not silence.

## Waiver file format

One file per release: `<release>.txt` where `<release>` is the release ref with
`/` replaced by `-` (e.g. `release-3.2.1.txt`, `hotfix-3.2.1.txt`). One entry
per line:

```
<sha-or-#pr>   <reason>
# lines beginning with '#' (followed by non-digit) are comments
62e12d56c      shipping in 3.3.0 — not needed on this hotfix line
#1097          same fix, deliberately deferred
```

A candidate is reconciled if its abbreviated SHA, full SHA, or `#<pr>` is the
first token of a line here.
