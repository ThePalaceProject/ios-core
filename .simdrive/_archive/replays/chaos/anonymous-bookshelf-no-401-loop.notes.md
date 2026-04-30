# anonymous-bookshelf-no-401-loop

Regression guard for F-007 (PP-4164).

## What this replay reproduces

A cold-launch sequence that historically (in 3.0.1 candidate before fix)
caused Palace to fire `GET /bookshelf/patrons/me/` against the Palace
Bookshelf (DPLA) backend, receive 401 with an OPDS auth-document body,
log a `BookRegistrySync.swift: Loans sync failed: PalaceError 0` event,
and repeat the cycle on every subsequent cold launch.

## Original finding

- ID: F-007
- Discovered: chaos-qa dogfood-3, 2026-04-29
- Source run dir: `~/.specterqa/chaos-runs/2026-04-29T18-58-34Z-dogfood-3-cold-launch/`
- Severity: major (auth-flow regression for anonymous libraries)
- Commit that fixed it: `<TBD — fix lands in this PR>` (Palace/Book/Models/BookRegistrySync.swift)

## Fix that the replay guards against regressing

`BookRegistrySync.sync()` was firing the loans fetch for any account
with a `loansUrl` set, regardless of whether the library required
authentication. Palace Bookshelf's OPDS auth document declares the
loans URL even though it is anonymous-auth, so the fetch always 401'd.

Fix added a gate that skips the sync when the current account does NOT
require auth AND has no stored credentials. See the inline comment at
the gate site (`BookRegistrySync.swift`, search for `F-007`).

## Mutants this replay kills

- Flipping the `&&` in the gate to `||` → fetch fires for accounts that
  HAVE credentials, which is wrong (regression toward the original
  behavior).
- Flipping `!userAccount.needsAuth` to `userAccount.needsAuth` → fetch
  fires only for libraries that DO require auth, breaking authenticated
  loans sync (a different but worse regression).
- Removing the early `return` and falling through to the OPDS fetch →
  fetch fires anyway, original bug returns.

The replay drives the cold-launch path that historically triggered the
401. Post-fix, observe should show no 401 and no "Loans sync failed"
log line. Drift threshold of 0.85 catches any of the three mutations
above because the post-fix end-state has no error overlay / no
401-related logged events, and a regressing build would re-introduce
those.

## How to verify locally

```bash
# Sim with the patched candidate Palace.app installed:
simdrive replay --name anonymous-bookshelf-no-401-loop \
  --on-drift halt --drift-threshold 0.85 \
  --udid <UDID>
```

Expected: replay completes, no drift. Pre-fix candidate would fail
because the post-state SSIM diverges (an error toast or a quieter log
state — depending on UI surfacing of the 401 — but always different
from the recorded post-fix state).

## Curation status

- [x] Reproducible: replayed twice on patched build, identical end state.
- [x] Bug fixed: BookRegistrySync gate added.
- [ ] Mutation-killing: not yet verified with palace_mutate.py against
      the gate's lines. TODO before promoting this from "tentatively
      curated" to "verified-corpus."

The replay is in the chaos corpus today as a forward-leaning move; the
mutation-killing verification is pending and tracked.
