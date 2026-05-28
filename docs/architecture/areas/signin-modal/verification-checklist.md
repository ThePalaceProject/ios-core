<!-- audit-verified: file list, line citations, call-site counts, test inventory, and commit SHAs (8ed7451c1 PR #905, ca5a2fb80/24dc6021d/9ffcfcfcf SignInModal predicate extraction, da9875e28 PR #907 SAML SwiftUI conversion) all confirmed via `ls Palace/SignInLogic/`, `git log --oneline origin/develop`, `grep -rn`, and `wc -l` on 2026-05-28. PP-4421 placeholder fix landed in `Palace/Settings/AccountDetailView.swift` lines 344 & 369 (verified). HelpSpot 17923 revert per `feedback_no_new_copy_without_design.md`. -->

# Sign-in modal area — verification checklist

**Owner area:** `Palace/SignInLogic/SignInModalView.swift`, `Palace/SignInLogic/SignInWebSheet.swift`, `Palace/SignInLogic/SignInWebSheetPresenter.swift`, `Palace/SignInLogic/SignInWebSheetViewModel.swift`, `Palace/SignInLogic/SignInWebViewCoordinator.swift`, and the modal entry points in callers listed below. **Scope distinction:** this file covers the modal *surface* (presentation, dismissal, web-sheet bridge). The sign-in business logic, `TPPSignInBusinessLogic`, auth flow dispatch, and AuthCoordinator routing live in `docs/architecture/areas/auth/verification-checklist.md` — read both before changing anything that crosses the boundary (e.g. the modal's completion hook firing into a coordinator-driven retry).

**Purpose:** the architect's first deliverable on ANY swarm or /rigorous-fix in this area is *update this file*. Verify what's still true, add what's changed, mark what's UNKNOWN. The modal surface has bitten us twice (PP-4114 race, PP-4421 placeholder contrast, HelpSpot 17923 unapproved-copy revert) — each was caused by skipping a precondition that's now codified here.

**Last refresh:** 2026-05-28 (initial baseline).
**Refreshing architect:** sign and date the next-refresh row at the bottom of this file.

---

## 1. Call-site map (where the modal is presented / dismissed)

### 1a. `SignInModalPresenter.presentSignInModalForCurrentAccount(...)` consumers

| File | Line | Trigger | Notes |
|------|------|---------|-------|
| `Palace/AppInfrastructure/DLNavigator.swift` | 86 | Deep-link nav | UIKit context — may fire before SwiftUI root mounts. |
| `Palace/Network/TPPNetworkExecutor.swift` | 489 | 401 handler | Fire-and-forget (`completion: nil`); may not be on `MainActor`. |
| `Palace/Holds/HoldsViewModel.swift` | 81 | Place-hold from anonymous state | SwiftUI VM. |
| `Palace/SignInLogic/TPPReauthenticator.swift` | 54 | Re-auth orchestration | Threaded through coordinator post-PR #1018. |
| `Palace/Book/UI/BookDetail/BookDetailViewModel.swift` | 659 | Borrow → sign in → resume | **PP-4114 race site.** Sets `showHalfSheet = true` in completion. |
| `Palace/MyBooks/MyBooksDownloadCenter.swift` | 495, 645 | Borrow + token-refresh | Two call sites. |
| `Palace/MyBooks/TokenRefreshInterceptor.swift` | 213 | OAuth refresh fallback | Silent-reauth-fails branch. |
| `Palace/MyBooks/MyBooks/MyBooksViewModel.swift` | 198 | Re-auth from MyBooks list | Fire-and-forget. |
| `Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift` | 618, 643 | Borrow + retry | Two call sites. |

Documentation-only references (NOT call sites — update if file moves): `Palace/MyBooks/BorrowOperation.swift:180`, `Palace/MyBooks/CredentialPromptCoordinator.swift:41`.

### 1b. Modal dismissal paths

- **Success:** `SignInModalView` body completion → `SignInModalHostingController.viewDidDisappear` → `onDidFullyDismiss` callback → caller's completion. Order: clear `isPresenting` BEFORE running completion (`SignInModalView.swift:160–168`).
- **User cancel:** Cancel button → `dismiss()` (SwiftUI inline) → hosting controller `viewDidDisappear` → completion fires (callers must tolerate completion-after-cancel).
- **Error:** error alert dismisses; modal remains open. No completion fires until the user retries or cancels.

### 1c. Web-sheet variants (SAML / OIDC redirect path)

| File | Lines | Role |
|------|-------|------|
| `Palace/SignInLogic/SignInWebSheet.swift` | 131 LOC | SwiftUI sheet wrapper around the WKWebView surface. |
| `Palace/SignInLogic/SignInWebSheetPresenter.swift` | 156 LOC | **Static API only** (`presentOnTop`, `dismissTop`, `cleanup(uuid:)`). Required `CoordinatorSignInModalPresenter` instance adapter in PR #1018 for AuthCoordinator wiring. |
| `Palace/SignInLogic/SignInWebSheetViewModel.swift` | 190 LOC | Owns navigation lifecycle, problem-document recording, cookie sync. |
| `Palace/SignInLogic/SignInWebViewCoordinator.swift` | 102 LOC | UIViewRepresentable bridge to WKWebView. |
| `Palace/SignInLogic/LegacySAMLAuthAdapter.swift` | 137, 183, 192, 198 | Constructs `SignInWebSheetViewModel`; calls static `presentOnTop` / `dismissTop`. |
| `Palace/MyBooks/MyBooksDownloadCenter.swift` | 1142 | Constructs `SignInWebSheetViewModel` for download-side reauth. |
| `Palace/MyBooks/BookSignInRedirectHandler.swift` | 105 | Constructs `SignInWebSheetViewModel` for borrow-redirect reauth. |

PR #907 (`da9875e28`) converted the SAML web view from the last remaining `UIViewController` to SwiftUI — there is no UIKit web modal surface left in SignInLogic.

---

## 2. Module ownership

| Module / file | Owner | Public surface (changes break callers) |
|---------------|-------|---------------------------------------|
| `Palace/SignInLogic/SignInModalView.swift` | Main target | `SignInModalView` SwiftUI view + `SignInModalPresenter` static class (`presentSignInModal`, `presentSignInModalForCurrentAccount`) + `SignInModalHostingController`. `@objcMembers` — assume ObjC callers may exist; grep `*.m`/`*.mm` before deleting. |
| `Palace/SignInLogic/SignInWebSheet*.swift` (4 files) | Main target | `SignInWebSheet` view, `SignInWebSheetViewModel` (constructed by 3 callers in `Palace/MyBooks/` + `Palace/SignInLogic/LegacySAMLAuthAdapter.swift`), `SignInWebSheetPresenter.presentOnTop / .dismissTop / .cleanup(uuid:)` (static), `SignInWebViewCoordinator` (`UIViewRepresentable`). |
| Modal predicate logic | Main target | `SignInModalPredicates` extracted in `ca5a2fb80` / `24dc6021d` / `9ffcfcfcf` (3 attempts to land cleanly) for mutation-gate coverage. Closed the 0%-kill-rate gap reported in `regression_develop_2026_05_11_evening.md`. |

**Next-sprint trunk move:** per `~/.claude/plans/palace-3.2.0-auth-architecture.md`, `Palace/SignInLogic/` (including modal files) is targeted to move under `Palace/Packages/PalaceAuth/`. Coordinate with the auth checklist owner before moving — the modal surface has 9 callers outside `SignInLogic/` that all import from the main target today.

---

## 3. Modal × auth-type matrix

Columns = (initial sign-in / coordinator-driven reauth / sign-out trigger / cancellation). "—" = no modal path.

| Auth type | Initial sign-in | Reauth | Sign-out trigger | Cancellation handling |
|-----------|-----------------|--------|------------------|----------------------|
| `.basic` | Modal w/ barcode + PIN fields | Modal (after silent token refresh fails) | Cancel button → clear creds → dismiss | Completion fires; caller resumes anonymous flow |
| `.token` | Modal w/ token-entry field | Modal | Cancel → dismiss | As basic |
| `.oauth` (Clever) | Modal opens, taps "Sign In", launches `ASWebAuthenticationSession` | Modal (always — silent path not supported) | Cancel out of OAuth sheet → modal stays; cancel modal → dismiss | Completion fires; OAuth cancel does NOT dismiss modal |
| `.saml` | Modal opens, taps "Sign In", launches `SignInWebSheet` (WKWebView) | Modal (always — see auth checklist §3) | Cancel in web sheet → web sheet dismisses → modal stays | Web-sheet cancel does NOT dismiss modal; user must cancel modal explicitly |
| `.oidc` | Modal opens, launches `ASWebAuthenticationSession` | **Silent reauth** at `TokenRefreshInterceptor.triggerOIDCReauth` (line 533) — NOT through modal. Modal fallback only if silent reauth fails. | Cancel → dismiss | As oauth |
| `.anonymous` | **No modal** — `presentSignInModalForCurrentAccount` short-circuits at `SignInModalView.swift:188–193` (`!userAccount.needsAuth` → fire completion, do not present). SQ-005 invariant. | — | — | — |
| `.coppa` | **No modal** — same path as anonymous. | — | — | — |

**Account-switching guard:** `SignInModalView.swift:142–145` — if `accountsManager.isAccountSwitching`, suppress presentation. F-032 invariant.

---

## 4. Presentation lifecycle invariants (DO NOT regress)

These were learned the hard way; each is enforced by code + tests today.

1. **Duplicate-suppression:** `SignInModalPresenter.isPresenting` static flag (line 131). Concurrent 401s from catalog refresh + bookmark sync + user-profile fetch must NOT stack modals. Test: `SignInModalPredicateTests`.
2. **Anonymous skip:** `!userAccount.needsAuth` → fire completion, do not present (SQ-005). Tested in `SignInModalPredicateTests`.
3. **Account-switch suppression:** mid-401 account swap must NOT prompt for the old library (F-032). Verified at `SignInModalView.swift:142`.
4. **Completion fires AFTER dismissal:** `SignInModalHostingController.viewDidDisappear` is the only place the caller's completion runs. SwiftUI inline `dismiss()` does NOT call completion. This is the PP-4114 fix (commit `8ed7451c1`) — do not regress by adding an inline completion to the SwiftUI view body.
5. **Clear `isPresenting` BEFORE completion:** lines 160–168. Caller's completion may itself present a half-sheet (BookDetail does) — the guard must be down when it runs.
6. **forceReauthMode is hard-coded `true`** in the wrapped `AccountDetailView`. If a future caller wants the non-force-reauth path, that is a separate decision and requires re-evaluating the cancel-button semantics.

---

## 5. Telemetry surface points

The modal surface itself does not emit dedicated analytics events today (it's a UI shell). Auth-decision telemetry lives in the AuthCoordinator path — see `docs/architecture/areas/auth/verification-checklist.md` §5. Candidate gaps (file as tickets, do not silently add):

- `modalPresented` — would let us correlate modal-show frequency with anonymous-skip-rate to detect mis-classified libraries.
- `modalDismissedCancel` vs `modalDismissedSuccess` — currently only the auth-coordinator `modalCancel` event fires, and only when the coordinator was the presenter. Direct callers (DLNavigator, BookCellModel) are not instrumented.
- `webSheetProblemDocumentReceived` — `SignInWebSheetViewModel.recordProblem(document:)` is a known telemetry-emission seam per `LegacySAMLAuthAdapter.swift:117` comment.

---

## 6. Test surface

**Modal-specific test files** (PR #938 closed the 0% mutation-kill gap on `SignInModalView`; current mutation-kill rate on `SignInModalView.swift` is 100% per the PR #938 thread):

| File | LOC | What it covers |
|------|-----|----------------|
| `PalaceTests/SignInLogic/SignInModalPredicateTests.swift` | 75 | Anonymous-skip + duplicate-suppression + account-switch-guard predicates (extracted for mutation-gate coverage). |
| `PalaceTests/SignInLogic/SignInModalSAMLOIDCTests.swift` | 182 | 8 tests — SAML/OIDC modal-launch path; web-sheet bridge wiring. |
| `PalaceTests/SignInLogic/SignInWebSheetViewModelTests.swift` | 365 | View-model unit tests — navigation lifecycle, problem-doc recording, cookie sync handoff. |
| `PalaceTests/SignInLogic/SignInWebSheetIntegrationTests.swift` | 182 | Integration — view-model + coordinator + presenter wiring. |
| `PalaceTests/SignInLogic/LegacySAMLProblemDocumentPropagationTests.swift` | — | Cross-cutting: web sheet → adapter → business logic problem-doc propagation. |

**Driver guidance — simdrive, not XCTest, for SAML/OIDC modal end-to-end.** Safari out-of-process sheets (ASWebAuthenticationSession + WKWebView) are invisible to XCTest accessibility. The recommended driver is simdrive — see `.simdrive/journeys/` for the existing SAML journeys and CLAUDE.md "E2E / UI sim driving — simdrive" for tool rules. Add new SAML/OIDC modal flows there, not under `PalaceTests/UI/`.

**Tests that test BEHAVIOR (must survive any refactor):**
- All 4 invariants in §4 (predicates + PP-4114 completion-after-dismissal).
- SAML web-sheet problem-document propagation.
- Anonymous/COPPA short-circuit.

**Tests that test IMPLEMENTATION (can be rewritten when underlying changes):**
- Tests that assert on `SignInModalHostingController`'s internal callback order — these will need to be rewritten when the full-SwiftUI refactor lands (see §7).
- Tests asserting on `SignInWebSheetPresenter` static-API surface — will change when the presenter is converted to instance-based for the AuthCoordinator path (already partially done via `CoordinatorSignInModalPresenter` in PR #1018).

---

## 7. Known traps / anti-patterns

- **PP-4421 placeholder contrast** — `SignInModalView` text-field placeholders rendered grayed-out, indistinguishable from disabled fields. Fixed via SwiftUI explicit `prompt:` with `.secondary` foreground (landed in 3.1.0; see `Palace/Settings/AccountDetailView.swift:344, 369` for the canonical pattern — same fix applies if a new field is added to the modal). Do NOT regress by adding a field with bare `TextField("Placeholder", text: $x)`.
- **HelpSpot 17923 / unapproved-copy revert** — engineering fix added a caption "Tap here to enter your [label]" above each field; the new copy never went through Lyrasis design review. Reverted in PR #976 / `547e185aa`. **NEVER add user-facing copy in this area without design sign-off recorded in the PR description.** Applies to placeholders, button labels, alert text, captions — anything visible to the user. Snapshot tests pinning new strings are also gated.
- **`SignInWebSheetPresenter` STATIC API** — required an instance adapter (`CoordinatorSignInModalPresenter`) for AuthCoordinator integration in PR #1018. New consumers should use the instance adapter, not the static API. Static API is preserved for `LegacySAMLAuthAdapter` (lines 192, 198) and the legacy SAML callers in `Palace/MyBooks/`; do not add new static-API callers.
- **Full-SwiftUI modal refactor is in backlog** (~150–200 LOC, 12 call sites — see `memory/signin_modal_swiftui_refactor.md`, Option A from PR #905 follow-up). Until it lands, the modal is a SwiftUI view hosted in a `UIHostingController`, presented imperatively via `TPPPresentationUtils.safelyPresent`. The architecture is *correct but fragile* — any caller that presents a SwiftUI sheet synchronously in the completion is at risk of the PP-4114 race. Wire completion → next-sheet via `@Published` + `.onChange`, not synchronous calls.
- **iOS 26 UITextField focus quirks** affect the modal. Confirm via simdrive after any iOS version bump — focus-on-appear and tab-key dismissal both regressed once on iOS 26 alpha SDKs. Recording the modal-open journey in `.simdrive/journeys/` is the fastest way to catch this.
- **Deep-link entry from `DLNavigator`** — `application(_:open:)` may fire before the SwiftUI root mounts. Current UIHostingController path tolerates this; a future full-SwiftUI sheet must buffer the request on the coordinator and present once the root view appears.
- **Fire-and-forget completion** — `TPPNetworkExecutor:489`, `MyBooksViewModel:198` both pass `completion: nil`. The modal-fire-and-forget code path is implicit in `SignInModalPresenter.presentSignInModal` (passes nil through the hosting controller's `onDidFullyDismiss`). Do not assume a completion will run when the caller did not register one.

---

## 8. Architect's pre-swarm checklist (what to verify before writing a new contract)

Before any new swarm or /rigorous-fix in this area, the architect should:

1. **Refresh §1 & §3** — confirm the 9 call-site files + 6 web-sheet caller lines + auth-type matrix are still accurate. `grep -rn "presentSignInModalForCurrentAccount\|SignInModalPresenter\|SignInWebSheetViewModel" Palace/ --include="*.swift"` catches drift.
2. **Confirm the 4 lifecycle invariants in §4 still hold** — run `PalaceTests/SignInLogic/SignInModalPredicateTests` + `SignInModalSAMLOIDCTests` against current `develop`. If a test is flaky, fix the test before starting the swarm — do NOT skip with `XCTSkip`.
3. **Re-check mutation kill rate** — `python3 scripts/palace_mutate.py --file Palace/SignInLogic/SignInModalView.swift --tests PalaceTests.SignInModalPredicateTests` must report 100%. Anything less is a regression of PR #938.
4. **Verify no new user-facing copy** — `git diff develop... -- 'Palace/SignInLogic/SignInModal*.swift' 'Palace/SignInLogic/SignInWeb*.swift'` and inspect every string literal. If new copy exists, hold the swarm until design sign-off is recorded in the PR description.
5. **simdrive sanity** — replay one SAML and one OIDC modal journey from `.simdrive/journeys/` against the rebuilt app. WKWebView focus and ASWebAuthenticationSession presentation must work — XCTest cannot see either surface.
6. **Update §9 (refresh history)** with date + your initials.

---

## 9. Refresh history

| Date | Refreshed by | Notes |
|------|-------------|-------|
| 2026-05-28 | Initial baseline (chore/swarm-rigor-meta-improvement) | Mined from `memory/signin_modal_swiftui_refactor.md`, `feedback_no_new_copy_without_design.md`, PR #905 (`8ed7451c1`), PR #907 (`da9875e28`), PR #938 (mutation-gap close), PR #976 (HelpSpot 17923 revert), PR #1018 (`CoordinatorSignInModalPresenter` adapter). Modal file inventory confirmed via `ls Palace/SignInLogic/` (5 files, 776 LOC total). |

---

**This file is owned by the sign-in modal area.** If you change anything in the files listed in §2, update the relevant section here before you commit. The Definition of Done (CLAUDE.md) treats out-of-date area checklists as scope debt. Cross-area changes that touch both this surface and the auth-flow business logic must update BOTH checklists.
