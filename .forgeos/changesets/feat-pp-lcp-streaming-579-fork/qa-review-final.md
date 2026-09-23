# QA / Test-Quality SoD Review — PP-4957 LCP audiobook streaming-from-license

- Branch: `feat/pp-lcp-streaming-579-fork`  tip `b4365d10a`
- Base: `origin/develop`
- Reviewer role: qa_test (test-quality lens)
- Critical path: DRM/LCP audiobook fulfillment
- **Verdict: BLOCKED** (1 concern on the DRM fulfillment success arm; rest is strong)

## Gate note (mechanics)
`heka2 context --role reviewer` shows `plan.required = [hygiene, mutation,
review:architect, stanza, tdd_red_first, verify_before_done]`. There is **no
`review:qa_test` gate** in the plan, so no signed qa_test verdict was submitted
to the ledger — this document is the deliverable. If a qa_test gate is intended,
it must be added to the plan before a signed verdict can be recorded.

## 1. Mutation adequacy — all 3 declared branches killed (PASS)
Each production branch has a named test that fails if the branch is deleted, and
each has a flag-OFF twin that pins the opposite outcome:

- **Fulfillment short-circuit** (`LCPFulfillmentHandler.swift` ~L119-135):
  `testFulfill_streamingEnabled_audiobook_marksSuccessfulOnLicense_noDownload`
  — delete the branch → `lcpService.fulfill` runs (fulfillCallCount 1) and
  markSuccessful is deferred → 3 assertions fail. The `.audiobook` conjunct is
  independently pinned by `testFulfill_streamingEnabled_epub_stillDownloads`
  (drop the content-type check → EPUB takes the streaming branch, fulfillCallCount
  drops to 0 → fails). Confirmed `.AudiobookLCP`→audiobook, `.ReadiumLCP`→EPUB via
  TPPBookMock (same mapping the existing download-first tests rely on).
- **Gate early-return** (`AudiobookSessionManager.shouldTriggerContentDownloadBeforeOpen`,
  `if streamingEnabled { return false }`):
  `testShouldTrigger_streamingEnabled_overridesDownloadFirst_returnsFalse` uses
  identical inputs to the returns-TRUE flag-off twin — delete the branch → returns
  true → fails. `testShouldTrigger_streamingEnabled_neverTriggers_acrossInputs`
  asserts all 8 (cold×canOpen×local) combos, covering the over-fetch domination.
- **Self-heal skip** (`LocalBookContentService.redownloadLCPContentFile`,
  `if streamingEnabledProvider() { return }`):
  `testRedownload_streamingEnabled_doesNotReFetchTheArchive` (callCount 0) vs
  `testRedownload_streamingDisabled_reFetchesTheArchive` (callCount 1) — same
  seeded license-only state, only the flag differs. Delete the branch → flag-ON
  test fetches → fails.

## 2. Flag-OFF regression coverage (PASS)
Download-first is pinned as the default: the new flag falls into `defaultValue`'s
`default: return false` (verified). Fulfillment setUp handler leaves the flag at
production default OFF so all pre-existing tests exercise the unchanged path; the
gate tests pass explicit `streamingEnabled: false`; the self-heal has an explicit
OFF twin. Today's behavior is not silently changed.

## 3. Edge cases — one real gap
- Non-audiobook LCP under the flag: EPUB covered; PDF not (behaviorally the same
  `contentType != .audiobook` path — low risk). WARNING, not blocking.
- Over-fetch: covered by the 8-combo loop (PASS).
- **License-read on the streaming path: SUCCESS arm untested + unreachable
  (CONCERN — see below).**

## 4. Fluff / unobservable assertions
- No fluff or tautology tests. The across-inputs loop is a real Act→Assert over 8
  cases, not a set-then-assert.
- `copyLicenseForStreaming` side effect is correctly NOT asserted (avoids the
  unobservable-assertion trap the brief flagged). Good.

## BLOCKING FINDING (concern) — DRM fulfillment-ID success arm is unverified
`LCPFulfillmentHandler` streaming branch does:
```
if let license = TPPLCPLicense(url: licenseUrl) {
    bookRegistry.setFulfillmentId(license.identifier, for: book.identifier)
} else { Log.error(...) }
```
`TPPLCPLicense.init?(url:)` decodes JSON. The test fixture `writeSourceFile(ext:
"lcpa")` writes 50 bytes of `0xCD` (invalid JSON), and no `.lcpl` fixture exists
in the bundle — so `TPPLCPLicense(url:)` returns nil and the streaming test always
runs the **else (Log.error) arm**. Consequences:
- The success arm and `bookRegistry.setFulfillmentId(...)` are never executed —
  a mutant deleting that call survives.
- No test asserts `registry.fulfillmentId(forIdentifier:)` on the streaming path.
  The fulfillment ID drives LCP return/revoke; on a money/access path CLAUDE.md
  requires every branch tested. This is the "fixture must match production bytes"
  failure mode: the test passes vacuously through the degraded arm.

**Recommendation:** add a valid `.lcpl` JSON fixture (real `id`), route the
streaming audiobook test through it, and assert
`registry.fulfillmentId(forIdentifier: book.identifier) == license.id`. Keep a
second case with an unreadable license that still marks successful + no download,
so both arms are pinned.

## Files
- Prod: Palace/MyBooks/LCPFulfillmentHandler.swift, Palace/MyBooks/LocalBookContentService.swift,
  Palace/Audiobooks/AudiobookSessionManager.swift, Palace/FeatureFlags/RemoteFeatureFlags.swift,
  Palace/Packages/PalaceFeatureFlags/.../PalaceFeatureFlag.swift
- Tests: PalaceTests/MyBooks/LCPFulfillmentHandlerTests.swift,
  PalaceTests/Audiobook/AudiobookContentGateTests.swift,
  PalaceTests/MyBooks/LocalBookContentServiceTests.swift
