---
name: swarm_eefef87a-contract-B-AudiobookCrossVendorSmoke
type: immutable
status: active
created: 2026-05-26T15:00:00Z
last_refresh: 2026-05-27
freshness_window: never
owners: [audiobook]
description: Module B — Audiobook cross-vendor smoke (Swift tests only)
---

# Module B — Audiobook cross-vendor smoke (Swift tests only)

**Improvement #2 from the A+ posture push (Swift portion).** Memory pin `reference_audiobook_toolkit_risk_profile.md` is load-bearing — read before writing. Module C owns the `scripts/verify-pr.sh` gating change; this module owns only the Swift smoke-test file that the gate invokes.

## Scope correction up front

The four vendors in current code are: **LCP, BearerToken (Overdrive uses this), OpenAccess, LocalFile**. `Findaway` is NOT a vendor in `Palace/Audiobooks/Vendors/` — `grep findaway` returns only a catalog string constant in `TPPOPDSAcquisitionPath.swift`. The risk-profile memory says "Findaway/OverDrive/LCP/open-access share the same player infrastructure" but the active adapter set in the iOS-core repo is the four listed above. Smoke the four that exist; note the absence of Findaway in the test header so future readers don't think it was missed.

## In-scope files (exclusive write)

- NEW `PalaceTests/Audiobooks/CrossVendorSmokeTests.swift` — XCTestCase named `AudiobookCrossVendorSmokeTests`, parameterized over the four adapter types
- MAY EXTEND `PalaceTests/Audiobooks/Mocks/` — only if a vendor's smoke needs a mock that doesn't already exist. Document each new mock in the test's header comment.

## OFF-LIMITS for this module

- `scripts/verify-pr.sh` (Module C)
- `Palace/Network/`, `Palace/MyBooks/`, `Palace/Accounts/` (Module A)
- `Palace/Reader2/`, `PalaceTests/Contract/` (Module D)
- `docs/architecture/` (Module C owns the new ADR)
- `Palace/Audiobooks/` production code — smoke tests should exercise via existing public seams (`AudiobookVendorAdapter`, `AudiobookLoader`, `PlaybackBootstrapper`); if a seam doesn't exist, STOP and escalate to the architect rather than adding a production hook.

## Test contract (LOCKED)

```swift
final class AudiobookCrossVendorSmokeTests: XCTestCase {
    // SMOKE-MATRIX: audiobook
    // This class is THE entry point for the audiobook cross-vendor smoke gate.
    // verify-pr.sh selects it via -only-testing:PalaceTests/AudiobookCrossVendorSmokeTests
    // when any Palace/Audiobooks/ or ios-audiobooktoolkit/ file is in the diff.
    // Removing or renaming this class WILL fail the gate. See:
    // .forgeos/swarms/swarm_eefef87a/contracts/B-AudiobookCrossVendorSmoke.md
    // .forgeos/swarms/swarm_eefef87a/contracts/C-Tooling.md

    func testSmoke_LCP_singleTrackLoadAndAdvance() async throws { ... }
    func testSmoke_BearerToken_singleTrackLoadAndAdvance() async throws { ... }     // Overdrive surface
    func testSmoke_OpenAccess_singleTrackLoadAndAdvance() async throws { ... }
    func testSmoke_LocalFile_singleTrackLoadAndAdvance() async throws { ... }
}
```

## Behavior contract (per scenario)

Each smoke case must, with a stubbed-out network where possible:
1. Build the vendor's `AudiobookVendorAdapter` via the production factory.
2. Load a single-track manifest fixture (use an existing fixture from `PalaceTests/Audiobook/Vendors/` — there are already `*AdapterTests.swift` for each).
3. Assert the adapter returns a non-nil player + a non-empty track list.
4. Advance one track (skip-forward or programmatic position seek; do NOT rely on actual audio decode — sim audio is broken per `feedback_audiobook_sim_audio_limitation.md`).
5. Assert the position-write surface receives ONE write (use the `CallLog` from `PalaceTests/Contract/` if helpful, OR a direct expectation on a mock delegate).

The smoke is intentionally cross-vendor on the SHARED player infrastructure, not deep on any one vendor. The bar is "did the vendor's adapter wire through to the shared player without throwing." Anything deeper is owned by the per-vendor adapter test files.

## Acceptance criteria

- File exists at `PalaceTests/Audiobooks/CrossVendorSmokeTests.swift`.
- Class name `AudiobookCrossVendorSmokeTests` (load-bearing — Module C's verify-pr edit references it by name).
- 4 test methods, one per vendor type, each passing.
- Tests complete in <10s aggregate (smoke = fast). If you can't meet 10s for all four, escalate.
- No edits to production code in `Palace/Audiobooks/`. If you discover a missing seam, the orchestrator/architect adds the seam in a follow-up — don't bundle that into this module.
- No edits in off-limits list.

## Implementer prompt

You are Module B implementer for `swarm_eefef87a`. Read `reference_audiobook_toolkit_risk_profile.md` before writing. The smoke is a regression-net for the 25+ revisions / regression-revert cycle on PalaceAudiobookToolkit — it doesn't need depth, it needs breadth across all four vendors.

**Step order:**
1. Write `transcripts/B-AudiobookCrossVendorSmoke.md` skeleton FIRST.
2. Read `PalaceTests/Audiobook/Vendors/*AdapterTests.swift` for the four existing vendors. The fixture pattern (manifest JSON, mocked URLSession) is already established — reuse it.
3. Read `Palace/Audiobooks/Vendors/Adapters+Production.swift` to understand the production factory that maps `TPPOPDSAcquisitionPath` → adapter type.
4. Write the four smoke cases. Each case <20 lines if you reuse the per-vendor mocks correctly.
5. Run `harness test --only PalaceTests/AudiobookCrossVendorSmokeTests`. All four green. Total time <10s.
6. Fill out the transcript with which mocks you reused vs. extended, what fixture each vendor loaded, and any timing budget concerns.

**No force unwraps.** No new `.shared` reads. `AppContainer` injection if you build any new helper.

**The class name `AudiobookCrossVendorSmokeTests` is contract.** Module C's verify-pr.sh patch references it by name. If you rename it, you break the swarm.

Do NOT commit. Do NOT push. Stage for the integrator.
