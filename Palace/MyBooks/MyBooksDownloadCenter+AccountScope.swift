//
//  MyBooksDownloadCenter+AccountScope.swift
//  Palace
//
//  Account-scope seam rationale for MyBooksDownloadCenter (Wave 3 S2b).
//
//  This file carries the verbose design rationale for the account-scope seam so
//  the frozen `MyBooksDownloadCenter` hub keeps only terse one-line pointers back
//  here. There is no code in this file — the seam is wired inline in the hub's
//  init; this is documentation that lives in an unfrozen file per the god-class
//  LOC-freeze contract ("land your fix by EXTRACTING into a collaborator, not by
//  growing the hub").
//
//  ── What the seam is ──────────────────────────────────────────────────────────
//  MyBooksDownloadCenter reads two kinds of account state:
//
//    1. Account SCOPE — the current account id and its auth-surface hosts. These
//       are pure identity/host lookups with no credential material. Wave 3 S2b
//       retypes these onto the Downloads-owned `DownloadAccountScopeProviding`
//       seam (`currentAccountID`, `currentAccountAuthSurfaceHosts`).
//
//    2. Account CREDENTIALS — the `TPPUserAccount` used to vend basic-auth /
//       OIDC credentials at the URLSession challenge. These stay on the concrete
//       `AccountsManager` this PR (see the credential/scope split below).
//
//  ── The credential-vs-scope split (why `accountsManager` is retained) ─────────
//  The concrete `accountsManager` is kept ONLY for the credential-vending path:
//  `userAccount` / `userAccount(forCapturedId:)`, the sub-service `accountsManager:`
//  passes, and the deferred B7 `() -> TPPUserAccount` closures. That path is bound
//  to `TPPUserAccount` via `NYPLBasicAuthCredentialsProvider` — a conformance the
//  scope protocol `DownloadUserAccount` does not declare — so it cannot cross to a
//  `DownloadCredentialsProviding` seam yet. It retypes at 3b together with the B7
//  closures (Wave 3 §2), when the URLSession-challenge `TPPBasicAuth` site's
//  `NYPLBasicAuthCredentialsProvider` requirement is resolved.
//
//  ── Why the adapter default ───────────────────────────────────────────────────
//  The `accountScope` init param is optional and defaults — in the init body, not
//  the signature, because a default expression can't reference another param — to
//  an `AccountsManagerDownloadContextAdapter` over the SAME resolved
//  `accountsManager`. Scope and credential reads therefore observe one coherent
//  account. The resolved value is bound to a local (`resolvedAccountScope`) because
//  the pre-`super.init()` wire-up closures (TokenRefreshInterceptor /
//  DownloadAuthRetryHandler) need it before `self` is available; that same local is
//  also passed to the default `BookFileManager` so a test-injected scope spy flows
//  through one seam.
//
//  ── Empty-set-for-nil is behavior-neutral ────────────────────────────────────
//  The adapter's `currentAccountAuthSurfaceHosts` returns
//  `currentAccount?.authSurfaceHosts ?? []` — an empty set where the old direct
//  read (`AppContainer.production().accountsManager.currentAccount?.authSurfaceHosts`)
//  returned nil. This is behavior-identical: the sole consumer, the foreign-host
//  guard in `AuthErrorClassifier` (PalaceAuth), collapses both nil and empty to the
//  same cold-launch legacy fallback via its `!currentHosts.isEmpty` guard (see
//  `AuthErrorClassifier.swift`, the 401 foreign-host early-return, ~lines 196–203:
//  "Empty set is treated like a nil provider (legacy behavior)"). The adapter's
//  `currentAccountID` returns exactly `accountsManager.currentAccountId`.
//
//  Retyping these two host-provider closures also removes the two B6 container-
//  locator `authSurfaceHosts` reaches (locator ratchet drop).
//
//  ── 3b reversal ───────────────────────────────────────────────────────────────
//  This seam nets negative at the 3a/3b package move: when the MyBooksDownloadCenter
//  cluster relocates into the PalaceDownloads package, the account-scope wiring
//  leaves the hub entirely and the small residual growth re-baselined here is
//  reclaimed. The freeze re-baseline for S2b is therefore a temporary carry on the
//  hub, tracked against that reversal, not permanent accretion.
//
