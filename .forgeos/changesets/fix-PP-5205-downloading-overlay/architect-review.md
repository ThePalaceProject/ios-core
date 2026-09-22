# Architect review — PP-5205 fix-contract (pre-implementation)

**Verdict: BLOCKED.** One structural defect in the proposed design (F1), one gate
that will false-red a correct implementation (F2), and two factual errors in the
traced chain (F3, F4). The diagnosis is right and the discriminator is right; the
blast radius is wrong.

Reviewed: contract, `AudiobookMorphingPlayerView.swift:792-940`,
`AudiobookSessionPresenter.swift:121-160/290-450/550-615`,
`AudiobookSessionManager.swift:1170-1180/1890-1925`,
`AudiobookDownloadProgressPolicy.swift`, `LCPStreamingPlayer.swift:185-240/615-660`,
`OpenAccessPlayer.swift:380-600`, `Player.swift:114-180`,
`NavigationHostView.swift:135-146`, `AudiobookMorphingPlayerViewTests.swift`,
`docs/architecture/areas/audiobook/verification-checklist.md`,
`scripts/godclass-loc-baseline.txt`.

---

## Answers to the seven questions

### 1. Is the causal chain right? — Mostly. Link 1 confirmed, link 2 wrong, link 3 asserted not measured.

**Link 1 — CONFIRMED.** `LCPStreamingPlayer.swift:190-209`. `isSeekWithinSameTrack`
is true only when `avQueuePlayer.currentItem.trackIdentifier == position.track.key`;
a later-chapter TOC pick fails that, so the `!isSeekWithinSameTrack` branch fires and
sets `isLoaded = false`, `suppressAudibleUntilPlaying = true`,
`avQueuePlayer.isMuted = true`, `lastStartedItemKey = nil`. Exactly as the contract
states.

**Link 2 — WRONG MECHANISM.** The contract says "`AudiobookSessionPresenter` mirrors
the toolkit playback model, so `audiobookSession.isLoaded` goes false." The presenter
does not have an `isLoaded` property at all:

    grep -n "isLoaded" Palace/Audiobooks/AudiobookSessionPresenter.swift
    # 322, 601 — both COMMENTS. No property, no @Published, no sink.

The view reads `audiobookSession.isLoaded`, which is a computed passthrough on
`AudiobookSessionManager.swift:1176-1177`:

    public var isLoaded: Bool { manager?.audiobook.player.isLoaded ?? false }

and its own doc-comment at :1173-1175 says **"Not `@Published`; the view re-reads it
on `isPlaying`/position ticks."**

This is not cosmetic. Because `isLoaded` is unpublished, the Downloading screen does
not appear when `isLoaded` flips — it appears on the next re-render, which is the
coincident `isPlaying` flip (`avQueuePlayer.pause()` at `LCPStreamingPlayer:201` →
`playbackStatePublisher` → presenter `:557-560`) or a position tick. That is
*why* QA sees "audio pauses AND a Downloading screen" as one event. Fix the
contract's wording; the fix itself survives this correctly, because
`hasStartedPlayback` **is** `@Published` (presenter `:134`) and latched.

**Link 3 — ASSERTED, NOT MEASURED.** `.downloading` requires `isDownloading == true`
at that instant. The contract infers this from the sibling policy's doc-comment
("for LCP that flag stays true through track decryption"). It never measures it on
build 509. If `isDownloading` were false the symptom would be `.skeleton` (shimmer),
not a determinate "Downloading… NN%". QA's wording is consistent with `true`, and the
fix collapses both to `.hidden`, so this is a `warning` not a blocker — but cite the
QA artifact or a log line rather than inferring. See F8.

### 2. Is `hasStartedPlayback` the right discriminator? — Yes. Every alternative is refuted by evidence.

- **An explicit toolkit "seeking"/"changing track" signal: does not exist.** The
  `Player` protocol (`Player.swift:141-175`) exposes `isPlaying`, `isLoaded`,
  `currentTrackPosition`, `playbackStatePublisher` — no seek/transition state.
  `PlaybackState` is `started/stopped/failed/bookCompleted/unloaded`; no `.loading`.
  `isSeekingWithinSameTrack` is private to `LCPStreamingPlayer` **and is the wrong
  polarity** — it is true for same-track seeks, i.e. exactly the case that does *not*
  cause the bug. REJECT.
- **`isPlayerExpanded`: REFUTED.** `AudiobookSessionPresenter:307` sets it `true` at
  session open, before any playback. It cannot distinguish the pre-playback window
  from mid-session, which is the only distinction that matters. REJECT.
- **Session age: REJECT.** A wall-clock heuristic over a network-bound load is
  unfalsifiable and re-introduces the timing coupling this subsystem keeps paying for.
- **"A playback model is bound": REJECT.** `audiobookSession.isLoaded` already depends
  on `manager?` being non-nil, and `adoptPlaybackModel` runs before first play — so
  bound ≠ played, and the pre-playback window (the cell the overlay exists for) would
  be destroyed.
- **Track-key change (`progress.currentLocation.track.key` drift): more precise for
  THIS trigger, but narrower.** It would not cover the backgrounding-eviction trigger
  the contract itself cites at presenter `:601`, and it adds view-local "last rendered
  key" state whose stale value fails closed to a permanently hidden overlay. REJECT
  for an RC.

So: **yes, coarse, and correctly coarse in polarity.** The latch over-hides, and
over-hiding is the right default for `.downloading` and `.skeleton`. It is not the
right default for `.loadError` — see F1. Right discriminator, wrong blast radius.

One structural observation in the fix's favour, which the contract should record: the
sibling `AudiobookDownloadProgressPolicy` needed a **correction** to the same latch
(`isFetchingArchive` outranks `hasStartedPlayback`) because latching alone hid the
`.lcpa` network fetch. That correction already protects the overlay change — with the
overlay `.hidden`, the player renders, and the download **bar** still appears during
an archive fetch. The state degrades from full-screen overlay to bar, not to nothing.
That is the strongest argument for the fix and it is not currently in the contract.

### 3. Does returning `.hidden` create a hole? — YES. This is the blocker.

Yes, and it is worse than "no indicator": it makes `.loadError` **strictly
unreachable for the rest of the session** once playback has started. See F1.

### 4. Is the toolkit correctly out of scope? — Yes, deferral approved, with a required follow-up.

`Player.isLoaded` is genuinely too blunt — a single Bool conflating "never loaded",
"reloading", and "dead". The app has now compensated for it **three** times:
`recoverPlaybackForForegroundEntry()` (presenter `:601`), `PlaybackReadinessGate`'s
polling probe + `bypassReadinessGate` (`AudiobookPositionPolicy:215`), and now this.
That is a real architectural smell and the contract should name it as such rather than
call the signal "its contract, not a bug".

But the deferral decision is still correct for a 3.3.0 RC blocker: checklist trap 1
(25+ toolkit revisions with revert cycles; Findaway/OverDrive/LCP/open-access share
the infrastructure) plus mandatory cross-vendor re-validation is not a thing to do to
a branch under active QA. **Required:** file a follow-up ticket for a toolkit
`loadPhase` enum (`.never / .reloading / .ready / .failed(Error)`) and cite its key in
the commit body. "Noted in the commit body" is not a follow-up; a ticket is.

### 5. Audio continuity / the mute — defensible to defer, but the failure mode INVERTS. Tighten acceptance.

Defensible on mechanism: `avQueuePlayer.pause()` at `:201` is unconditional for any
seek and is normal; the mute self-clears at `LCPStreamingPlayer:625-631` when
`timeControlStatus` reaches `.playing`, and the 30s workItem (`:214-236`) unmutes as a
backstop. So the mute is bounded and is not a second defect *by construction*.

Not defensible as written: the contract's "the patron perceives it as audio paused
mainly BECAUSE the transport controls vanished" is an unmeasured claim about
perception, and the change **inverts the failure mode**. Today, if audio genuinely
does not resume, the patron at least sees a Downloading screen that explains the
silence. After the fix they see a normal player with working-looking transport
controls, silent. A silent failure is strictly harder for QA to re-report.

Required: the Moes Max check is **blocking, not advisory**, and the commit body must
state the measured resume behaviour (time-to-audio across a chapter seek, streaming
ON, and once on a degraded network), not "verified on device".

### 6. Are the three criteria well-formed and sufficient? — No. Deleting two was right; the three that remain do not discriminate, and one will false-red.

The instinct was correct and applied incompletely.

- **C2 will fail on a correct fix.** `grep -A3 "func loadingOverlayState"` covers
  lines 827-830 = `func`, `isLoaded`, `isDownloading`, `loadingTimedOut`. A new
  parameter placed anywhere after the third — including the natural position after
  `loadingTimedOut` — lands on 831 and is invisible to `-A3`. The gate is
  **parameter-order-dependent**. See F2.
- **C1 and C3 are shape greps, not behaviour.** All three are satisfiable by adding
  the parameter and never reading it (C1/C2), plus two test call sites that assert
  nothing in particular (C3). None can tell a correct fix from an inert one.
- **The godclass criterion is vacuous.** `AudiobookMorphingPlayerView.swift` is not in
  `scripts/godclass-loc-baseline.txt` (the six entries are AudiobookSessionManager,
  AccountsManager, MyBooksDownloadCenter, BookDetailViewModel,
  TPPSignInBusinessLogic, BorrowOperation). This changeset touches no frozen file, so
  `check-godclass-loc-freeze.sh` exits 0 whatever is written. Keep it as hygiene;
  strike it from the criteria table. Same rule that removed the other two. See F5.
- **Nothing measures the hole.** No criterion asserts `.loadError` stays reachable.
- **Structural:** the section labelled "Verification criteria" contains only greps,
  while the actual discriminating gates live unnumbered under "Tests required",
  and Acceptance then says "criteria 1 and the table" — conflating the two sections.
  Promote Tests-required #1/#2/#5 into the numbered criteria table.

### 7. Scope and size — single-module: yes. Size: SMALLER than stated. The 32-cell table is NOT overkill; keep it.

Single module, single production file (`Palace/AppInfrastructure/`). Correct for an RC.

The "~5 production lines / two call sites" is an overcount: `loadingOverlayState` has
exactly **one** call site (`:883`). `:926` is `shouldSurfaceLoadTimeout`, a different
function with a different signature. See F4.

**Keep the 32 cells.** 5 booleans = 32, mechanical, and it is the only thing in the
contract that will catch the `forceSkeletons` ordering (F7) and force the `.loadError`
cells to be decided explicitly. It is the prescribed CLAUDE.md shape and it is cheap.
One sequencing caveat: **a table asserts whatever you write in it.** If it is authored
before F1 is resolved, it will cement the hole as expected behaviour and every future
reader will read it as intentional. Resolve F1 first, then write the table.

---

## Findings

### F1 — `concern` / blocking — architecture. `.loadError` becomes unreachable for the rest of the session once playback starts.

`loadingTimedOut` has exactly one arming site: the `.skeleton` case's `.onAppear`
(`AudiobookMorphingPlayerView.swift:918-930`). If `loadingOverlayState` returns
`.hidden` whenever `hasStartedPlayback`, then mid-session:

    !isLoaded + hasStartedPlayback → .hidden → EmptyView
      → .skeleton never appears
      → .onAppear never runs
      → the 30s timer is never armed
      → loadingTimedOut stays false forever
      → .loadError is unreachable, for every vendor, for the session

Today a mid-session dead player yields a skeleton, then after 30s the load-error
overlay with a **Retry** button that calls `audiobookSession.play()`. After the fix it
yields a normal-looking player with transport controls that do nothing, forever, with
no error and no retry.

Reachable, by the contract's own citation: `AudiobookSessionPresenter.swift:601`
documents iOS evicting the AVPlayer buffer on backgrounding, flipping
`Player.isLoaded` false **mid-playback** — `hasStartedPlayback` is true by
construction there, and that comment explicitly describes the current resolution as
"shows its LoadingView; if the player doesn't reload within 30s it transitions to
LoadingErrorView." The contract cites :601 as evidence the defect is general and does
not notice that :601's scenario is precisely the one the fix silences.
`recoverPlaybackForForegroundEntry()` is a best-effort re-prime, not a guarantee.

Also reachable on the LCP stall path: `LCPStreamingPlayer:209` sets
`lastStartedItemKey = nil` on every cross-track seek, and `:645-655`
(`waitingToPlayAtSpecifiedRate` with `lastStartedItemKey == nil`) re-sets
`isLoaded = false` and re-mutes. The only escape is the toolkit's own 30s workItem
(`:214-236`), which is **LCP-only** — `OpenAccessPlayer` and `FindawayPlayer` have no
equivalent, and this view is vendor-blind.

And there is no fallback UI underneath: `NavigationHostView.swift:135-146` shows the
toolkit's `AudiobookPlayerView` (which owns `LoadingErrorView`) only on the legacy
pushed route when `in_app_playback_nav_enabled` is OFF. On the flag-ON path QA is
testing, `loadingOverlay` is the **only** loading/error surface in the app.

**Recommendation.** Your own instinct in the brief is the right answer. Add a fifth
case rather than reusing `.hidden` — e.g. `.inlineIndicator`: renders the player
normally with a small non-blocking spinner near the transport, and carries an
`.onAppear` that arms the same 30s timer. Then `(isLoaded:false, hasStartedPlayback:
true, loadingTimedOut:false)` → `.inlineIndicator`, and
`(…, loadingTimedOut: true)` → `.loadError` — real failures still surface with Retry.

If a fifth case is judged too much for an RC, the minimum acceptable alternative is to
order the guard so `loadingTimedOut` is evaluated **before** the `hasStartedPlayback`
bypass AND move the timer arming off `.skeleton.onAppear` to a container-level
`.task(id:)` keyed on `isLoaded` — but that is not smaller than the enum case, and it
silently drops the visual "something is happening" affordance. Prefer the enum case.

Either way: add a criterion asserting `.loadError` is still reachable with
`hasStartedPlayback: true`, and a test driving it. Nothing in the contract measures
this today.

### F2 — `concern` — verification. C2 is parameter-order-dependent and will false-red a correct implementation.

`grep -A3 "func loadingOverlayState"` spans `:827-830` — the `func` line plus three
parameters. A new parameter in any position after the third is invisible to it. A gate
that fails on correct code destroys the signal exactly as thoroughly as one that
cannot fail (the same PP-5191 lesson, other polarity).

**Recommendation.** Replace with a behavioural criterion:

    loadingOverlayState(isLoaded: false, isDownloading: true,
                        loadingTimedOut: false, hasStartedPlayback: true,
                        forceSkeletons: false) == .hidden

demonstrated RED on `origin/release/3.3.0` (where it does not compile — see F6 for why
that is not sufficient on its own, and what to do about it). If a grep is wanted at
all, drop `-A3` and scope by line range or use `-A8`.

### F3 — `concern` — discipline. Link 2 of the traced chain states a mechanism that does not exist.

The contract says the presenter mirrors `isLoaded`. It does not — the presenter has no
such property (`grep -n "isLoaded" Palace/Audiobooks/AudiobookSessionPresenter.swift`
returns only comments at 322 and 601). It is an unpublished computed passthrough at
`AudiobookSessionManager.swift:1176-1177`, documented at :1173-1175 as deliberately
not `@Published`.

This matters beyond accuracy: the unpublished read is why the overlay appears
simultaneously with the pause rather than on the `isLoaded` flip, and any future reader
reasoning about re-render timing from this contract will be reasoning from a false
model. Correct the paragraph and note that `hasStartedPlayback` **is** `@Published`,
which is what makes the fix work through the same coarse tick cadence.

### F4 — `warning` — discipline. `:926` is not a `loadingOverlayState` call site.

`grep -n "loadingOverlayState\|shouldSurfaceLoadTimeout"` gives 827 (decl), 845
(`shouldSurfaceLoadTimeout` decl), 883 (the only `loadingOverlayState` call), 925
(`shouldSurfaceLoadTimeout` call). There is one call site, not two.

The risk is not the line count — it is that an implementer following the contract
literally will go to `:926` and thread `hasStartedPlayback` into
`shouldSurfaceLoadTimeout`, which changes the timer-suppression logic without any of
the reasoning in F1 having been done. Correct to "one call site, `:883`", and state
explicitly whether `shouldSurfaceLoadTimeout` changes (under F1's recommendation, it
should not).

### F5 — `warning` — verification. The godclass criterion cannot fail for this changeset.

`AudiobookMorphingPlayerView.swift` is absent from `scripts/godclass-loc-baseline.txt`
(verified via `bash scripts/check-godclass-loc-freeze.sh --count` — six files, none of
them this one). The rule that removed two criteria from the first draft applies here
too. Keep the script in the pre-commit battery; strike it from the criteria table.

Separate observation, not blocking: that file is 1734 physical lines and is not under
the freeze. Worth a ratchet entry in a later changeset, not this one.

### F6 — `concern` — discipline. A compile failure is claimed as a red-before-green signal.

Tests-required #3: "their failure to compile against the new signature is itself a
red-before-green signal worth recording." CLAUDE.md is explicit that a build failure
proves nothing ("A build failure is not a kill"; `palace_mutate.py` reports `errored`
separately for exactly this). A signature change breaks compilation whether the guard
is correct, inverted, or absent.

**Recommendation.** Strike that sentence. Demonstrate red by running the new assertion
against a base-ref build with the parameter added and the guard body omitted, or by
asserting the base-ref 4-arg form returns `.downloading` for the equivalent inputs.

Related and **required** either way: the new parameter must have **no default value**.
A `hasStartedPlayback: Bool = false` would let the existing tests and the `:883` call
site compile unchanged, silently preserving today's behaviour at the one call site
that matters — the exact failure mode the contract's own compile-break reasoning was
reaching for. State it as a constraint.

### F7 — `warning` — architecture. `forceSkeletons` ordering is left ambiguous.

The contract says the new guard means "never `.downloading`, never `.skeleton`". Read
literally that would defeat the PP-4797 QA override, which must stay first
(`:833 if forceSkeletons { return .skeleton }`). State the invariant explicitly:
`forceSkeletons` wins unconditionally, the `hasStartedPlayback` bypass sits after it.
The 32-cell table will enforce this once the ordering is decided — but decide it in the
contract, not in the table.

### F8 — `warning` — verification. `isDownloading == true` at the moment of the seek is inferred, not measured.

The step-3 claim that the overlay resolves to the determinate `.downloading` state
(rather than `.skeleton`) depends on `presenter.isDownloading` being true during an
LCP cross-track seek. The contract sources this from
`AudiobookDownloadProgressPolicy`'s doc-comment. Cite the build-509 QA artifact,
screenshot, or a log line. Low risk — the fix collapses both to `.hidden` — but the
contract asserts a specific visual and should be able to show it.

### F9 — `pass` — architecture. Toolkit deferral is correct; the smell is real.

Approved per the reasoning in Q4. Required deliverable: a filed follow-up ticket for a
`loadPhase` enum on the toolkit `Player` protocol, keyed in the commit body. Also worth
one line in the contract acknowledging that this is the third app-side compensation for
the same blunt signal — that is the honest framing, and it is what justifies the ticket.

### F10 — `pass` — scope. Single-module, correctly sized, table correctly sized.

One production file, one call site, plus tests. Right shape for an RC blocker. The
32-cell enumeration is not overkill — keep it, author it after F1 is resolved.

### F11 — `pass` — verification. Checklist obligations are correctly carried.

`CrossVendorSmokeTests` (trap 1, §8.3), sim-first via TOC seek (trap 5 — TOC seek is
explicitly the sanctioned decoder-free position driver), device deferral for audio,
full-suite `verify-pr.sh --quick` rather than `-only-testing`, PalaceWiringTestCase.
All correct and all cited to the right traps.

Minor: `AudiobookMorphingPlayerViewTests` currently extends `XCTestCase`
(`:23`). The contract's PalaceWiringTestCase requirement is scoped to *new* classes;
since this class is being extended substantially, rebase it onto
`PalaceWiringTestCase` in the same change.

---

## Required before this contract is implementable

1. **F1** — decide and document the `.loadError` disposition; prefer the fifth enum
   case. Add a criterion and a test that `.loadError` stays reachable with
   `hasStartedPlayback: true`.
2. **F2** — replace C2 with a behavioural criterion.
3. **F3, F4** — correct the two factual errors in the traced chain.
4. **F6** — strike the compile-failure-as-red claim; add "no default value" as a
   stated constraint.
5. **F7** — state the `forceSkeletons` ordering invariant.
6. **F5** — move the godclass check out of the criteria table.
7. **F9** — file the toolkit follow-up ticket; cite its key.
8. **Q5** — make the Moes Max audio check blocking, with the measured resume time in
   the commit body.

Re-request review once the contract is revised. The diagnosis and the choice of
discriminator are sound — this is a blast-radius correction, not a redesign.

---

# Addendum — coordinator's Phase 3.5 class scan (survivor #2)

**Verdict unchanged: BLOCKED.** Survivor #2 is **REFUTED as stated**, and latching it
would be actively harmful. But the scan pointed at the right neighbourhood: there is a
real second defect there, of a different shape, which a latch-shaped scan cannot see.

## F12 — `fail` — architecture. Do NOT latch `shouldSurfaceLoadTimeout`. It is the last remaining annunciator.

### The arming claim is false

The message says the timer is "armed at :86 while `!isLoaded`". It is not. The
complete set of sites:

    grep -n "loadingTimedOut" Palace/AppInfrastructure/AudiobookMorphingPlayerView.swift
    88   @State private var loadingTimedOut = false     ← declaration
    830  loadingTimedOut: Bool,                          ← pure-function parameter
    836  if loadingTimedOut { return .loadError }        ← read
    886  loadingTimedOut: loadingTimedOut,               ← read at the call site
    905  loadingTimedOut = false                         ← Retry button
    923  loadingTimedOut = false                         ← .skeleton .onAppear reset
    929  loadingTimedOut = true                          ← the timer body

And there is no reactive hook on the signal:

    grep -n "\.onChange(of:\|\.task(\|\.onReceive(" …/AudiobookMorphingPlayerView.swift
    # 325 (playbackModel != nil), 334 (toastMessage), 1589/1648 (slider/rate). No isLoaded.

`:86-87` is a **doc comment on a `@State` declaration**; it arms nothing. Its text —
*"while `!isLoaded`, a 30s timer arms"* — asserts a mechanism no code implements.
That is itself a finding (F14): the comment is the source of the coordinator's
reading, and it will mislead the next reader the same way.

The sole arming site is `.skeleton`'s `.onAppear` (`:918-930`).

### Consequence: an ordinary cross-track seek cannot produce a load error

Two independent blocks, either sufficient:

1. **The skeleton never appears on the PP-5205 path.** The contract's own premise for
   the defect is `isDownloading == true` (that is what makes it the determinate
   "Downloading… NN%" screen rather than the shimmer). With `isDownloading` true the
   state is `.downloading`, so `.skeleton` is not rendered, `.onAppear` never fires,
   and the timer is never armed. The two survivors are on **mutually exclusive
   branches** of the same `switch` — `shouldSurfaceLoadTimeout` is unreachable on
   exactly the input that triggers `loadingOverlayState`'s defect.
2. **Even when armed, the closure re-reads live state at fire time** (`:927-932`).
   It does not latch `loadingTimedOut` at arming; it evaluates
   `shouldSurfaceLoadTimeout(isLoaded: audiobookSession.isLoaded, …)` at +30s. A
   chapter seek that completes in the normal 1-3s leaves `isLoaded == true`, the
   predicate returns false, and nothing happens. The function is already
   self-disarming against transient flips.

So: **not "the same defect with a worse outcome", and not fired on every seek.**

### The narrow case where it does fire is CORRECT behaviour

`shouldSurfaceLoadTimeout` surfaces the error only when the seek genuinely stalls for
≥30 s with no download in flight — the `LCPStreamingPlayer:645-655` path
(`waitingToPlayAtSpecifiedRate` with `lastStartedItemKey == nil`, re-set by the
`lastStartedItemKey = nil` at `:209` on every cross-track seek) on a degraded network.
In that state the player **is** broken and the patron **should** be told, with the
Retry button at `:904-906` that calls `audiobookSession.play()`.

### Why latching it is the wrong direction

This sharpens Q3 exactly as the coordinator anticipated. Latching both functions on
`hasStartedPlayback` would mean, mid-session:

    loadingOverlayState      → .hidden   (skeleton + downloading suppressed)
    shouldSurfaceLoadTimeout → false     (error suppressed)

The patron gets **nothing, permanently, for any mid-session player death, on every
vendor** — no indicator, no error, no Retry, and no toolkit fallback underneath
(`NavigationHostView.swift:135-146`: the toolkit's `LoadingErrorView` renders only on
the legacy route with `in_app_playback_nav_enabled` OFF). That is F1 made total and
deliberate rather than accidental.

`shouldSurfaceLoadTimeout` is not a second instance of the defect — it is the
**backstop that makes F1 survivable**. Under F1's recommendation it must become *more*
reachable, not less: the `.inlineIndicator` case carries the `.onAppear` that arms the
timer, so a genuinely dead mid-session player still reaches `.loadError` after 30 s.
The two changes are coupled in the **opposite** direction from the proposal.

**Recommendation: leave `shouldSurfaceLoadTimeout`'s predicate unchanged.** Do not add
`hasStartedPlayback` to it. Record the reasoning in the contract's Scope-out table, so
the next class scan does not re-propose it.

## F13 — `concern` — architecture. The real second defect in that neighbourhood: the timer has no cancellation, and PP-5205's repro is the stacking trigger.

The scan found the right file and the wrong shape. `:924-931`:

    loadingTimedOut = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { … }

There is no `DispatchWorkItem` handle and no cancellation. Every `.skeleton` appearance
schedules **another** un-cancellable 30 s timer. SwiftUI re-fires `.onAppear` each time
the `.skeleton` branch is re-entered, so N stalled-then-recovered seeks leave N timers
in flight, each independently evaluating the live predicate 30 s after its own arming.
QA's repro — *"repeats every time"* — is precisely the stacking trigger.

This is the identical bug the toolkit already fixed **one layer down**, with the fix
sitting in a file the contract already cites (`LCPStreamingPlayer.swift:211-214`):

    // Cancel any prior fallback from an earlier play(at:) so stale timers don't
    // fire after the queue has advanced past the startup window. Without this,
    // rapid re-presentations stack multiple timers that all log at once.
    loadTimeoutWorkItem?.cancel()

Same structural sibling relationship as `AudiobookDownloadProgressPolicy` → the
overlay: a correct mechanism built one layer down and not applied one layer up. It is
also adjacent to checklist trap 2 (the `LCPStreamingPlayer` 30 s DispatchWorkItem
firing after the operation completed), which is the production-crash precedent for
exactly this shape.

**Recommendation.** Hold the work item in `@State`, cancel on re-arm and on
`.onDisappear`. ~6 LOC, same file, and it is a prerequisite for F1 — once
`.inlineIndicator` arms the timer on every mid-session flip (rather than only on the
rarer skeleton path), the arming rate goes **up** and unbounded stacking becomes the
dominant failure mode rather than a latent one.

A latch-shaped class scan could not have found this: the defect is timer lifecycle,
not a missing session-phase parameter. Worth noting for the detector's own limits.

## F14 — `warning` — discipline. The `:86-87` doc comment asserts a mechanism the code does not implement.

*"Loading-timeout state: while `!isLoaded`, a 30s timer arms"* — no code arms on an
`isLoaded` transition; arming is solely `.skeleton`'s `.onAppear`. This comment is
the direct source of the coordinator's mis-reading of survivor #2, and it is the
second doc-vs-code divergence in this review (see F3, where
`AudiobookSessionManager:1173-1175` is correct and the contract's model was not).
Correct it in this changeset — it is one line and it is load-bearing for how the next
reader reasons about the error path.

## F15 — `concern` — verification. The refined detector predicate contradicts the scope conclusion it is being used to justify.

The message states the detector "must key on *returns a blocking UI state*, not *takes
a readiness signal*". Apply that predicate to the two survivors:

| function | returns | blocking UI state? |
|---|---|---|
| `loadingOverlayState` (:827) | `LoadingOverlayState` | yes — `.downloading` / `.loadError` / `.skeleton` replace the player |
| `shouldSurfaceLoadTimeout` (:845) | `Bool` | **no** — it *gates* a state, it does not return one |

Under the refined predicate the survivor count is **1, not 2** — which is exactly the
conclusion F12 reaches from the reachability trace. The detector refinement and the
scope decision point the same way, and they disagree with the proposal to fix both.
Trust the refined predicate; it is right.

This matters beyond bookkeeping. A detector validated against a survivor set that
includes a false positive will be tuned to keep firing on it, and the repo's canon on
detectors (CLAUDE.md CI contract #4 — dry-run for zero false positives before landing)
is specifically about not doing that. **Validate the detector against the corrected
survivor set of 1.** Also note that neither predicate finds F13, so the detector's
"clean" result must not be read as "this file is now clean".

## Revised scope recommendation

Still within the Phase 3.5 small-class budget (≤3 survivors, ≤50 LOC), and still a
single module:

| # | change | ~LOC |
|---|---|---|
| 1 | `loadingOverlayState` + `hasStartedPlayback` + the `.inlineIndicator` case (F1) | ~20 |
| 2 | Timer cancellation via a held `DispatchWorkItem` (F13) | ~6 |
| 3 | Fix the `:86-87` doc comment (F14) | 1 |
| — | **`shouldSurfaceLoadTimeout`: NO CHANGE** — record in Scope-out with F12's reasoning | 0 |

Two survivors addressed, one explicitly refused with a written rationale. Add to the
32-cell table a test that a genuinely stalled mid-session player still reaches
`.loadError` with `hasStartedPlayback: true` — that single cell is what distinguishes
this design from the one the coordinator proposed, and nothing in the contract
currently asserts it.

---

# Addendum 2 — rev 3 design questions (arming site, inline affordance)

Rev 3's four acceptances are correctly reasoned and I have nothing to add to them.
Answers to the two open design questions follow. Q2's premise is **refuted** — the bar
cannot cover this — and the refutation is definitional, so it is worth reading first.

## A1 — Lift the arming out of the case bodies. Keep `DispatchWorkItem`; do NOT use `.task(id:)`.

**Lift it — but not for the reason you might expect, and I want to name the argument I
tried and discarded.**

I first reached for a clock-reset correctness argument: per-case arming means a
`.skeleton` → `.inlineIndicator` transition re-arms and restarts the 30 s clock. On
tracing it, that transition is **near-unreachable**: `.skeleton` requires
`!hasStartedPlayback`, `.inlineIndicator` requires `hasStartedPlayback`, and the latch
can only rise on an `AudiobookSessionState.playing` emission, which implies the player
loaded — so the path passes through `.hidden` in between. The latch is one-way, so
there is no oscillation back. **That argument is weak; do not use it.**

The three that hold:

1. **The arming condition is a property of the state, not of which case body drew.**
   This is exactly what the `:86-87` comment already *claims* — *"while `!isLoaded`, a
   30 s timer arms."* F14 is currently scoped as "fix the comment to match the code."
   Lifting lets you fix it the other way round: make the code match the design the
   comment describes. That is the better resolution of F14, and it costs nothing extra
   because you are already editing that region.
2. **Two cases with identical lifecycle obligations is the drift shape you named**, and
   F13 makes each branch heavier, not lighter: per-case, `.inlineIndicator` must
   duplicate reset + arm + cancel-on-rearm + cancel-on-disappear. Four things to keep
   in sync across two branches.
3. **F13's cancellation is inherently cross-case.** The work-item handle is view-level
   `@State` already. With per-case arming you must reason about which branch cancelled
   it and whether a branch swap ordered disappear-before-appear. One arming site
   deletes that entire question.

**Shape.** Bind the state once and switch on it, then arm from a single modifier:

    let state = Self.loadingOverlayState(…)     // computed once, not twice
    switch state { … }                          // case bodies purely presentational
    .onChange(of: state) { … arm / cancel … }

`LoadingOverlayState` has no associated values, so `Equatable` is synthesised — the
`onChange` costs nothing. Key on the **enum**, not on `!isLoaded`: the enum already
encodes `forceSkeletons` and the fired timeout, so you arm for `.skeleton` /
`.inlineIndicator` only, and `.downloading` stays suppressed — preserving the existing
`isDownloading` guard in `shouldSurfaceLoadTimeout` rather than re-deriving it.

**Use `DispatchWorkItem`, not `.task(id:)`.** I considered recommending `.task(id:)`
— structured cancellation would subsume F13 for free — and rejected it on precedent:

    grep -rn "\.task(id:" Palace/   →  0 matches
    grep -rn "DispatchWorkItem" Palace/  →  23 matches, incl. Palace/Audiobooks/NowPlayingCoordinator.swift

`DispatchWorkItem` is the established idiom in this very module, and F13's whole
justification is *mirroring the toolkit's existing fix* at `LCPStreamingPlayer:214`
(`loadTimeoutWorkItem?.cancel()`, also :281/:626). Introducing a concurrency primitive
with zero precedent in `Palace/` into a 1734-line view on an RC branch is the wrong
trade, however much tidier it reads. Mirror the toolkit exactly; it keeps your ~6 LOC
estimate and it is the more reviewable diff.

**Caveat to write down.** Keying on the state inherits F3's coarseness —
`audiobookSession.isLoaded` is not `@Published`, so arm/cancel fires on the next render
tick, not at the instant of the flip. That is acceptable **because** the fire-time
predicate re-reads live state and self-disarms (F12). Record it, or someone will later
"fix" the latency by making `isLoaded` published and be surprised at what re-renders.

## A2 — REFUTED: the bar cannot cover this. It is suppressed by definition in exactly this state.

This is the cleanest answer in the review, and it is definitional rather than empirical.

    static func shouldShowPlayerDownloadBar(isDownloading:hasStartedPlayback:isFetchingArchive:) -> Bool {
        if isFetchingArchive { return true }
        return isDownloading && !hasStartedPlayback
    }

`.inlineIndicator` exists **only when `hasStartedPlayback == true`** — that is the
definition of the case. So the second clause evaluates `isDownloading && false` =
**false**, unconditionally. The bar can only appear via `isFetchingArchive`, which is
`archiveProgress != nil` (`AudiobookSessionPresenter:157`) — the `.lcpa` **network
fetch**, which on a mid-session chapter seek has long since completed.

So the bar and `.inlineIndicator` are keyed on **the same latch with opposite intent**:
the bar is suppressed precisely when `.inlineIndicator` exists. Reusing it is not
merely insufficient, it is impossible without un-latching the bar — which would
re-introduce the exact defect `AudiobookDownloadProgressPolicy` was written to fix
(the 37 % → 62 % bar beside working transport controls, device recording build 505).

`.inlineIndicator` must therefore own its affordance. Which raises the question you did
not ask but should have:

### The visible indicator is the optional half, and it carries a flicker risk

Separate the case's two jobs:

- **Load-bearing (required):** arm the 30 s timer so `.loadError` stays reachable.
  This is what closes F1's hole. Everything in the contract depends on it.
- **Cosmetic (optional):** the visible affordance.

A normal chapter seek completes in 1-3 s. An immediately-visible spinner is therefore a
**new visible behaviour on the exact flow QA is testing on the RC** — a plausible new
report ("spinner flashes on every chapter change"), which is how a blocker fix earns a
follow-up ticket. Three options:

| | behaviour | risk | LOC |
|---|---|---|---|
| (a) | no visual; renders the player unchanged, timer armed | none | 0 extra |
| (b) | immediate spinner | flicker on every seek | ~5 |
| (c) | spinner delayed ~2 s, armed/cancelled alongside the 30 s item | none | ~5 |

**Recommend (c).** Because F13 already gives you a held-and-cancelled work item, the
delay is a second item on the same handle pattern — genuinely ~5 LOC, not a new
mechanism. It gives you "something rather than nothing" on a real stall while a normal
seek shows nothing at all.

**If the budget is tight, (a) is the correct RC call** and (c) is the follow-up. (a)
still closes F1 completely: the full-screen Downloading screen is gone and `.loadError`
is still reachable at 30 s. What the patron sees is transport controls that briefly do
not respond, then audio — which is what a chapter seek looks like on any player.

**If you take (a), rename the case.** A case named `.inlineIndicator` that renders no
indicator is a lie in the type, and the next reader will add one. `.playerVisible` or
`.awaitingReload` says what it does.

### One more table cell

Mid-session with `isFetchingArchive == true` (streaming LCP, archive still landing,
patron seeks a chapter), the bar **does** show — and under (b)/(c) `.inlineIndicator`
would draw a second concurrent progress affordance. Do **not** fix this by adding
`isFetchingArchive` as a sixth parameter; that doubles the table to 64 cells for one
cosmetic case. Handle it at the view level if at all, and add the cell as a device-
verification item rather than a unit assertion.

## Minor, out of scope — CLAUDE.md deployment-target drift

`grep -m3 IPHONEOS_DEPLOYMENT_TARGET Palace.xcodeproj/project.pbxproj` → `17.0`, while
CLAUDE.md's Build & Test section says "iOS 16.0+ deployment target." Not this
changeset's problem and explicitly not something to bundle into an RC fix, but worth a
one-line follow-up — it is the kind of stale prose that sends the next reader down a
wrong path, which is precisely what F14 documents happening to rev 1.

## Standing verdict

**BLOCKED** until the revised contract is posted with F1's `.loadError` disposition
resolved. Rev 3 resolves every finding I raised on rev 2 and the reasoning is sound;
what remains is mechanical. Re-request review on the revised contract, or on the
implementation diff if you prefer to review both at once.
