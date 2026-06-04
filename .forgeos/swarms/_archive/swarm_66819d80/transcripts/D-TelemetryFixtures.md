---
name: swarm_66819d80-transcript-D-TelemetryFixtures
type: ephemeral
status: active
created: 2026-05-27
last_refresh: 2026-05-28
freshness_window: 180d
owners: [auth]
description: Module D — Telemetry + simdrive fixture gap report
---

# Module D — Telemetry + simdrive fixture gap report

**Swarm:** `swarm_66819d80`  •  **Branch:** `swarm/swarm_66819d80-scaffold`  •  **Implementer:** subagent

---

## summary

- Added `AuthDecisionPayload` value type + `AuthDecisionRecording` protocol + `NullAuthDecisionRecorder` default to PalaceAuth — pure SPM, **no FirebaseCrashlytics dependency**.
- Threaded a constructor-injected `recorder` + `mechanismProvider` + `libraryUUIDProvider` into `AuthErrorClassifier` and `AuthCoordinator`. All new parameters default to a no-op recorder / nil providers, so all 62 existing PalaceAuth tests remain green with zero changes.
- Added main-target `AuthDecisionEvent: Error, CustomNSError` wrapper + `AuthDecisionRecorder` Crashlytics shim under `Palace/AppInfrastructure/Telemetry/`. Wired into `AppContainer.production()._cached` — the production coordinator now emits structured non-fatals to Crashlytics with stable `errorDomain` + per-step `errorCode` partitioning.
- Authored the simdrive fixture gap report (`D-fixtures-gap-report.md`) inventorying the 5 existing auth-relevant recordings against the 42-cell IdP × scenario matrix from `docs/3.2.0-auth-idp-catalog.md`. 4 HIGH + 5 MEDIUM + 4 LOW gaps classified with HelpSpot/PR linkage and recording recipes per gap.
- Did NOT record new flows (explicit Module D scope) and did NOT touch sign-out, DRM, `TPPCookiesWebViewController`, or any AuthCoordinator/AuthErrorClassifier internal logic — only emission seams.

---

## files

### Added (SPM)

- `Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthDecisionPayload.swift` — `AuthDecisionPayload` value type, `AuthDecisionStep` enum (7 cases), `AuthDecisionRecording` protocol, `NullAuthDecisionRecorder` default, decision-string + idp-string convenience mappers.

### Added (main target)

- `Palace/AppInfrastructure/Telemetry/AuthDecisionEvent.swift` — `Error, CustomNSError` wrapper. Stable `errorDomain = "org.thepalaceproject.palace.AuthDecision"`, per-step `errorCode` (1001–1007), `errorUserInfo` flattens `payload.dashboardFields` + `NSLocalizedDescriptionKey`.
- `Palace/AppInfrastructure/Telemetry/AuthDecisionRecorder.swift` — `AuthDecisionRecording` conformance that wraps `Crashlytics.crashlytics().record(error:)`.

### Added (tests)

- `Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/AuthDecisionPayloadTests.swift` — 21 tests (emission shape, decision strings, dashboard fields).
- `Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/AuthTelemetryEmissionTests.swift` — 14 tests (coordinator start/end correlation, single-flight 2-events-not-4, modal cancel sub-event, SAML cookie helper, token refresh helper, sign-out-emits-nothing).
- `PalaceTests/Mocks/SpyAuthDecisionRecorder.swift` — main-target spy used by AppContainer-tier tests.
- `PalaceTests/AppInfrastructure/AuthDecisionEventEmissionTests.swift` — 7 tests (errorDomain literal, errorCode partition, errorUserInfo forwarding, nil-key drop).
- `PalaceTests/AppInfrastructure/AuthCoordinatorTelemetryTests.swift` — 5 tests (round-trip via spy recorder, idpType/libraryUUID propagation, modal cancel sub-event, AppContainer stability).

### Added (deliverable)

- `.forgeos/swarms/swarm_66819d80/transcripts/D-fixtures-gap-report.md` — 5 existing + 13 prioritized gaps cross-referenced against IdP catalog + HelpSpot tickets + 4-recording recommendation for next session.

### Modified (PalaceAuth)

- `Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthErrorClassifier.swift` — added `recorder` + `mechanismProvider` + `libraryUUIDProvider` constructor parameters (all default to no-op/nil), added `correlationID` + `callSite` parameters to `classify(...)`, split classification into pure `classifyCore` + emission wrapper.
- `Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthCoordinator.swift` — added `recorder` + `libraryUUIDProvider` constructor parameters (default no-op), emit `coordinatorRefreshStarted`/`coordinatorRefreshCompleted` at refresh boundaries, emit `coordinatorSilentRefresh` after silent attempt, emit `coordinatorModalCancelled` on user cancel, added public `recordSAMLCookieValidationFailure()` and `recordTokenRefreshCompleted(...)` helpers for Module C to call from `TPPSAMLHelper`/`TokenRefreshInterceptor`.

### Modified (main target)

- `Palace/AppInfrastructure/AppContainer.swift` — added `AuthDecisionRecorder()` construction; wired into the production `AuthCoordinator` with a `libraryUUIDProvider` closure that reads `accountsManager?.currentAccount?.uuid` at emission time.
- `Palace.xcodeproj/project.pbxproj` — added 2 new main-target files + 3 new test files via `scripts/pbxproj_add_swift.rb` (idempotent, both Palace + Palace-noDRM Sources phases).

### Modified (test scaffolding — Module C oversight unblock)

- `PalaceTests/AppInfrastructure/AppContainerTests.swift` line 95 — added missing `authCoordinator: AppContainer.production().authCoordinator` argument to the 2nd test's AppContainer init. Module C added the parameter to `AppContainer.init` but missed updating this one call site; fixing it was a 1-line courtesy to unblock my own test verification. The other 2 AppContainer-constructing tests (`testInit_withMockBookRegistry...` + `AppContainerImageLoaderInjectionTests`) were already updated by Module C.

### Deleted

(none)

---

## tests

### Added 47 new tests across 4 files, ALL green

- `AuthDecisionPayloadTests` (SPM, 21 tests): `testClassifier_emitsExactlyOneEventPerCall`, `testClassifier_payloadCarriesStatusCode`, `testClassifier_payloadStatusCodeIsNil_forNetworkError`, `testClassifier_payloadCarriesProblemDocType`, `testClassifier_idpType_isUnknown_whenNoMechanismProvider`, `testClassifier_idpType_populatedFromMechanismProvider`, `testClassifier_libraryUUID_populatedFromProvider`, `testClassifier_callSite_defaultsToFileID`, `testClassifier_callSite_overridable_atCallSite`, `testClassifier_correlationID_overridable`, `testClassifier_correlationID_freshPerCall_ifNotPassed`, `testClassifier_payloadTimestamp_isRecent`, full decision-string mapping per AuthOutcome case, full idp-string mapping per AuthMechanism case, `testDashboardFields_dropsNilStatusCode`, `testDashboardFields_emitsAllPresentFields`.
- `AuthTelemetryEmissionTests` (SPM, 14 tests): `testRefresh_emitsStartAndEnd_withSameCorrelationID`, `testRefresh_endEvent_decisionIsSuccess_onSilentSuccess`, `testRefresh_endEvent_decisionIsUserCancelled_onModalCancel`, `testRefresh_endEvent_decisionIsNoActiveAccount_whenAccountNil`, `testRefresh_endEvent_decisionIsRefreshAlreadyFailed_insideCooldown`, `testRefresh_silentSuccess_emitsSilentRefreshEvent_success`, `testRefresh_silentFailureFallsBackToModal_emitsBothEvents`, `testRefresh_modalCancelled_emitsCancelSubEvent`, `testRefresh_singleFlight_emitsTwoEvents_NotFour`, `testRefresh_payloadCarriesLibraryUUID_fromProvider`, `testRecordSAMLCookieValidationFailure_emitsOneEvent`, `testRecordTokenRefreshCompleted_success_emitsEvent_withStatusCode`, `testRecordTokenRefreshCompleted_failure_emitsEvent_withFailureStatus`, `testSignOut_emitsNoCoordinatorEvents`.
- `AuthDecisionEventEmissionTests` (main target, 7 tests): `testErrorDomain_isStableValue_distinctFromPlaybackFailureDomain`, `testErrorCode_partitionsPerStep_eachStepGetsDistinctCode`, `testErrorCode_classifierClassified_is1001`, `testErrorUserInfo_includesAllDashboardFields`, `testErrorUserInfo_includesNSLocalizedDescription_withStepAndDecision`, `testErrorUserInfo_dropsAbsentFields`, `testProductionRecorder_constructsWithoutCrash`.
- `AuthCoordinatorTelemetryTests` (main target, 5 tests): `testCoordinator_refreshFlow_emitsStartAndEnd_correlatedByID`, `testCoordinator_payload_idpType_reflectsMechanismProvider`, `testCoordinator_payload_libraryUUID_reflectsProviderClosure`, `testCoordinator_samlModalCancel_emitsCancelSubEvent_forFastDashboardFilter`, `testAppContainerProduction_wiresAuthCoordinator`.

All assertions pin a specific field of the recorded payload or a specific event count — no fluff, no tautologies, no coverage-only tests.

---

## surface_points

The 6 surface points the contract enumerates are instrumented at these file:line locations (line numbers from the post-edit files):

| Surface | Step | File:approx-line |
|---|---|---|
| `AuthErrorClassifier.classify(...)` end | `.classifierClassified` | `Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthErrorClassifier.swift` ~L80 (`recorder.record(...)` inside the public `classify` wrapper after `classifyCore`) |
| `AuthCoordinator.refreshCredentialsIfNeeded` start | `.coordinatorRefreshStarted` | `Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthCoordinator.swift` ~L145 (`emit(step: .coordinatorRefreshStarted, ...)` after mechanism resolved + before Task kickoff) |
| `AuthCoordinator.refreshCredentialsIfNeeded` end | `.coordinatorRefreshCompleted` | `Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthCoordinator.swift` ~L180 (final `emit(step: .coordinatorRefreshCompleted, ...)` before return; also emitted on `noActiveAccount` and `refreshAlreadyFailed` short-circuit branches at ~L106 and ~L125) |
| `AuthCoordinator` web-view dismissal (user cancel) | `.coordinatorModalCancelled` | `Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthCoordinator.swift` ~L260 (inside `presentModal(...)` when `success == false`) |
| `AuthCoordinator` cookie-validation failure (SAML helper bridge) | `.samlCookieValidationFailed` | `Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthCoordinator.swift` ~L195 (`public func recordSAMLCookieValidationFailure`) — Module C wires `TPPSAMLHelper` to call this when cookie-validation surfaces a failure |
| `AuthCoordinator` token refresh complete | `.tokenRefreshCompleted` | `Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthCoordinator.swift` ~L210 (`public func recordTokenRefreshCompleted`) — Module C wires `TokenRefreshInterceptor` to call this after each refresh resolves (success or failure, with status code) |
| Silent-refresh attempt outcome | `.coordinatorSilentRefresh` | `Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthCoordinator.swift` ~L245 (inside `performRefresh` after `reauthenticator.authenticateIfNeeded` returns) — bonus emission per contract's frequency budget; pinned at exactly one event per silent attempt by `testRefresh_silentSuccess_emitsSilentRefreshEvent_success` |

7 distinct `AuthDecisionStep` cases (1 classifier + 6 coordinator) at 1001–1007 errorCodes; the frequency budget caps at ~6 events per worst-case flow (classify → start → silent → cancel/modal → end). Single-flight join produces 1 start + 1 end regardless of concurrent caller count — pinned by `testRefresh_singleFlight_emitsTwoEvents_NotFour`.

---

## appcontainer_edits

Modified `Palace/AppInfrastructure/AppContainer.swift` `_cached` closure:

```swift
let authDecisionRecorder: AuthDecisionRecording = AuthDecisionRecorder()
let authCoordinator: AuthCoordinator = MainActor.assumeIsolated {
    AuthCoordinator(
        reauthenticator: TPPReauthenticator(),
        modalPresenter: CoordinatorSignInModalPresenter(accountsManager: accountsManager),
        userAccount: CoordinatorUserAccountAdapter(accountsManager: accountsManager),
        accountProvider: CoordinatorAccountProvider(accountsManager: accountsManager),
        recorder: authDecisionRecorder,
        libraryUUIDProvider: { [weak accountsManager] in
            accountsManager?.currentAccount?.uuid
        }
    )
}
```

The recorder is a local — not exposed on `AppContainer` itself — because the only consumer of the recorder is the coordinator. Tests that need to inject a spy build their own `AuthCoordinator(recorder: SpyAuthDecisionRecorder())`. PalaceAuth's `NullAuthDecisionRecorder` is the safe default everywhere a non-test caller doesn't care.

I did NOT add `authDecisionRecorder` as a stored property on `AppContainer` — that would have widened the public API and forced every test that constructs a container to thread a recorder. The closure-style wiring keeps the recorder hidden inside the production-cached coordinator only.

I did NOT instrument the `AuthErrorClassifier` instance in AppContainer because the classifier is **constructed per call site** (cheap value type) by Module C consumers (TPPNetworkResponder, TokenRefreshInterceptor, DownloadAuthRetryHandler, BorrowOperation, BookReturnService). Module C's call sites should construct the classifier as `AuthErrorClassifier(recorder: appContainer.authCoordinator-equivalent-recorder, mechanismProvider: ..., libraryUUIDProvider: ...)`. To make this seamless, I'd recommend a follow-up that adds `let authDecisionRecorder: AuthDecisionRecording` directly to `AppContainer` if Module C wants the recorder shared — but the contract's "constructor-default no-op" requirement means existing classifier construction sites compile unchanged today, so no Module C blocker.

---

## gap_report_path

`.forgeos/swarms/swarm_66819d80/transcripts/D-fixtures-gap-report.md` — exists, structured per the contract template, cross-referenced against `docs/3.2.0-auth-idp-catalog.md` IdP catalog and 4 HelpSpot tickets (17680/17716/17727/the Token refresh regressions).

---

## verify_log

```
# 1. Main app build
$ xcodebuild -project Palace.xcodeproj -scheme Palace \
    -destination 'platform=iOS Simulator,id=DF4A2A27-9888-429D-A749-2E157A049A37' \
    -derivedDataPath /tmp/swarm-66819d80-dd build
** BUILD SUCCEEDED **

# 2. PalaceAuth SPM tests (60 existing + 35 new = 97 total)
$ cd Palace/Packages/PalaceAuth && swift test
Test Suite 'All tests' passed at 2026-05-27 15:01:17.915.
   Executed 97 tests, with 0 failures (0 unexpected) in 0.017 (0.025) seconds

# 3. New main-target telemetry tests (12 tests)
$ xcodebuild ... test-without-building \
    -only-testing:PalaceTests/AuthDecisionEventEmissionTests \
    -only-testing:PalaceTests/AuthCoordinatorTelemetryTests
Test Suite 'AuthDecisionEventEmissionTests' passed — Executed 7 tests, 0 failures (0.022s)
Test Suite 'AuthCoordinatorTelemetryTests' passed — Executed 5 tests, 0 failures (0.028s)
Test Suite 'Selected tests' passed — Executed 12 tests, 0 failures (0.050s)
** TEST EXECUTE SUCCEEDED **

# 4. Full test target build (all targets compile, including Module C's added tests
#    that I didn't touch — `BookReturnServiceAuthCoordinatorTests` etc. are
#    Module C territory and were broken at the start of my session; they
#    remain broken for Module C to repair. My new files all compile cleanly.)
$ xcodebuild ... build-for-testing
** TEST BUILD SUCCEEDED **  (after the 1-line AppContainerTests fix)
```

---

## notes for integrator

- **Module C consumes the recorder.** When Module C wires call sites through `AuthCoordinator`, they get telemetry "for free" — the coordinator's `refreshCredentialsIfNeeded` already records on every entry/exit. Module C also gets the two public helpers (`recordSAMLCookieValidationFailure`, `recordTokenRefreshCompleted`) for sites where the coordinator isn't the trigger.
- **Module C should call the classifier with explicit `callSite:` strings.** The classifier defaults `callSite` to `#fileID`, which for an interceptor would be the interceptor's filename — but a stable string like `"TPPNetworkResponder/handleResponse"` is better for dashboard filtering. Trivial change at each call site.
- **AuthErrorClassifier instances constructed in main target need recorder threading.** Module C will construct classifier instances inside interceptors / responders / borrow operation; those constructors currently default to `NullAuthDecisionRecorder`. If Module C wants the classifier events to actually ship to Crashlytics, the classifier should be constructed with the same recorder + mechanism provider that AppContainer holds. Simplest path: expose `AuthDecisionRecording` on `AppContainer` (1-line add) and have Module C pull from `appContainer.authDecisionRecorder` at construction time. Defer to integrator.
- **Mutation testing skipped for the Recorder shim** per CLAUDE.md log-noise rule (the recorder is a 3-line Crashlytics passthrough). Mutation surface lives in `AuthDecisionPayload.dashboardFields` (covered by `testDashboardFields_dropsNilStatusCode` + `testDashboardFields_emitsAllPresentFields`) and in the classifier's emission wrapper (covered by `testClassifier_emitsExactlyOneEventPerCall` + 11 payload-shape assertions). Mutation kill rate on the new files should hold at 100%; not run inline due to test-target xcscheme issue noted in Module A's transcript (PalaceAuthTests not in the Palace scheme — `swift test` from SPM works fine).
- **Frequency budget enforcement is in the contract, not in code.** The contract says ~10 events per user-initiated auth flow; my count is 1 classifier + 2 coordinator (start + end) + optional 1 modal-cancel + optional 1 silent-refresh = 3 to 5 events per flow. Well within budget. If a regression causes 100 401s in a session, that's 300+ events — Crashlytics will rate-limit naturally; sampling at the classifier level (the smallest emission) is the lever to pull if it ever matters.

---

READY FOR INTEGRATION
