# Investigator D: Network-Stub Race (HTTPStubURLProtocol register/unregister)

## Mode
INVESTIGATION ONLY. No production-code or test-file edits.

## Hypothesis
`HTTPStubURLProtocol` and `URLSession.stubbedSession()` register URLProtocols on
the global `URLSessionConfiguration` registry. If a test:
1. doesn't unregister in tearDown, OR
2. mixes `URLSession.stubbedSession()` (test-local) with code paths that fall
   through to `URLSession.shared` (production-default), OR
3. queues a stub response keyed by URL that a later test's URL also matches,
the wrong stub fires for a different test. Symptom: tests pass individually,
fail in a specific suite-run ordering — and the failure is "real production
error code surfaced" (e.g. `Code=314 missing payload`) rather than "test
machinery threw."

## Evidence the category exists
- CI run 26593379677, OAuth section:
  - `SignInLogic/TPPSignInBusinessLogic+OAuth.swift: [REDIRECT] ERROR: URL missing payload`
  - `Error Domain=Sign-in redirection error: missing payload Code=314 ...
    loginURL=palace-oidc-callback://org.thepalaceproject.oidc/callback?access_token=tok&patron_info=%7B%7D, numAccounts=100`
  The loginURL is fabricated (access_token=tok) — a test fired it, but the
  redirect-handling code path saw NO matching stub. Either stub teardown happened
  too early or the redirect went to the unstubbed shared session.
- Recon: 33 PalaceTests files use `HTTPStubURLProtocol` / `stubbedSession`.
  Three core files (`HTTPStubURLProtocol.swift`, `URLSession+Stubbing.swift`,
  `NoNetworkURLProtocol.swift`) are the shared machinery; everything else is a
  consumer.

## What to look for

### Grep set 1 — register without unregister
For every test file using `HTTPStubURLProtocol`:
- Does setUp/setUpWithError install stubs via `HTTPStubURLProtocol.stub(...)`?
- Does tearDown call the inverse (`HTTPStubURLProtocol.removeAllStubs()` or
  `URLProtocol.unregisterClass(HTTPStubURLProtocol.self)`)?

### Grep set 2 — mixed-session usage
Find tests that BOTH:
- Construct `URLSession.stubbedSession()` for SOME calls, AND
- Allow code paths that fall through to `URLSession.shared` / `TPPNetworkExecutor.shared`
The mismatch is the bug: stub setup misses the unstubbed path.

### Grep set 3 — URL-keyed stub collisions
`HTTPStubURLProtocol` stubs by URL (or URL prefix). Two tests stubbing the same
URL (e.g. `https://lion.lyrasistechnology.org/`) in the same process — if either
forgets to remove its stub, the other test's request gets the wrong response.
Grep for repeated stub-URL constants across files.

### Grep set 4 — async response leak
A stub that fires a delayed response (`DispatchQueue.main.asyncAfter`) after the
test ends races the next test's request.

### Grep set 5 — NoNetworkURLProtocol
This is the inverse — it ENSURES no network call. Tests that don't install it
when they SHOULD (per their hermetic contract) are flake contestants when CI
DNS is flaky.

## Where to look (33 files; here are the highest-risk ones)
- `PalaceTests/SignInLogic/TPPSignInBusinessLogicOAuthTests.swift` — directly
  cited in CI failure (OIDC callback)
- `PalaceTests/SignInLogic/AuthErrorProblemDocSeamTests.swift`
- `PalaceTests/SignInLogic/TokenRequestTests.swift`
- `PalaceTests/Sync/CrossDeviceSyncE2ETests.swift` (E2E = biggest stub surface)
- `PalaceTests/MyBooks/DownloadResumeAfterKillTests.swift`
- `PalaceTests/MyBooks/DownloadFreeSpaceExhaustionTests.swift`
- `PalaceTests/MyBooks/DownloadIntegrityTests.swift`
- `PalaceTests/Integration/SignInToReadFlowIntegrationTests.swift`
- `PalaceTests/Integration/AccountSwitchLifecycleTests.swift`
- `PalaceTests/Integration/BorrowAndDownloadIntegrationTests.swift`
- `PalaceTests/OPDS2/UnifiedOPDSServiceStateMachineTests.swift`
- `PalaceTests/DRM/LCPCharacterizationTests.swift`
- `PalaceTests/Security/AuthFlowSecurityTests.swift`
- `PalaceTests/Security/DRMAdversarialTests.swift`

## Evidence to collect
```
file:line | stub_setup_location | stub_teardown_present? | session_used (stubbed/shared/mixed) | severity
```
- HIGH = setup with no teardown + mixed-session
- MED = teardown present but happens AFTER super.tearDown OR after a Task fire-and-forget
- LOW = clean register/unregister, no collision risk

## Proposed fix SHAPE
1. `HTTPStubTestCase` base class with deterministic register/unregister around every
   test. Subclasses opt into `stub(url:response:)` and stubs are torn down
   automatically.
2. Lint: `scripts/check-http-stub-teardown.py` that fails any file using
   `HTTPStubURLProtocol.stub` without a matching `removeAllStubs` or
   `: HTTPStubTestCase` ancestry.
3. Lint: ban `URLSession.shared` and `TPPNetworkExecutor.shared` in
   `PalaceTests/**` outside an explicit allowlist (per CLAUDE.md "Use mocks/stubs
   for dependencies. Never hit real singletons").
4. CI gate: run the test suite once with `NoNetworkURLProtocol` registered
   globally; any test that needs real network without explicitly opting in fails.

## NOT in scope
- No edits to `HTTPStubURLProtocol.swift`, `URLSession+Stubbing.swift`,
  `NoNetworkURLProtocol.swift`, or `TPPNetworkExecutor.swift`.
- No test edits — only enumeration of stub-discipline gaps.

## Output contract
Same shape as Investigator A. Emphasis on the FILE LIST + severity bucketing.
```

---
