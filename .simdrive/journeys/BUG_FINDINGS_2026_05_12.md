# Simdrive bug findings — 2026-05-12 borrow-flow validation

During driving the planned `borrow-read-return-roundtrip` recording for
PR #943 (the money-flow critical path), simdrive surfaced two
reproducible product issues that block the happy-path recording from
completing end-to-end on the A1QA Test Library fixture.

Both are captured as user-local recordings under
`~/.simdrive/recordings/` (NOT in this repo) for replay:

- `borrow-download-failed-cinema-beyond-human/` (3 steps)
- `borrow-stuck-overdrive-up-and-running/` (4 steps)

The recordings are user-local because they document failure paths
against a specific test library state, not flows we want to replay
in CI. If/when the underlying issues are fixed, these recordings
should be deleted (their value is purely as bug evidence).

## Bug 1 — "Download Failed - No error message" alert

**Reproduction steps:**

1. Sign in to A1QA Test Library (basic auth)
2. Catalog → Ebooks facet → tap "Cinema beyond the human" (Anat Pick, A1QA Automated Tests lane)
3. Tap Borrow

**Expected:** Book downloads + Read button appears on detail screen,
book appears in MyBooks.

**Actual:** Alert appears immediately with:
- Title: "Download Failed"
- Body: literally **"No error message"**
- Buttons: Cancel + Retry

**Severity:** Medium — the alert title and Cancel/Retry buttons are
correct UX, but the body text "No error message" is a placeholder/
fallback string that escaped to production. Users see a literal
"No error message" string which conveys nothing actionable.

**Note:** The loan DOES register server-side — after dismissing the
alert, the book detail screen shows Download + Return buttons (not
the original Borrow button), indicating the OPDS borrow request
succeeded but the fulfillment/download path failed.

**Root cause hypothesis:** The download-failure code path lacks a
meaningful error message for at least one failure mode (likely
network-level rather than HTTP-error-level, since HTTP errors would
typically have a status code or problem-document body to surface).

**Where to look:** `Palace/MyBooks/Download/` — specifically the
NSError → user-facing-string translation in the download manager.
Probably a `?? "No error message"` fallback that's never been
audited against actual failure modes.

## Bug 2 — Borrow stuck with Cancel-only UI, no progress indicator

**Reproduction steps:**

1. Sign in to A1QA Test Library
2. Catalog → tap "Up and Running" (O'Reilly Vagrant, A1QA Automated Tests lane, Overdrive distributor)
3. Tap Borrow

**Expected:** Either a quick borrow → download → Read button (per
the Mathematics Test Book happy path), OR a clear failure alert
(per Bug 1's pattern).

**Actual:** Borrow button disappears, replaced by **only a Cancel
button**. No progress indicator, no spinner, no percentage, no
status text. After 30+ seconds of waiting, the state is unchanged.
Tapping Back returns to the previous screen and the Borrow button
re-appears (cancelling the borrow). The book never reaches MyBooks.

**Severity:** High for UX — the user has no signal that anything is
happening or failing. They can only Back-out or Cancel.

**Root cause hypothesis:** The Overdrive fulfillment path may be
hanging on a network call that never returns and never times out.
The UI is correctly bound to a "borrow-in-progress" state but
there's no progress indicator surface OR no timeout to trigger a
failure alert.

**Where to look:**
- The borrow operation's network executor — is there a timeout?
- The book detail screen's `BookDetailViewModel` — what state is
  bound to the missing progress indicator?
- Specifically the Overdrive code path (other distributors may
  not have this issue — Mathematics Test Book's distributor
  worked fine).

## Impact on PR #943 (money-flow critical path coverage)

The PR was originally scoped to land a `borrow-read-return-roundtrip`
recording. With these two bugs blocking the borrow half, the PR
instead lands:

- `book-return-from-mybooks.yaml` — Return half only (already on PR)
- `read-return-from-mybooks-roundtrip.yaml` — Read + Return halves
  end-to-end, starting from an already-borrowed book
- This findings doc + bug-recording references

The borrow half is **explicitly deferred** until either:
1. The two bugs are triaged + fixed, OR
2. A known-good catalog book in the A1QA fixture is identified that
   reliably succeeds, OR
3. A different test library (Palace Bookshelf anonymous?) is used as
   the borrow-half pre-state.

## Impact on 3.1.0 release readiness

Both bugs are **discovered by simdrive driving against the simulator
on the develop branch**. Neither blocks the build, but both produce
visibly broken UX that real users would encounter. Recommend triage
before tagging 3.1.0 as RC:

- Bug 1 is likely a quick fix (replace the fallback string with a
  user-actionable message or a localized "couldn't reach server"
  body)
- Bug 2 is more substantial (needs a timeout + progress indicator
  surface)

Both bugs also exist on `develop` independent of any of this
session's PRs — they are not regressions introduced by my work.
