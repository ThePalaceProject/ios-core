---
name: adobe-activation-single-flight
created: 2026-08-12
author: claude-opus-5
---

**ADR refs:** none — no prior decision covers on-demand Adobe activation. Checked
the local `docs/architecture/` ledger (`account-state-machine.md`,
`areas/auth/verification-checklist.md`, `ipad-on-mac-exit-static-destructor-bypass.md`);
the ForgeOS ADR API was not queried because governance is OFF in this environment
per `CLAUDE.local.md`.

## Context

Crashlytics issue `ed05e903c2777582d68747b624e4f548`, fresh in 3.2.3 (492), is a
malloc abort inside Adobe RMSDK's bundled expat parser:

```
_xzm_xzone_malloc_from_freelist_chunk.cold.1
lookup / storeAtts / XML_ParseBuffer
adept::createActivationDOM → adept::DRMProcessorImpl::getActivations()
-[NYPLADEPT authorizeWithVendorID:username:password:completion:]
```

The event log shows `DownloadStartCoordinator` starting the same borrow twice
(2.3s apart) and `AdobeCertificate.swift:450` logging `Performing on-demand Adobe
device activation for borrow` twice. `ensureDeviceActivated()` has no in-flight
de-duplication — its only guard is the `isUserAuthorized` fast path, which cannot
be true until a prior activation has already *completed*. Two concurrent callers
both enter the non-thread-safe RMSDK and corrupt its shared C++ heap.

## Claims

- adds `AdobeActivationCoordinator` actor in `Palace/Reader2/ReaderStackConfiguration/AdobeDRM/AdobeActivationCoordinator.swift`, providing single-flight coalescing so concurrent callers share one in-flight activation
- adds a deadline on the RMSDK continuation itself in `AdobeDRMService.ensureDeviceActivated`, via a one-shot latch (`OneShotContinuation`) resumed by whichever of RMSDK's completion or the timeout arrives first, so a wedged `authorize` cannot permanently block every later borrow

  AMENDED after review round 1: this was originally claimed as a watchdog inside
  `AdobeActivationCoordinator`, implemented by wrapping the work in
  `BorrowOperation.withTimeout`. That is inert — a task group awaits its children
  on scope exit and cannot unwind a non-resuming continuation, so the slot would
  have wedged forever. The coordinator now does single-flight only; bounding is
  the caller's job, because only the caller can interrupt its own operation.
- migrates `AdobeDRMService.ensureDeviceActivated()` to route its `NYPLADEPT.authorize` call through the coordinator
- adds a `PP-4952` non-fatal on the activation-timeout branch, so the failure mode this design accepts is visible in Crashlytics, reported only when the deadline actually claims the continuation
- adds injectable `authorizer:` (a closure, so RMSDK is not initialised ahead of the guards), `userAccount:`, `isDRMAvailable:` and `timeout:` parameters to `AdobeDRMService.ensureDeviceActivated()`, so the de-dup is testable against `TPPDRMAuthorizingMock` rather than only at the helper level

## Anti-claims

- does NOT change the `TPPDRMAuthorizing` protocol surface
- does NOT serialize the other RMSDK entry points (`fulfill`, `returnLoan`, `cancelFulfillment`) — they share the same non-thread-safe C++ state and are a real but separate exposure, deferred
- does NOT modify `DownloadStartCoordinator` or fix the underlying duplicate borrow-start; this change makes the DRM layer safe against duplicate callers rather than eliminating them
- does NOT change `AdobeCertificate.isDRMAvailable` gating or the licensor/client-token parsing
- does NOT alter the iPad-on-Mac static-destructor bypass (`registerStaticDestructorBypassIfNeeded`)
- does NOT change the existing `PP-3649` non-fatal, which still fires unchanged on activation failure (a SEPARATE new non-fatal is added for the timeout — see Claims)

## Files in scope

- Palace/Reader2/ReaderStackConfiguration/AdobeDRM/AdobeActivationCoordinator.swift
- Palace/Reader2/ReaderStackConfiguration/AdobeDRM/AdobeCertificate.swift
- PalaceTests/DRM/AdobeActivationCoordinatorTests.swift
- PalaceTests/DRM/AdobeActivationDedupTests.swift
- PalaceTests/Mocks/TPPDRMAuthorizingMock.swift
- Palace.xcodeproj/project.pbxproj

## Scope amendment (2026-08-12, during implementation)

`TPPDRMAuthorizingMock` was added to scope after starting: its `authorize` fired
its completion synchronously, so there was no way to hold one activation in
flight while other callers raced in — the exact setup the de-dup test needs. It
gains `shouldDeferAuthorize` / `completeDeferredAuthorize`, mirroring the
`deauthorize` support that was already there, and captures ALL deferred
completions behind a drain-and-stay-open latch so a de-dup regression fails on a
count mismatch rather than deadlocking. Test-infrastructure only; no production
behavior.
