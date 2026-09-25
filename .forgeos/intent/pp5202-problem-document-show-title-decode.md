---
name: pp5202-problem-document-show-title-decode
created: 2026-09-23
author: claude-opus-5
---

## Summary

PP-5202 / PR #1462 review [r4073991333](https://github.com/ThePalaceProject/ios-core/pull/1462#discussion_r4073991333).

PR #1462 added `public let showTitle: Bool?` to `TPPProblemDocument` so a library can ask the
client to render its patron-blocking message without the standard title. `TPPProblemDocument`
uses synthesized `Codable`, whose `decodeIfPresent` returns `nil` only for an ABSENT or `null`
value and THROWS `typeMismatch` on a present-but-wrong-typed one, aborting the whole decode.

Declaring the member therefore moved `show_title` from "unknown key, ignored whatever its type"
into "must be exactly right or the caller gets no document at all". A server sending
`"show_title": "false"` or `0` — plausible, since many templating layers stringify booleans —
discards the ENTIRE problem document.

On the sign-in path that is not cosmetic: `TPPNetworkResponder` parses with the strict
`fromData`, its `catch` arm returns an `NSError` with no problem document,
`userFacingSignInError` receives `nil`, skips the branch PR #1462 just added, and falls through
to "invalid credentials". A patron blocked by library policy is told their password is wrong and
the library's `detail` never renders.

This change makes the flag — and only the flag — non-fatal, and builds a wall against the
instinctive fix, which silently deletes the feature: an explicit `CodingKeys` case spelled
`showTitle = "show_title"` matches NOTHING, because `.convertFromSnakeCase` rewrites the incoming
key before matching.

## Claims

- adds an explicit `private enum CodingKeys: String, CodingKey` with **camelCase** `showTitle` to `Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/TPPProblemDocument.swift`
- adds `public init(from decoder: Decoder) throws` to the same file, decoding the five RFC 7807 members exactly as synthesized `Codable` did and decoding `showTitle` inside a `do`/`catch` that assigns `nil` on a type mismatch
- adds a `Log.warn` on the `catch` branch so a server misconfiguration is discoverable rather than silent (`PalaceCatalog` already links `PalaceLogging`)
- adds `// PUBLIC_INTENT:` rationales above `showTitle`, `shouldShowTitle`, and `init(from:)`
- adds decode-table tests to `PalaceTests/ProblemDocumentTests.swift` covering `false`, `true`, `"false"`, `0`, `null`, absent, unknown-key, and other-members-stay-strict
- adds two round-trip tests to the same file — snake encoder/decoder, and plain encoder/decoder — pinning the wire format in the TEST rather than in the type
- adds `blockedByPolicyDocument(showTitleLiteral:)` plus four named sign-in tests to `PalaceTests/TPPSignInBusinessLogicTests.swift` asserting a blocked patron still sees the library message
- adds Section 7b (the problem-document decode seam) to `docs/architecture/areas/network/verification-checklist.md`
- adds `.forgeos/wall-failures/2026-09-23-pr1462-snakecase-codingkeys.md`

## Anti-claims

- does NOT land the `check-snakecase-codingkeys.py` detector or any of its wiring — designed, written and reviewed, but split into its own follow-up PR because block-mode tooling that can stop every developer's commit should be reviewed on its own merits, not as a passenger on a sign-in fix. Preserved on `origin/pp5234-snakecase-codingkeys-detector` (PR #1512) — pushed, not local.

- does NOT make the five RFC 7807 members lenient — a wrong-typed `status` stays fatal (pre-existing, deliberately not widened)
- does NOT make `fromData` itself lenient or non-throwing — callers rely on the throw to distinguish a problem document from unrelated JSON
- does NOT add a custom `encode(to:)` — the synthesized encoder already round-trips through the new `init(from:)`, and a snake_case encoder would break every plain-decoder round trip
- does NOT touch `Palace/Network/TPPNetworkResponder.swift` — its `catch` arm is correct for a genuinely unparseable body
- the DECODE commit does not touch `Palace/SignInLogic/TPPSignInBusinessLogic.swift`
  — `userFacingSignInError` was starved of input, not wrong. NOTE: the feature
  commits on this branch DO change that file (`userFacingSignInError` honours
  `shouldShowTitle`), so this anti-claim is scoped to the decode fix, not to the
  branch as a whole.
- does NOT touch `AuthErrorClassifier`
- does NOT reconcile the strict/lenient `{"status":"403","show_title":0}` divergence — that needs `fromDictionary`'s public contract to change; recorded as known debt in Section 7b

## Files in scope

- Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/TPPProblemDocument.swift
- Palace/SignInLogic/TPPSignInBusinessLogic.swift (feature commits — see Anti-claims)
- PalaceTests/ProblemDocumentTests.swift
- PalaceTests/TPPSignInBusinessLogicTests.swift
- docs/architecture/areas/network/verification-checklist.md
- .forgeos/wall-failures/2026-09-23-pr1462-snakecase-codingkeys.md
