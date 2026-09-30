# Swift concurrency doctrine

<!-- audit-verified -->

How to resolve a concurrency diagnostic in this repo. Lifted from the Swift 6
modernization plans when those were retired — the migration finished at PR
**#1199** (`SWIFT_VERSION 5.0 → 6.0`), and the project now builds at
`SWIFT_VERSION = 6.0` with `SWIFT_STRICT_CONCURRENCY = complete` on every
config, so a violation is a compile **error**, not a warning.

The plans were exhaust once that landed. This is the part that wasn't: the
rules were paid for across 10+ merged PRs and they apply to code written now.

## Fix by ISOLATION, never `nonisolated(unsafe)`

The #1129 playbook, in the order to try:

| diagnostic | fix |
|---|---|
| value type not `Sendable` | add `: Sendable` — additive, no behaviour change |
| generic `T` crossing a `Task`/continuation | constrain it: `<T: Sendable>` |
| class captured or crossed | `final class … : @unchecked Sendable` **with a documented invariant** — lock-guarded, or immutable-after-init. **No bare `@unchecked`.** |
| `@MainActor` member reached from nonisolated | `await MainActor.run { }`, or mark the member `@MainActor` |
| delegate conformance "crosses into main actor-isolated code" | `@preconcurrency` on the *conformance* (the EmailTicketGateway #1134 pattern) |
| a module's types not Sendable-audited | `@preconcurrency import <Module>` |

**`nonisolated(unsafe)` is not on this list.** It silences the compiler without
establishing the invariant, so the next reader cannot tell a checked case from
an unchecked one.

**Avoid `MainActor.assumeIsolated` in `deinit`** — it `fatalError`s when the
object is released off-main, which is exactly when a deinit is hardest to
predict. See [[boundedcompletion-mainactor-trap]] for the shape.

## Two things that ripple further than they look

**Making a PROTOCOL `Sendable` reaches every conformer**, including test mocks.
Budget for the conformers before changing the protocol, not after the build
breaks.

**Shared types cascade, so map them first.** Concurrency diagnostics are not
independent: fixing one shared type clears several sites at once, and fixing
sites individually does the same work repeatedly. The retired A.5 plan found 31
warnings that collapsed to a handful of root types — `AccountDetails`,
`AccountsManager`, `TPPUserAccountProvider`. Enumerate the shared types in the
diagnostic set before writing any fix.

A corollary that plan stated and is worth keeping: **do not blindly `@unchecked`
a large shared type.** Check its mutable state first. A type that is big enough
to be tempting is big enough to hide a real race.

## Measuring

Under `complete` + language mode 6.0 the count is structurally zero — the build
fails otherwise. If a measurement is ever needed against a looser setting, take
it from a CI build log rather than a local `xcodebuild` override: a *global*
`SWIFT_STRICT_CONCURRENCY` override also overrides the SPM packages' own v6
mode and re-flags already-`Sendable` package types, over-counting. Per-target
settings only.
