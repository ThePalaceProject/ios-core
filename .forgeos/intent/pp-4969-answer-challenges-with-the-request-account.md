---
name: pp-4969-answer-challenges-with-the-request-account
created: 2026-08-17
author: claude-opus-5
jira: PP-4969
stacked_on: PP-4895 (fix/pp-4895-urlsession-auth-witness, tip 5e026959b)
---

**ADR refs:** none. The governing recorded decision is the credential-isolation
invariant documented at the head of
`Palace/Accounts/Library/AccountCredentialResolver.swift` — F-034 (cross-account
credential leak, PP-4020) and F-016 (ride-out over the account-switch window).
This change sits on that boundary and must not weaken either.

## Context

Both of the app's authentication-challenge sites can answer a challenge with a
different library's credentials than the request was made for. Surfaced by the
independent architect and blast-radius reviews of PP-4895; both asked that it
ride alongside that change rather than trail it, because PP-4895 measurably
widens one of the two windows.

**Path 1 — `TPPNetworkResponder`, credential-validation requests.** The
responder holds `credentialsProvider` **weakly** (deliberately — a strong
reference closed a retain cycle: VM → businessLogic → networkExecutor →
responder → provider(=VM)). At challenge time it reads
`credentialsProvider ?? AppContainer.production().accountsManager.currentUserAccount`.
If the only non-nil provider in the app — `AccountDetailViewModel` — is released
while its request is in flight, the fallback substitutes the CURRENT library's
account, so library B's server receives library A's barcode.

PP-4895 did not create this: the VM could already be released before the
challenge arrived. It widened it, because the callback is now the SDK's `async`
requirement and the compiler-generated thunk hops to a Task before the body
reads the weak reference. Per blast-radius, that widening is **not bounded by a
short hop** — under the cooperative-pool saturation this project has already
documented, it can stretch arbitrarily.

**Path 2 — `MyBooksDownloadCenter`, book files behind basic auth.** The callback
resolves credentials through `userAccount`, which is
`injectedUserAccount ?? accountsManager.currentUserAccount` — the account current
*when the challenge arrives*, not the account the download was started for. A
library switch mid-download answers with the new library's card. This one is
older than PP-4895 and is already self-flagged: that property's own doc says new
code on the download path should use `userAccount(forCapturedId:)` instead,
"deterministic across library-swap windows".

Path 2 is only now fixable. The pre-PP-4895 callback was synchronous and
structurally could not reach the actor-isolated `taskIdentifierToBook`; the async
form can `await` it.

## The cell table

Each site is (provider/record state) × (protection space). Enumerated because the
naive fix — return `.cancelAuthenticationChallenge` when the provider is gone —
is WRONG in two of the six cells: cancelling a server-trust challenge breaks
every HTTPS request, and cancelling an unsupported method changes today's
`rejectProtectionSpace` behaviour.

Path 1, `TPPNetworkResponder`:

| provider | HTTP basic | server trust | other method |
|---|---|---|---|
| alive | its credentials | performDefaultHandling | rejectProtectionSpace |
| supplied, since released | **cancel** (was: current account's credentials) | performDefaultHandling | rejectProtectionSpace |
| never supplied | current account's credentials | performDefaultHandling | rejectProtectionSpace |

Path 2, `MyBooksDownloadCenter`:

| started-task record | HTTP basic | server trust | other method |
|---|---|---|---|
| present, account A (current B) | **A's credentials** (was: B's) | performDefaultHandling | rejectProtectionSpace |
| absent / empty account | current account (unchanged) | performDefaultHandling | rejectProtectionSpace |

The whole right-hand side of both tables is reached by routing the degraded case
through a credentials provider that simply HAS no credentials, rather than
hard-coding a disposition. `TPPBasicAuth.handleChallenge` already answers all
three protection spaces correctly for a provider with nil username/pin: basic →
`cancelAuthenticationChallenge`, server trust → `performDefaultHandling`, other →
`rejectProtectionSpace`. So there stays exactly ONE decision point and the two
sites cannot drift from it.

## Claims

- adds `TPPNetworkResponder.wasSuppliedCredentialsProvider`, a `let` recorded at
  init, so a later nil weak reference can be read as "it was released" rather
  than "none was ever supplied". Those two are indistinguishable from the weak
  reference alone and must be answered differently — every other call site in the
  app passes nil deliberately and relies on the fallback, so the fallback cannot
  simply be removed
- on the released path, answers the challenge through a no-credentials provider
  instead of the current account, and logs a warning. Basic-auth challenges are
  therefore declined rather than answered with the wrong library's card, while
  server-trust and unsupported-method challenges keep today's dispositions
  exactly
- adds `fallbackCredentialsProvider` to `TPPNetworkResponder.init` as a
  defaulted, lazily-invoked closure over
  `AppContainer.production().accountsManager.currentUserAccount`. Behaviour-
  neutral — the default resolves at challenge time exactly as the inline
  expression did — and it is the seam that lets the "never supplied" cell be
  tested without warming the production container, which is the pollution PP-4895
  review spent a round removing
- adds `MyBooksDownloadCenter.challengeAccount(for:)` in a NEW collaborator file
  `MyBooksDownloadCenter+ChallengeAccount.swift`, resolving the challenging
  task's account by two well-defined hops the class already trusts elsewhere:
  `taskIdentifierToBook` (the live map used by the progress, completion and
  retry paths) for the book, then the durable started-task record for that
  bookID, whose `account` field is already written at download start. The hub's
  callback body is replaced one-for-one, so the frozen hub does not grow —
  per the freeze contract's "land your fix by EXTRACTING into a collaborator"
- degrades to today's `userAccount` when either hop misses, so a task with no
  live mapping or no durable record behaves exactly as it does now
- covers both cell tables at both sites, including the two cells a naive
  cancel-on-missing-provider fix would break, and all THREE of path 2's
  degradation arms — no live task mapping, mapped but no record, and a record
  whose account is the empty string. A first pass claimed the empty-account arm
  was "covered by the record-absent test on the same branch"; that was wrong,
  they are different branches, and the arm is not hypothetical — the start path
  writes `account: accountScope.currentAccountID ?? ""`, so production emits `""`
  itself. Review caught it. Also adds a selectivity test with two libraries
  downloading concurrently, because with a single persisted record a resolver
  that took the first record would have passed every other test here. The one
  path-2 cell deliberately not written is record-present × unsupported-method,
  which cannot reach a different answer

## Anti-claims

- does NOT remove or alter the `?? currentUserAccount` fallback for the callers
  that intend it — every site that passes no provider keeps reaching the current
  account
- does NOT make `credentialsProvider` strong. That would reintroduce the retain
  cycle the weak reference exists to break
- does NOT change any disposition `TPPBasicAuth` returns, or add a second place
  where a disposition is decided
- does NOT change the download state machine, add state to it, or alter what is
  written at download start. Path 2 only READS the record that is already
  persisted there
- does NOT claim declining is free. The released cell is not always a leak: when
  the account screen's library IS the current library — the common case — the old
  fallback happened to supply the CORRECT credential, and those requests now fail
  instead of succeeding. Sign-out runs through the same executor, so a
  server-side revoke that used to complete may no longer. The trade is deliberate
  and is the standard the credential-isolation boundary sets: an operation that
  fails and can be retried is recoverable, a credential sent to the wrong
  library's server is not. It should still be understood as a trade rather than a
  pure win
- does NOT close the underlying window on path 1. A provider released before the
  challenge arrives is still unobservable; this changes what the app DOES in that
  case, from "send the wrong credential" to "send none"
- does NOT touch `AccountCredentialResolver`, `currentUserAccount`'s ride-out
  behaviour, or the F-034 lock span

## Review-driven amendments (round 1)

Architect and blast-radius both approved; QA requested changes. Everything below
was taken.

**A launch abort I misdiagnosed, and the correction.** A `_os_unfair_lock_recursive_abort`
under `AppContainer._cachedValue()` killed the app at launch mid-round, and I
attributed it to the then-new `fallbackCredentialsProvider` default — a closure
over `AppContainer.production()` — reasoning that the container constructs the
responder, so the default was reachable from `init`.

**That attribution was wrong and is retracted.** Both reviewers independently
built standalone reproductions showing a closure-literal default argument does not
invoke its body at the call site; I then restored the closure default on the real
app with a clean derived-data and it passed. The commit that had already shipped
that exact shape, 036c2ff1c, ran 8308 tests without crashing — evidence in my own
history I failed to check before generalizing. The abort was real; **its cause is
unidentified.** The leading unexcluded candidate is that the run immediately
before it failed to COMPILE, so the crashing build was incremental on top of a
partially-built module.

What IS verified, and is what the comment and memory now teach: the hazard class
is real but belongs to VALUE-typed defaults, which are evaluated at the call site.
`TPPNetworkExecutor`'s DI-friendly init carries exactly that form —
`accountsManager: TPPLibraryAccountsProvider = AppContainer.production().accountsManager`
— and is safe today only because overload ranking prefers the `@objc` init for the
container's own call. Safe by accident, and named here so it is not load-bearing
by accident silently.

The parameter stays `nil`-defaulted regardless, for a reason that survives the
correction: it keeps container reads off every construction path by SHAPE rather
than by argument-evaluation rules, which is the property worth having when the
container is what builds you.

**A false census in my own comment (QA).** I had written that every site seeding
`taskIdentifierToBook` writes the durable record first, and called that ordering
load-bearing. Three of the five do not: the bearer-token re-issue
(`RightsManagementDispatcher`), the follow-up/rights re-issue
(`BackgroundDownloadHandler`), and launch-reconciliation adopt. Verified by
reading each. The real guarantee is bookID keying with an upsert-by-bookID store,
which is why a re-issued task inherits the right account and why task-identifier
reuse is irrelevant. The comment now says that instead.

**Path 2 had three degradation arms, not two (QA).** No live task mapping,
mapped-but-no-record, and record-with-empty-account. Only the first was tested,
and the test was misnamed for the second. All three now have a test, and the
empty-account arm is not hypothetical — the start path writes
`account: accountScope.currentAccountID ?? ""`.

**A third survivor mutant, found by QA on re-review.** Re-keying hop 2 from
bookID to `taskIdentifier` passed the entire suite, because every test until now
challenged with the same identifier it persisted under. That refactor looks like a
tightening and would silently break the bearer-token and rights re-issue paths,
whose correctness rests entirely on bookID keying. A re-issue test — record
written under one task identifier, challenge arriving on another mapped to the
same book — now kills it.

**Two named survivor mutants (QA, first round).** Dropping the emptiness guard, and taking the
first record rather than the challenging book's. Both survived the original
suite; a selectivity test with two libraries downloading concurrently and a
sharpened empty-account test now kill them. The first attempt at the
empty-account test passed for the wrong reason — it injected an account, which
wins over the captured id and made the guard invisible — so it now asserts on the
resolver's returned account identity, which is the only place the distinction is
observable.

**An ARC lifetime hazard in a test (architect and blast-radius, independently).**
`ProviderBox`'s last use sat before the `await`, so an optimized build could
release the provider before the challenge and turn a pass into a decline. Pinned
across the await.

## Review-driven amendments (round 2) — a CI-only failure the local suite hid

CI failed three of the new download-path tests while the local full suite
reported 8308 tests / 0 failures. They failed all three retry iterations, so not
flakes. This was found only because the PR's CI was checked before merging, not
because anything local caught it.

**Mechanism, verified in source by two reviewers independently.**
`TPPKeychainStoredVariable.write()` sets `cachedValue` and `alreadyInited = true`
BEFORE attempting the keychain write, and `read()` short-circuits on
`alreadyInited`. So a single instance never consults storage — a silent `-34018`
is invisible — while a SECOND instance for the same library must hit the keychain
and gets nothing. `TPPUserAccountTestFactory.makeIsolated(libraryUUID:)`
deliberately constructs a fresh account bypassing the accounts-manager cache, so
the account the test wrote and the account the resolver returned were two objects
agreeing only through storage. Green locally, deterministically red on CI.

It is also the pattern this project's test rules ban outright: never hit the real
keychain, inject instead.

**Fix.** The captured-account tests mint through the accounts manager the center
under test is built with, so test and resolver share one instance and storage
leaves the path.

A first attempt used `AppContainer.production().accountsManager`, which CI
rejected: `AppContainerIsolationLintTests` bans `production()` reads in test
bodies outside a whitelist, and that test failed all three iterations.

The manager is now minted via `PalaceWiringTestCase.makeFreshAccountsManager()`,
and the suite is based on `PalaceWiringTestCase`.

Two earlier attempts were both wrong, and CI caught each:
`AppContainer.production().accountsManager` tripped
`AppContainerIsolationLintTests`; a hand-rolled `AccountsManager()` then tripped
`AccountsManagerIsolationLintTests`. The second is the more instructive failure —
the hand-rolled form pinned the same opt-out flag but LEAKED
`cancelAndDrainBackgroundWork()`, which the sanctioned seam registers on
teardown. So the lint was not enforcing a style preference; it was enforcing a
cleanup I had silently dropped, exactly the sort of thing a local run does not
show. The seam does everything the hand-rolled version did, plus that.

A note on process rather than code: this repo has NINE meta-lint classes and I
had been running two. They assert over the whole test corpus, so no
`-only-testing` selection derived from changed files can reach them — a
structural blind spot, not forgetfulness. All seven scannable ones now run
against this branch. That is the
"hand-rolled `AccountsManager()`" an earlier round recorded as unacceptable, and
that rejection was wrong: the objection was the background `loadCatalogs`
outliving the test, and pinning the flag is exactly what suppresses it — which is
all `makeTestAppContainer()` does for that concern. Correcting the record rather
than leaving a rationale that rejects an option for a reason it also removes.

The lint's suggested remedy, `makeTestAppContainer()`, was tried and rejected on
its own merits: it builds an entire container to yield one member, and the
`MyBooksDownloadCenter` inside it is constructed WITHOUT the `urlSession:` seam,
so it creates a background `URLSession` on the single static identifier with
itself as delegate — never invalidated, delegate retained, one stranded center
per call. That is the exact pollution this file's seam exists to avoid, so
routing the fixture through it would have reintroduced through the back door what
the suite closes at the front.

Either way the resolver-cache residue the review weighed is gone: nothing
synthetic is inserted into the production graph.

Honest caveat: the flag lives behind `#if DEBUG`, so in a non-DEBUG configuration
the background load is not suppressed. That is true of the factory as well, so it
is not a regression introduced here — but it is not a guarantee either. Accounts are torn down per test. The instance-sharing property is asserted
directly rather than left implicit, in all three converted tests.

Those assertions test INSTANCE IDENTITY, not credential visibility, and the
distinction is the whole point. Two instances for one library agree via the
keychain, which SUCCEEDS on a developer machine — so a `barcode ==` precondition
passes locally and fails only on CI, reproducing the exact property this round
exists to eliminate. Identity never round-trips through storage, so it fails
locally. A first pass used `barcode ==` in two of the three and review measured
the difference: reverting the helper failed 1 of 3 locally with the credential
form, 3 of 3 with identity. All three are identity now, with a credential
assertion kept alongside for the diagnostic message.

**Two reviewer answers worth recording**, because both push back on the "cleaner"
option:
- Injecting a stub `AccountsManager` was rejected. A fresh `AccountsManager()`
  starts a background `loadCatalogs` that outlives the test — a documented
  polluter here — and a protocol seam would be a production signature change to a
  frozen god-class on the download critical path, made to serve a test. The
  retype belongs with the S2b MBDC wave, and even then would not simplify these
  tests, since `userAccount(forCapturedId:)` prefers `injectedUserAccount`.
- Evicting the synthetic accounts from the resolver cache was rejected: nothing
  enumerates that cache, `userAccount(for:)` does not write
  `lastKnownCurrentUserAccount` (so F-016's ride-out cannot pick one up), and
  `TPPUserAccount.init(libraryUUID:)` is inert. Adding an eviction API purely for
  tests would be new production surface serving only tests.

**One belief corrected:** `removeAll()` is NOT scoped to an account's own keychain
keys — it also broadcasts `TPPDidSignOut` globally and posts through
`UserAccountPublisher`. Net-new risk here is ~zero, because
`TPPUserAccountTestFactory`'s resetter already called it on every minted account,
so only the timing changed. Recorded so nobody later moves that call somewhere it
does matter.

## Not done — adjacent reads left alone

`BackgroundDownloadHandler.swift:267` attaches `delegate.userAccount.authToken` —
the CURRENT account — to the follow-up download request for a book that may have
been started under another library. Same F-034 boundary and the same
current-versus-started-for shape this ticket fixes at the challenge site, and it
is a second consumer of the very property path 2 redirects away from. Named
explicitly rather than gestured at, per review; out of scope here because it is a
request-construction path rather than a challenge answer, and deserves its own
tests.



`TPPNetworkResponder` reaches `currentUserAccount` on several other paths (the
401 handling, token refresh, and `refreshToken`'s default argument), and the
download start / bearer-auth path has its own `forCapturedId` note. Those are the
same family and are deliberately untouched here: each would need its own
reasoning about which account a retry or a refresh belongs to, and bundling them
would put several credential-routing decisions in one revert unit.

## Files in scope

- `Palace/Network/TPPNetworkResponder.swift`
- `Palace/MyBooks/MyBooksDownloadCenter.swift` (callback body, one line)
- `Palace/MyBooks/MyBooksDownloadCenter+ChallengeAccount.swift` (new)
- `PalaceTests/Network/NetworkResponderAuthChallengeWitnessTests.swift`
- `PalaceTests/MyBooks/DownloadAuthChallengeWitnessTests.swift`
- `Palace.xcodeproj/project.pbxproj` (both targets for the new production file)
