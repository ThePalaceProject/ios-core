---
name: pp-4895-async-delegate-auth-challenge
created: 2026-08-17
author: claude-opus-5
jira: PP-4895
---

**ADR refs:** none. The closest recorded decision is the wall-failure
`.forgeos/wall-failures/2026-07-07-pr1205-wknavigationdelegate-mainactor-witness.md`
(same defect class, WebKit sign-in) and the CLAUDE.md rule that a
`nearly matches optional requirement` on a delegate is never benign.

## Context — measured, not theorised

`Palace-noDRM` build of `origin/develop` (a0968e652) emits, verbatim:

```
Palace/MyBooks/MyBooksDownloadCenter.swift:1636:10: warning: instance method
  'urlSession(_:task:didReceive:completionHandler:)' nearly matches optional
  requirement 'urlSession(_:task:didReceive:completionHandler:)' of protocol
  'URLSessionTaskDelegate'
  note: candidate has non-matching type '(URLSession, URLSessionTask,
    URLAuthenticationChallenge, @escaping (URLSession.AuthChallengeDisposition,
    URLCredential?) -> Void) -> ()'
  note: requirement declared here
    optional func urlSession(..., completionHandler: @escaping @MainActor
      @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
```

The same warning fires on `Palace/Network/TPPNetworkResponder.swift:765` — the
app's two and only authentication-challenge implementations.

`@MainActor` is not in the SDK header. `NSURLSession.h` annotates that block
`NS_SWIFT_SENDABLE` only. The `@MainActor` is the Xcode 26.2 ClangImporter
canonical-block-type poisoning already documented for `NSOperationQueue`
(memory `webkit-clangimporter-mainactor-poisoning`, cracked on #1338), now
confirmed on a second block shape:
`void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *)`, shared
between Foundation's `URLSessionTaskDelegate` requirement and WebKit's
`WKNavigationDelegate.webView(_:didReceive:completionHandler:)`, which WebKit
blanket-annotates `WK_SWIFT_UI_ACTOR`.

Reproduced standalone, two files, iOS 26.2 and macOS SDKs, `-swift-version 6
-strict-concurrency=complete`, first-use-wins per frontend process:

| import order | warns on | `responds(to:)` for the ObjC selector |
|---|---|---|
| WebKit decl first | our URLSession method | **false** |
| Foundation decl first | WebKit's method | true |

The runtime consequence is proven, not inferred: in the poisoned batch
`responds(to: NSSelectorFromString("URLSession:task:didReceiveChallenge:completionHandler:"))`
returns **false**. URLSession dispatches optional delegate methods by
`respondsToSelector:`, so the callback is not merely un-witnessed — it is
absent from the ObjC runtime and can never be invoked. Patron-visible effect:
a download served behind HTTP basic auth gets no credential from the app.

Two consequences that shape the fix:

1. Which side loses is decided by frontend batch membership, so an unrelated
   file move can flip it. This is a lottery, not a stable state — which is why
   the DRM target can be green on the same source.
2. Annotating our handler `@escaping @MainActor @Sendable` fixes only the
   poisoned arm and breaks the clean arm. That is the
   `invariant-retirement-needs-a-census` trap; both arms must pass.

Forcing the selector was measured and is not available: an explicit
`@objc(URLSession:task:didReceiveChallenge:completionHandler:)` is a hard
compile error ("provided by method ... conflicts with optional requirement").

## Claims

- replaces the completion-handler spelling of the authentication-challenge
  delegate method with the SDK's **async** spelling —
  `urlSession(_:task:didReceive:) async -> (disposition, credential)` — at both
  sites (`MyBooksDownloadCenter`, `TPPNetworkResponder`). The async requirement
  carries no block parameter, so there is nothing for the importer's
  canonical-block-type cache to poison. Measured: registers in BOTH import
  orders, warns in neither
- preserves the credential decision exactly. `TPPBasicAuth` remains the single
  decision point and is still constructed with the same credentials provider at
  each site; only the shape of the delegate hop changes
- adds `PalaceTests/MyBooks/DownloadAuthChallengeWitnessTests`, which asserts
  the contract the compiler stopped guaranteeing: the ObjC selector is present in
  the class's method list, and the challenge yields the stored barcode and PIN,
  cancels on a repeat failure, defers on server trust, and rejects a protection
  space we do not handle. The behaviour tests call the callback DIRECTLY —
  optional-requirement dispatch through the `URLSessionTaskDelegate` existential
  was tried and crashes swift-frontend in SILGen on Xcode 26.2, so registration
  is asserted separately rather than through that path
- adds the equivalent registration + behaviour coverage for
  `TPPNetworkResponder`
- adds `TPPBasicAuth.response(to:)`, the single place that adapts the existing
  completion-handler decision into the value the async callbacks return. Both
  challenge sites route through it, so the two cannot drift, and the "always
  calls its completion synchronously" assumption is stated once rather than
  twice inline. Covered directly in `TPPBasicAuthTests` by an equivalence test
  across all four protection-space branches
- ratchets the `MyBooksDownloadCenter` god-class baseline DOWN 1257 -> 1256.
  The first draft of this fix grew the hub by 4 lines and the freeze gate
  correctly blocked it; extracting the shared adapter reversed that
- adds `scripts/check-auth-challenge-async-form.py` (ACF-1), a source-level
  detector banning the completion-handler form of an auth-challenge delegate
  callback in `Palace/**`, wired into `verify-pr.sh` and the Phase-3.5
  pre-commit hook, with `scripts/tests/test_check_auth_challenge_async_form.py`
  (12 cases incl. a comment-only-mention pass) and a new assertion in the hook
  fixture test covering both the block AND the clean-diff pass. A source-level
  gate is required because the existing build-log gate can only see the batch
  lottery draw a given build happened to make
- makes `non-drm-build.yml` tee its build and run the existing witness-drift
  gate on that log. CI has never scanned a noDRM build, which is why a detector
  that was already correct never fired on this

## Anti-claims

- does NOT change what disposition is returned for any protection space, or
  what credential is built. `TPPBasicAuth.handleChallenge` is untouched
- does NOT add `@MainActor` anywhere, and does not annotate any handler to
  match the poisoned import shape
- does NOT change the session's delegate queue or the download state machine,
  and does not weaken the `@unchecked Sendable` contract. It DOES narrow that
  contract's stated justification: the new callback is `nonisolated async`, so
  its body runs off the `.main` delegate queue. See the review-driven amendment
  below — the class header now carries an explicit exception instead of a
  universal that is no longer true
- does NOT attempt a general fix for the importer bug or audit every other
  block shape in the app. The build log is the oracle for what is currently
  mis-registered and it names exactly these two sites; a broader sweep of
  WebKit-shared block shapes is called out as follow-up, not done here
- does NOT silence the warning by the compiler's suggested `private` or
  "move to another extension" — both hide the signal the CI detector depends on

## Review-driven amendments (round 1)

Architect (blocking, discipline): the class-header `@unchecked Sendable`
justification on `MyBooksDownloadCenter` asserted that the `.main` delegate queue
means "every delegate callback lands on the main thread". The new callback is
`nonisolated async`, so its body runs on the cooperative pool — the effect is
still safe (traced: `injectedUserAccount` is a `let`; `AccountCredentialResolver`
is deliberately lock-backed rather than an actor precisely so it is reachable
synchronously from any thread; `TPPUserAccount` serializes keychain on
`accountInfoQueue`; the callback writes no MBDC state) but the stated universal
was false. That comment now carries an explicit, reasoned exception rather than
leaving a reader to infer one.

Architect (warning, accepted as follow-up): `void (^)(void)` also carries
`WK_SWIFT_UI_ACTOR` in eight WebKit declarations, and `NotificationService` +
`TPPAppDelegate` implement non-`@MainActor` optional requirements with that
shape. Neither warns in the current DRM or noDRM logs, so both are latent
lottery exposure rather than live defects. Named here so the follow-up is
specific instead of "audit the block shapes some day".

QA (blocking, redundancy): the second registration test could not fail while the
first passed — same method list reached through a compile-time upcast. Replaced
both with a single `instancesRespond(to:)` assertion, which asks the CLASS and so
needs no instance, no production container, and no background session.

QA (blocking, pollution): the suite constructed a download center per test. A
`URLSession` retains its delegate, so a center that delegates for a live session
cannot deinit and its `.shared` observers outlive the suite — real pollution
aimed at exactly the registry suites that read `AppContainer.production()`. Both
suites now build through the documented `urlSession:` seam, which skips
background-session construction entirely; the injected ephemeral session has no
delegate, so nothing retains the center and it deinits normally. THAT is what
closes the vector.

A first pass at this also claimed to cut construction count "from 7 to 2", which
was wrong and both the QA and architect reviewers caught it: `setUp()` runs per
test method, so building both fixtures there made it 12, not 2. The fixtures are
now lazy, so each test constructs only the one it uses and the registration test
constructs none — 5 rather than 12. Stated plainly because the earlier
"two centers for the whole class" wording invited a later reader to turn these
into genuine class-level shared state, which WOULD be pollution.

QA (gap): added the missing `rejectProtectionSpace` cell to the responder suite,
so both challenge sites now cover the same four protection-space branches.

QA (gap, accepted): the `credentialsProvider ?? AppContainer.production()`
fallback arm in `TPPNetworkResponder` is untested. It is an unchanged line, and
exercising it requires warming the production container — the pollution this
round is reducing. Left uncovered deliberately rather than traded against test
isolation.

Both reviewers flagged a dangling citation of the pre-rename intent filename;
fixed. The guard-bite proof was re-run against the new class-level assertion:
same result, no compile error, registration fails while all five behaviour tests
pass.

## Files in scope

- `Palace/MyBooks/MyBooksDownloadCenter.swift`
- `Palace/Network/TPPNetworkResponder.swift`
- `Palace/Packages/PalaceNetwork/Sources/PalaceNetwork/TPPBasicAuth.swift`
- `PalaceTests/MyBooks/DownloadAuthChallengeWitnessTests.swift` (new)
- `PalaceTests/Network/NetworkResponderAuthChallengeWitnessTests.swift` (new)
- `PalaceTests/SignInLogic/TPPBasicAuthTests.swift`
- `Palace.xcodeproj/project.pbxproj` (test-target membership for the new files)
- `scripts/check-auth-challenge-async-form.py` (new)
- `scripts/tests/test_check_auth_challenge_async_form.py` (new)
- `scripts/tests/fixtures/auth_challenge_async_form/` (new)
- `scripts/tests/test_pre_commit_phase35_detectors.sh`
- `scripts/pre-commit-phase35-detectors.sh`
- `scripts/verify-pr.sh`
- `scripts/godclass-loc-baseline.txt`
- `.github/workflows/non-drm-build.yml`

## Verification

- `responds(to:)` proof of the defect and of the fix, both import orders, in a
  standalone two-file reproducer (iOS 26.2 + macOS SDKs)
- `Palace-noDRM` build before: warns on both sites. After: no witness warning
- DRM `Palace` build before: no warning — the same source, the other draw. This
  is the evidence that a build-log gate alone cannot hold the invariant
- 12 new delegate tests + 2 `TPPBasicAuth` tests pass on the DRM target
- Guard-bite proof: with `@nonobjc` on the download-center callback (the
  runtime shape of the defect — method present in Swift, absent from ObjC) both
  registration test fails by name while ALL FIVE behaviour tests still pass. The
  mutant was applied to the download-center callback only, so it exercises that
  suite's guard; the responder's registration assertion is the same construct
  against the same runtime question. Re-run after the assertion was collapsed to
  a single class-level check, rather than assumed to carry over — and the first
  attempt at the mutant was malformed and failed to COMPILE, which per this
  project's rule is not a kill; the reported result is from the corrected one.
  Hand-authored and mechanism-targeted; it is a demonstration that the guard
  bites, not a mutation score
- `palace_mutate.py --diff-only` reports 0 mutation points on the changed lines
  in both files, honestly: the diff introduces no operator, conditional, or
  return to perturb. Reported as an empty surface rather than dressed up as a
  pass
- 12/12 detector pytests; full `scripts/tests/` suite; hook fixture test (7
  assertions)
