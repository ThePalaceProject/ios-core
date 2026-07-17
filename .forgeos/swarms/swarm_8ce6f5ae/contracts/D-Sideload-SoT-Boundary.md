# Contract D — Formalize the SideloadedBookRegistry SoT Boundary (WS4)

**Module:** MyBooks/Sideload
**Risk:** critical_path (a second owner of book state; patron content persistence)
**Depends on:** A (doctrine declares the scoped-SoT rule)

## Verified starting facts
- `SideloadedBookRegistry` (`Palace/MyBooks/Sideload/SideloadedBookRegistry.swift:45`)
  — `final class SideloadedBookRegistry: @unchecked Sendable` — owns side-loaded
  book state + manifest persistence, independent of `TPPBookRegistry`.
- Sibling: `Palace/MyBooks/Sideload/SideloadedBookManager.swift`.
- There is already a `PalaceTests/Contract/SideloadImportContractTests.swift`
  + snapshot dir — the import path is partially pinned.

## Realistic one-day scope (formalize + probe, do NOT unify)
Unifying the two registries behind one storage is a large, risky change (touches
`TPPBookRegistry` — owned by Contract C — and the download path — Contract E).
**Do the "OR" branch of WS4: document + probe-guard the second owner behind one
interface.**

1. **Introduce (or confirm) a single protocol seam** both registries can be viewed
   through for the read side — e.g. a `BookStateReading` protocol exposing
   `state(for:)` — so callers depend on the seam, not the concrete class.
   If such a seam already exists, document that `SideloadedBookRegistry` is the
   authorized second conformer; if not, add a minimal protocol and conform
   `SideloadedBookRegistry` to it (no behavior change).
2. **Add a header doc block** on `SideloadedBookRegistry.swift` stating: it is the
   authorized second book-state owner, scoped to side-loaded (non-loan) content;
   it MUST NOT be used for loaned books; loaned-book state stays in
   `TPPBookRegistry`. Reference the doctrine (Contract A).
3. **Probe-guard**: a Contract-F fact/probe asserting exactly TWO book-state
   owners exist (`TPPBookRegistry`, `SideloadedBookRegistry`) so a THIRD owner
   trips CI. Provide the grep the probe uses (below).

## Scope (exact files)
- `Palace/MyBooks/Sideload/SideloadedBookRegistry.swift` (doc header + protocol
  conformance if a read seam is added)
- (optional NEW, only if no read seam exists) a small protocol file, registered
  via `scripts/pbxproj_add_swift.rb`
- Extend `PalaceTests/Contract/SideloadImportContractTests.swift` OR add a new
  boundary test asserting sideloaded state never leaks into `TPPBookRegistry`.

## Off-limits
- `Palace/Book/Models/TPPBookRegistry.swift` / `TPPBookState.swift` (Contract C)
- `Palace/MyBooks/MyBooksDownloadCenter.swift`, `BorrowOperation.swift`,
  `BookReturnService.swift`, `DownloadStart*.swift` (Contract E)
- Do NOT attempt to unify the two registries.

## What public types change
- New (or documented-existing) read-seam protocol; `SideloadedBookRegistry` gains
  a conformance + doc header. No method removals.

## Test contracts
- Boundary test: importing a sideloaded book updates `SideloadedBookRegistry` and
  does NOT call `TPPBookRegistry.setState` (spy the loan registry; assert 0 calls).
- Existing `SideloadImportContractTests` snapshot stays green (no contract drift).

## Verification criteria (Phase 4.5)
```bash
# AC1: SideloadedBookRegistry documents its authorized-second-owner scope
grep -Eiq 'second (book-?state )?owner|side-?loaded|scoped to' Palace/MyBooks/Sideload/SideloadedBookRegistry.swift

# AC2: exactly two book-state owners exist (no third crept in)
test "$(grep -rlE 'class (TPPBookRegistry|SideloadedBookRegistry)' Palace --include='*.swift' | wc -l | tr -d ' ')" = "2"

# AC3: a boundary/contract test guards the seam
grep -Rq 'SideloadedBookRegistry' PalaceTests/Contract/

# AC4: existing sideload import snapshot untouched (no unintended contract drift)
test -d PalaceTests/Contract/__Snapshots__/SideloadImportContractTests
```
