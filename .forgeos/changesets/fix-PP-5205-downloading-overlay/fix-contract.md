# Fix-contract — PP-5205: a chapter seek replaces the player with a full-screen Downloading state

## The defect, traced end to end

QA, TestFlight build 509, LCP streaming, Blocker:

> Choose a later chapter from the TOC → a Downloading screen appears and audio pauses.
> Repeats on every later-chapter selection.

The chain, verified in source rather than inferred:

1. `LCPStreamingPlayer.play(at:)` (`ios-audiobooktoolkit/.../LCPStreamingPlayer.swift:204-209`):

       // Only show loading state for heavy operations (rebuilds or track changes)
       if !isSeekWithinSameTrack {
         isLoaded = false
         suppressAudibleUntilPlaying = true
         avQueuePlayer.isMuted = true

   A later chapter is a different track, so this fires on every such seek. The
   toolkit is signalling "changing tracks", deliberately and briefly.

2. **[rev2 — CORRECTED]** The presenter does NOT mirror `isLoaded`; it has no such
   property. It is an unpublished computed passthrough on the session manager
   (`AudiobookSessionManager.swift:1176`), whose own doc says *"Not `@Published`; the
   view re-reads it on `isPlaying`/position ticks."* That is WHY the overlay appears
   simultaneously with the pause rather than on the flip itself. The fix survives this
   (`hasStartedPlayback` IS `@Published`), but rev 1's model was false and is corrected
   here rather than left to mislead the implementer.

3. `AudiobookMorphingPlayerView.loadingOverlayState` (`Palace/AppInfrastructure/AudiobookMorphingPlayerView.swift:827-838`):

       guard !isLoaded else { return .hidden }
       if isDownloading { return .downloading }

   turns that transient signal into `.downloading` — a FULL-SCREEN determinate
   "Downloading… NN%" state that replaces the player.

**The overlay has no notion of "we have already been playing."** Its only input is
whether the player is loaded *at this instant*, so it cannot tell the pre-playback
window (no player yet — overlay correct) from a mid-session track change (player
exists, patron is listening — overlay wrong).

**This is a known shape in this very subsystem, already solved one layer down.**
`AudiobookDownloadProgressPolicy.shouldShowPlayerDownloadBar` latches on
`hasStartedPlayback` precisely so the download BAR does not reappear mid-listen; its
doc says using live state "would re-summon the bar on every pause — the patron
pauses, a download bar appears on a book they have been listening to for twenty
minutes, and it reads as though pausing broke something." The overlay makes the
identical mistake one layer up, where the cost is the entire player rather than a bar.

The same `isLoaded` flip is ALSO documented at `AudiobookSessionPresenter.swift:601`
for a different trigger — iOS evicting the AVPlayer buffer on backgrounding — where
it was patched with a bespoke `recoverPlaybackForForegroundEntry()` rather than by
fixing the overlay's input set. PP-5205 is the second trigger of the same defect.

## Scope (in)

| File | Change |
|------|--------|
| `Palace/AppInfrastructure/AudiobookMorphingPlayerView.swift` | **[rev2]** `loadingOverlayState` gains `hasStartedPlayback` **with NO default value** — a `= false` would let the call site compile unchanged and silently keep today's behaviour. Mid-session it resolves to a NEW fifth case `.inlineIndicator`, **not `.hidden`** — see F1 below. |
| `Palace/AppInfrastructure/AudiobookMorphingPlayerView.swift` | **[rev2]** ONE call site: `:883`. Rev 1 said `:884` and `:926`; `:926` is `shouldSurfaceLoadTimeout`, a different function. |
| `Palace/AppInfrastructure/AudiobookMorphingPlayerView.swift` | **[rev3, F13]** Hold the 30s timer in a `DispatchWorkItem` and cancel the prior one on re-arm, mirroring `LCPStreamingPlayer:214`. ~6 LOC. |
| `Palace/AppInfrastructure/AudiobookMorphingPlayerView.swift` | **[rev3, F14]** Correct the `:86-87` doc comment to describe the actual arming site. 1 LOC. |
| — | **NO presenter change needed.** Verified by running the criteria rather than assuming: `AudiobookSessionPresenter:134` already publishes a LATCHED `hasStartedPlayback`, set on first real play (`:560` — `if playing && !hasStartedPlayback`) and cleared only on session teardown (`:347`, `:439`). It is already latched rather than live, which is the property that matters. The view already threads it at `:748` — into `shouldShowPlayerDownloadBar`. `loadingOverlayState` simply never received it. |

**This makes the fix ~5 production lines**, not a new mechanism: add the parameter,
add one guard, thread it at the two call sites. The mechanism was built correctly for
the bar and then not applied to the overlay sitting directly above it.

### **[rev2] F1 (architect BLOCKER) — `.hidden` makes `.loadError` unreachable for the session**

Verified: `loadingTimedOut` has exactly ONE arming site — `case .skeleton:`'s `.onAppear`
(`:916-931`). Returning `.hidden` renders `EmptyView`, so the skeleton never appears, the
30s timer never arms, and **`.loadError` becomes unreachable for the rest of the session,
for every vendor.** A genuinely dead mid-session player would show a normal-looking
player with dead transport controls, no error and no Retry — strictly worse than today,
where the Downloading screen at least explains the silence.

The case is reachable, and by my own citation: `AudiobookSessionPresenter:601` documents
iOS evicting the AVPlayer buffer mid-playback, where `hasStartedPlayback` is true by
construction. Rev 1 cited that as proof the defect is general without noticing it is the
case the fix would silence. Also reachable via `LCPStreamingPlayer:209`
(`lastStartedItemKey = nil`) → `:645-655` re-setting `isLoaded = false`, whose only
escape is the toolkit's LCP-only 30s workItem — and this view is vendor-blind. There is
no fallback underneath: `NavigationHostView.swift:135-146` shows the toolkit's
`LoadingErrorView` only on the legacy route with the flag OFF.

**Resolution — a fifth case, `.inlineIndicator`.** Mid-session with the player not
loaded: render the PLAYER (transport controls live, no full-screen takeover) with a
small non-blocking indicator, AND arm the 30s timer so a real failure still falls
through to `.loadError`. The latch suppresses the *takeover*, never the *failure path*.

**[rev3] `shouldSurfaceLoadTimeout` is NOT latched, and the reason is stronger than rev 2's.**
My Phase 3.5 scan flagged it as a sibling; that is WITHDRAWN on reachability, not just
on direction. It is **unreachable on the exact input that defines PP-5205**: the premise
is `isDownloading == true` (that is what makes the screen the determinate "Downloading…
NN%" rather than the shimmer), which selects `.downloading`, so `.skeleton` never
renders, its `.onAppear` never fires, and the timer never arms. The two are on mutually
exclusive branches of one `switch`. It also re-reads live state at fire time (`:927-932`)
rather than latching at arm time, so a seek completing in the normal 1-3s already
self-disarms it.

Where it DOES fire — a genuine ≥30s stall with no download in flight
(`LCPStreamingPlayer:645-655`) — the player really is broken and the error is correct,
with a working Retry at `:904`. **It is not a second instance of the defect; it is the
backstop that makes F1 survivable**, and under `.inlineIndicator` it must become MORE
reachable, not less. Latching both would give `.hidden` AND `false` mid-session: the
patron sees nothing, permanently, every vendor, with no toolkit fallback underneath
(`NavigationHostView:135-146` is legacy-route only).

### **[rev3] F13 — the 30s timer is never cancelled, and stacks on every re-entry**

The real second defect, and a different shape from the one the scan was looking for.
`:924-931` schedules `DispatchQueue.main.asyncAfter` with **no `DispatchWorkItem` handle
and no cancellation** — verified: the file contains zero `DispatchWorkItem`. Every
`.skeleton` re-entry stacks another timer, and QA's *"repeats every time"* is the
stacking trigger.

The toolkit fixed this identical bug one layer down, in a file this contract already
cites: `LCPStreamingPlayer:44/214/235/281/626` holds `loadTimeoutWorkItem` and cancels
it, with the comment *"rapid re-presentations stack multiple timers."* Same sibling
relationship as `AudiobookDownloadProgressPolicy` → the overlay: solved below, not
applied above.

This is also a PREREQUISITE for F1 rather than an optional extra — once `.inlineIndicator`
arms on every mid-session flip, the arming rate rises and stacking becomes dominant.

**A latch-shaped scan could not have found it.** It is timer lifecycle, not a missing
parameter, which is why a clean run of the new detector must NOT be read as "this file
is clean".

### **[rev3] F14 — the doc comment at `:86-87` describes a mechanism no code implements**

It reads *"while `!isLoaded`, a 30s timer arms"*. Nothing arms on `isLoaded`: there is no
`.onChange(of:)`/`.task`/`.onReceive` hook on it anywhere in the file. The only arming
site is `.skeleton`'s `.onAppear`. Fix the comment — it is what sent rev 1's analysis
down the wrong path.

## Scope (out)

- **The toolkit.** `LCPStreamingPlayer`'s `isLoaded = false` on track change is its
  contract, not a bug — the app is misreading a "changing tracks" signal as "no player
  yet". Changing the toolkit would need a submodule bump and cross-vendor
  re-validation (checklist trap 1: 25+ revisions with revert cycles), for a defect that
  is entirely on the app side.
- **`avQueuePlayer.isMuted` / `suppressAudibleUntilPlaying`.** The brief audio
  suppression during a track change is deliberate toolkit behaviour. The patron
  perceives it as "audio paused" mainly BECAUSE the transport controls vanished behind
  a full-screen overlay; fixing the overlay is the load-bearing half. If audio still
  audibly gaps on device after this fix, that is a separate finding — see Acceptance.
- `AudiobookDownloadProgressPolicy` — already correct; it is the model being copied.
- The `recoverPlaybackForForegroundEntry` backgrounding hack — out of scope, but note
  in the commit body that this fix addresses its root cause and the hack may be
  removable later with its own verification.

## Verification criteria (each demonstrated RED on `origin/release/3.3.0` first)

Measured on `origin/release/3.3.0` before writing any code:

| # | criterion | target | observed | red? |
|---|-----------|--------|----------|------|
| C1 | `grep -c hasStartedPlayback …/AudiobookMorphingPlayerView.swift` | ≥4 | `1` | yes |
| C2 | **[rev2]** `grep -A8 "func loadingOverlayState" … \| grep -c hasStartedPlayback` | ≥1 | `0` | yes |
| C3 | `grep -c "hasStartedPlayback: true" PalaceTests/AppInfrastructure/AudiobookMorphingPlayerViewTests.swift` | ≥2 | `0` | yes |
| C4 | **[rev2]** `grep -c "case inlineIndicator" …/AudiobookMorphingPlayerView.swift` | ≥1 | `0` | yes |
| C5 | **[rev2]** `grep -c "inlineIndicator" PalaceTests/AppInfrastructure/AudiobookMorphingPlayerViewTests.swift` | ≥1 | `0` | yes |

**[rev2] C2 was widened from `-A3` to `-A8`.** At `-A3` the window covers only `:827-830`,
so a parameter added in the natural position (after `loadingTimedOut`) is invisible and a
CORRECT fix would false-red. A criterion that fails a correct fix is as useless as one
that passes a broken one.

**[rev3] Detector validation set is 1 survivor, not 2.** Under the refined predicate —
*returns a blocking UI state* — `shouldSurfaceLoadTimeout` does not qualify: it returns
`Bool`, gating a state rather than returning one. My scope conclusion and my own detector
refinement contradicted each other and the detector was right. Validating the detector
against a 2-survivor set would have tuned it to keep firing on a false positive, which is
exactly what CI contract #4 forbids.

**[rev2] The god-class criterion is DELETED as vacuous.**
`AudiobookMorphingPlayerView.swift` does not appear in `scripts/godclass-loc-baseline.txt`
(verified: 0 matches, 6 entries, none this file), so the check could never fail for this
changeset. Third vacuous criterion caught by running rather than assuming.

**Two criteria from the first draft were DELETED because they were already green**, and
a criterion that cannot fail is not a gate (the PP-5191 lesson, twice over):
`grep -c loadingOverlayState PalaceTests/` already matched — the SUT has a test file —
and `grep -c hasStartedPlayback …/AudiobookSessionPresenter.swift` already returned `4`,
because the latch is pre-existing. Neither would have measured this change.
- Mutation ≥ 80% diff-only on `AudiobookMorphingPlayerView.swift`
- `scripts/check-godclass-loc-freeze.sh` exit 0 — `AudiobookSessionManager` is frozen and
  this changeset must not grow it (the PP-5191 lesson: land by extracting)
- `python3 scripts/lint-test-quality.py --changed origin/release/3.3.0` exit 0
- Every new test class extends `PalaceWiringTestCase` (the other PP-5191 lesson)

## Tests required

1. **The regression.** `loadingOverlayState(isLoaded: false, isDownloading: true, hasStartedPlayback: true)`
   ⇒ `.hidden`. Must fail on `origin/release/3.3.0`, where it returns `.downloading`.
2. **The pre-playback window is preserved.** Same inputs with `hasStartedPlayback: false`
   ⇒ `.downloading`. This is the cell that must NOT change — the overlay exists for it.
3. **Full table.** Every (isLoaded × isDownloading × loadingTimedOut × hasStartedPlayback ×
   forceSkeletons) combination asserted, per CLAUDE.md's states×events rule. 32 cells;
   enumerate rather than sample — now 5 states across 32 input cells. The existing
   `AudiobookMorphingPlayerViewTests` covers the 4-argument form and those call sites must
   be updated. **[rev2]** Rev 1 called their failure to compile "a red-before-green
   signal"; that is struck — CLAUDE.md is explicit that a build failure is not a kill and
   proves nothing about test strength.
4. **The latch is a latch.** `hasStartedPlayback` stays true across a pause — driven
   through the presenter (`isPlaying` false→true→false), not by setting the flag directly,
   or it proves only that a Bool stores a value. This pins PRE-EXISTING behaviour the fix
   now depends on; if the latch ever became live, the overlay would return on every pause
   and PP-5205 would reappear in a new disguise.
5. **Load-error still reachable.** A genuine timeout with `hasStartedPlayback: false`
   still yields `.loadError`; the fix must not suppress real failures.
6. **Session teardown clears the latch**, so the next open shows the overlay correctly.
7. **[rev2, F1] The failure path survives the latch.** Mid-session with the player not
   loaded, the 30s timer ARMS and a real failure still reaches `.loadError`. This is the
   test that would have caught rev 1's hole, and it must fail against a `.hidden`
   implementation.
8. **[rev3, F1/F12] The stalled mid-session player still reaches `.loadError`.**
   `hasStartedPlayback: true`, player not loaded, no download, timer fires ⇒ `.loadError`
   with a working Retry. **This single cell is what separates this design from rev 1's**,
   and nothing in rev 1 or rev 2 asserted it.
9. **[rev3, F13] Timer cancellation.** Re-entering the arming path does not leave the
   prior timer live — drive two arms and assert exactly one fire.
10. **[rev2] No default value.** A test or grep asserting the new parameter is required at
   the call site, so the compiler cannot silently preserve today's behaviour.

## Acceptance

- All criteria pass; criteria 1 and the table demonstrated RED on the base ref first.
- `CrossVendorSmokeTests` green (checklist §8.3 — mandatory for any audiobook PR).
- `AudiobookOpenStateRaceTests`, `AudiobookContentGateTests`, `AudiobookPositionRestoreTests` green.
- `verify-pr.sh --quick` — FULL suite, not `-only-testing`. PP-5191 shipped a
  pollution source because scoped runs cannot see cross-suite effects.
- **Sim repro first** (checklist trap 5: TOC seek is explicitly listed as exercising
  position paths without the audio decoder), **then device verification on Moes Max** —
  audio continuity across a chapter seek cannot be judged on the simulator.
