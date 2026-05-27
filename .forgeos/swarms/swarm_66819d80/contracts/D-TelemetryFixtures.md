# Module D — Telemetry instrumentation + simdrive fixture gap report

**Swarm:** `swarm_66819d80`  •  **Base SHA:** `d7f115adeb69032fb3abed33ba07b3deeb245f4b`  •  **Depends on:** Module A (must merge first); runs parallel to Module C

---

## Goal

Instrument every auth decision point with a structured Crashlytics
non-fatal so the next regression surfaces with full context
(`idp_type`, `library_uuid`, `status_code`, `problem_doc_type`,
`decision`) instead of as a vague crash signature. Mirrors PR #933's
playback-failure non-fatal pattern.

Plus: audit `~/.simdrive/recordings/` for IdP fixture coverage. Where
recordings are missing for IdP × scenario cells in
`docs/3.2.0-auth-idp-catalog.md`, write a gap report so a follow-up
session can capture them.

This module does **not** record new flows — recording requires
backend access and credential typing, which is a separate operator
session. Module D's job is the seam + the report.

---

## In-scope files

### Add (new)

```
Palace/AppInfrastructure/Telemetry/AuthDecisionEvent.swift
  Structured non-fatal type. Lives in main target (Crashlytics is a
  main-target dep, not a PalaceAuth dep).

Palace/AppInfrastructure/Telemetry/AuthDecisionRecorder.swift
  Wraps Crashlytics.crashlytics().record(error: ...) call. Allows
  spy substitution in tests.

PalaceTests/AppInfrastructure/AuthDecisionEventEmissionTests.swift
PalaceTests/AppInfrastructure/AuthCoordinatorTelemetryTests.swift

.forgeos/swarms/swarm_66819d80/transcripts/D-fixtures-gap-report.md
  Recording-gap report (the deliverable per task brief).
```

### Modify

```
Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthCoordinator.swift
  Inject AuthDecisionRecording protocol; emit start + end events per refresh.

Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthErrorClassifier.swift
  Inject AuthDecisionRecording protocol; emit one event per classify call.

(Both protocol-injected so PalaceAuth doesn't link Crashlytics.
Production conformance is at the main target.)

Palace/AppInfrastructure/AppContainer.swift
  Wire AuthDecisionRecorder into PalaceAuth coordinator + classifier.
```

### OFF-LIMITS

- Anything NOT in the telemetry surface. Module D does NOT migrate
  callers (that's Module C). It does NOT touch SignInLogic internals.
- Do NOT record new simdrive flows — that's a separate operator
  session. Module D writes the gap report.
- Do NOT change the public `AuthOutcome` / `AuthCoordinator` API. The
  telemetry hook is a constructor-injected dependency, not a new public
  method.

---

## API contract

### `AuthDecisionEvent.swift` (main target)

```swift
import Foundation

/// Structured Crashlytics non-fatal payload for every auth decision.
/// Mirrors the PR #933 playback-failure pattern: 1 event per decision,
/// with full IdP context, so dashboard filtering surfaces patterns
/// (e.g. "all Cornell Shibboleth users hit .samlSessionExpired in the
/// 15:00–16:00 window after CM deploy").
public struct AuthDecisionEvent: Error {
    public let outcome: AuthOutcome           // imported from PalaceAuth
    public let idpType: String                // "basic" / "oauth" / "oidc" / "saml" / "token" / "unknown"
    public let libraryUUID: String?           // current account's UUID
    public let statusCode: Int?               // nil for network errors
    public let problemDocType: String?        // nil if no problem doc
    public let callSite: String               // #fileID + #function
    public let correlationID: UUID            // ties classify ↔ coordinator events

    /// CustomNSError conformance maps to Crashlytics userInfo so we can
    /// filter the dashboard by any field.
    public var errorUserInfo: [String: Any] { ... }
}
```

### `AuthDecisionRecorder.swift` (main target)

```swift
import FirebaseCrashlytics
import PalaceAuth

/// Production conformance for PalaceAuth's AuthDecisionRecording protocol.
/// Wraps Crashlytics recording so tests can inject a spy.
public final class AuthDecisionRecorder: AuthDecisionRecording {
    public init() {}

    public func record(_ event: AuthDecisionEvent) {
        Crashlytics.crashlytics().record(error: event)
    }
}
```

### `AuthDecisionRecording` (PalaceAuth, public protocol)

```swift
public protocol AuthDecisionRecording: Sendable {
    func record(_ event: AuthDecisionEvent)
}
```

(Where `AuthDecisionEvent` is imported into PalaceAuth via a
public-but-thin event-shape struct — or PalaceAuth declares a
`AuthDecisionEventPayload` protocol that the main-target struct
conforms to. Implementer picks the simpler path; the constraint is
**PalaceAuth does NOT import FirebaseCrashlytics**.)

Recommended: PalaceAuth declares a value-typed `AuthDecisionPayload`
struct (no Crashlytics dependency); main target's `AuthDecisionEvent`
wraps it + conforms to Error. The recorder takes the payload, builds
the Event, and ships to Crashlytics.

---

## Telemetry emission contract

Emit events at these surface points (precise list — implementer MUST
NOT add more without architect sign-off):

| Surface | Event | Notes |
|---|---|---|
| `AuthErrorClassifier.classify` | 1 event per call | correlation_id = new UUID for this classify call |
| `AuthCoordinator.refreshCredentialsIfNeeded` start | 1 event | correlation_id = classify's UUID if available (propagated via context), else new |
| `AuthCoordinator.refreshCredentialsIfNeeded` end | 1 event | same correlation_id; outcome populated |
| `AuthCoordinator` web-view dismissal (user cancel) | 1 event | outcome = `.failure(.userCancelled)` |
| `AuthCoordinator` cookie-validation failure (when surfaced by SAML helper) | 1 event | special outcome = `.reauthRequired(.samlSessionExpired)` |
| `AuthCoordinator` token refresh complete (success or failure) | 1 event | wraps the silent-refresh result |

**Frequency budget:** at most ~10 events per user-initiated auth flow.
Not per-network-call. The classifier event is the smallest unit; the
coordinator's start+end pair is the largest. If a flow emits more than
~10, sample at the classifier level (debug-only).

---

## Test contract

### `AuthDecisionEventEmissionTests.swift`

```swift
final class AuthDecisionEventEmissionTests: XCTestCase {

    func test_classifierEmits_oneEventPerCall_withCorrectPayload() {
        let spy = SpyAuthDecisionRecorder()
        let classifier = AuthErrorClassifier(recorder: spy)
        _ = classifier.classify(response: stub401Response, problemDocument: nil, body: nil, originalRequestURL: nil)
        XCTAssertEqual(spy.recorded.count, 1)
        XCTAssertEqual(spy.recorded.first?.outcome, .reauthRequired(reason: .unknown401))
        XCTAssertEqual(spy.recorded.first?.statusCode, 401)
    }

    func test_classifier_libraryUUIDPopulated_fromAccountProvider() { ... }
    func test_classifier_problemDocTypeSurfaced() { ... }
    func test_classifier_callSitePopulated() { ... }
    func test_classifier_correlationIDIsStableAcrossCallsToSameEvent() { ... }
}
```

### `AuthCoordinatorTelemetryTests.swift`

```swift
final class AuthCoordinatorTelemetryTests: XCTestCase {

    func test_coordinator_emits_startAndEnd_withSameCorrelationID() {
        let spy = SpyAuthDecisionRecorder()
        let coordinator = makeCoordinator(recorder: spy)
        _ = await coordinator.refreshCredentialsIfNeeded(reason: .expiredToken)
        XCTAssertEqual(spy.recorded.count, 2)
        XCTAssertEqual(spy.recorded[0].correlationID, spy.recorded[1].correlationID)
    }

    func test_coordinator_userCancelled_emitsUserCancelledOutcome() { ... }
    func test_coordinator_singleFlight_emits_TwoEvents_NotFour() {
        // Two concurrent refresh calls → only one start+end pair, not 2 pairs.
    }
}
```

### Spy

`PalaceTests/Mocks/SpyAuthDecisionRecorder.swift` — records events to
an array; tests assert on it.

### Mutation gate

`AuthDecisionEvent.swift` is a value type — mutation will probably
find few real mutants beyond `errorUserInfo` dict construction.
`AuthDecisionRecorder.swift` is a 3-line wrapper — mutation skipped per
CLAUDE.md log-noise rule (Crashlytics call). The TELEMETRY assertions
in `AuthDecisionEventEmissionTests` carry the load: each assertion
must pin a specific field of the recorded event.

---

## Recording gap audit (the second deliverable)

### Method

```bash
ls ~/.simdrive/recordings/ | grep -iE "saml|oauth|oidc|signin|sign-in|basic|signout|sign-out|reauth"
```

As of 2026-05-27, the inventory is:

```
a1qa-basic-signin
a1qa-sign-out
danny-saml-signin-init
icarus-oidc-signin
pr907-saml-signin-gorgon
```

### Gap analysis against IdP catalog

Compare against `docs/3.2.0-auth-idp-catalog.md` § "IdP types we ship
today" — 7 IdPs × 6 scenarios = 42 cells. Each cell either has a
recording, has a UNIT test (which doesn't replace a recording), or is
a gap.

Module D writes a structured report at
`.forgeos/swarms/swarm_66819d80/transcripts/D-fixtures-gap-report.md`
listing:

```markdown
# Auth fixture gap report (Module D, swarm_66819d80)

Generated against ~/.simdrive/recordings/ on 2026-05-27.

## Have recordings

| IdP × scenario | recording name | last-validated |
|---|---|---|
| Basic × Sign-in success | a1qa-basic-signin | per simdrive metadata |
| SAML × Sign-in (gorgon library) | pr907-saml-signin-gorgon | per metadata |
| SAML × Sign-in (Danny / library X) | danny-saml-signin-init | per metadata |
| OIDC × Sign-in (Icarus library) | icarus-oidc-signin | per metadata |
| Generic × Sign-out | a1qa-sign-out | per metadata |

## Gaps (recording absent)

| IdP × scenario | priority | rationale |
|---|---|---|
| OAuth-intermediary × Sign-in (Clever) | HIGH | most cross-library shibboleth has no Clever cousin; sign-in path differs |
| Token × Silent refresh (near-expiry) | HIGH | TokenRefreshOnForegroundTests covers unit-level but no behavioral fixture |
| SAML × Cookie expiry mid-borrow | HIGH | HelpSpot 17727 (Sonoma) was the reason 3.0.2 hotfix shipped — no replay exists |
| SAML × Sign-in (Cornell Shibboleth) | MEDIUM | HelpSpot 17680; we have generic SAML but not Cornell specifically |
| SAML × Sign-in (RAILS) | MEDIUM | HelpSpot 17716 — different cookie behavior |
| SAML × Sign-in (NJStateLib) | MEDIUM | partner library; cookie rotation differs |
| Any × Forbidden (license expired) | MEDIUM | not covered |
| Any × Server 5xx during sign-in | LOW | unit test path |
| Any × Network failure during sign-in | LOW | unit test path |
| OIDC × Sign-out | MEDIUM | sign-out exists for SAML; not for OIDC specifically |

## Recommended next session

Record these 4 first:
1. Token × Silent refresh — fastest to set up; uses Frida library
2. SAML × Cookie expiry mid-borrow — highest user impact
3. OAuth-intermediary × Sign-in — Clever, partner has test creds
4. SAML × Sign-in (Cornell Shibboleth) — paired with HelpSpot 17680 retest

Each is ~30 min of `scripts/record-auth-flow.sh` (from PR #940)
plus credential typing.
```

The gap report is the actual deliverable here — it's the bridge to
Phase 7 of the parent plan (`palace-3.2.0-auth-architecture.md`).

---

## TDD assertion outline

```
Day 2 (parallel to Module C):

  1. Read docs/3.2.0-auth-idp-catalog.md to understand the event payload shape.
  2. Write AuthDecisionPayload struct in PalaceAuth (pure value type).
  3. Write AuthDecisionRecording protocol in PalaceAuth.
  4. Write SpyAuthDecisionRecorder in PalaceTests/Mocks/.
  5. Write AuthDecisionEventEmissionTests test 1 (classifier emits 1 event). Fails.
  6. Inject recorder into AuthErrorClassifier; record on classify. Test passes.
  7. Iterate through remaining 4 emission tests.
  8. Write AuthCoordinatorTelemetryTests — start+end correlation; user-cancelled; single-flight 2-events-not-4.
  9. Inject recorder into AuthCoordinator; record on start, end, special events. Tests pass.
  10. Write main-target AuthDecisionEvent + AuthDecisionRecorder. Wire into AppContainer.
  11. Build the main app once to confirm wiring compiles.
  12. Inventory ~/.simdrive/recordings/. Write the gap report.
  13. Confirm gap report cross-references the IdP catalog correctly.
```

---

## What NOT to do

1. **Do NOT link FirebaseCrashlytics into PalaceAuth.** The recorder
   protocol pattern keeps PalaceAuth dependency-clean.
2. **Do NOT emit events per network call.** The classifier event is the
   smallest unit; coordinator start+end is the largest.
3. **Do NOT record new simdrive flows.** That's a separate operator
   session (requires backend + credentials). Module D writes the gap
   report; recording is followup work.
4. **Do NOT add a UI for telemetry.** This is non-fatal telemetry;
   surfaces in Crashlytics dashboard only.
5. **Do NOT modify Module A's public surface.** The recorder is
   constructor-injected — `AuthErrorClassifier()` continues to compile
   without a recorder (default to a no-op recorder), so callers that
   don't care don't have to wire one.
6. **Do NOT compete with PR #933's playback-failure telemetry.** This
   is auth-decision telemetry, a separate non-fatal class. They can
   coexist; do not unify in this swarm.

---

## Pbxproj wiring

```
ruby scripts/pbxproj_add_swift.rb \
  Palace/AppInfrastructure/Telemetry/AuthDecisionEvent.swift \
  Palace/AppInfrastructure/Telemetry/AuthDecisionRecorder.swift

ruby scripts/pbxproj_add_swift.rb \
  PalaceTests/AppInfrastructure/AuthDecisionEventEmissionTests.swift \
  PalaceTests/AppInfrastructure/AuthCoordinatorTelemetryTests.swift \
  PalaceTests/Mocks/SpyAuthDecisionRecorder.swift
```

PalaceAuth files (AuthDecisionPayload.swift, AuthDecisionRecording.swift)
are SPM — no pbxproj.

---

## Acceptance

- All 9 new tests green (5 emission + 4 telemetry).
- `AuthErrorClassifier` and `AuthCoordinator` from Module A still pass
  their own tests with the new recorder dependency injected (the
  constructor-default no-op preserves backward compat).
- `AppContainer.production().authCoordinator` is wired with a real
  `AuthDecisionRecorder` instance.
- Build the main app once after merge — verify Crashlytics non-fatal
  registers (use `Crashlytics.crashlytics().record(error: ...)` smoke
  test).
- `.forgeos/swarms/swarm_66819d80/transcripts/D-fixtures-gap-report.md`
  exists with the structure shown above.
- `swiftlint` clean on new files.
- Mutation: skipped for the recorder wrapper (log-noise rule); event
  payload assertions pin field-level behavior.

---

## Evidence to attach (for forge-review)

- `unit_test`: 9 new tests count + green.
- `lint`: swiftlint on new files.
- `architect_review`: reviewer attests PalaceAuth still doesn't import Crashlytics, recorder is properly DI'd.
- `qa_test`: reviewer attests the fixture-gap report is complete + prioritization rationale.
- (Optional) `simdrive`: run the 5 existing recordings to verify replay still passes — telemetry should NOT affect replay determinism.
