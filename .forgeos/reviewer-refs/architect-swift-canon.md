# Architect reviewer — Swift canon

A reference lens for evaluating structural changes in this codebase. **Not a checklist.** Consult when a changeset introduces or modifies an abstraction, type hierarchy, dependency edge, concurrency model, or protocol surface — i.e., when "is this the right shape?" is a real question.

Skip when the change is mechanical (renames, formatting, dependency bumps, single-call-site bugfixes). The wall-failures catalog (`.forgeos/wall-failures/`) is the empirical complement to this doc — use both: this for *what good Swift architecture looks like*, that for *what we've shipped that broke*.

---

## How to use this doc during review

1. Read the diff first. Form your own opinion about whether the structure fits.
2. If something feels off but you can't name it, scan the relevant section here (POP, SOLID-in-Swift, GoF translation, smells).
3. If a section gives you a vocabulary for the concern, cite it in the finding (`see architect-swift-canon §SOLID/DIP`) so the author can read the same lens.
4. If nothing here fits but a concern is real, write the finding anyway. The canon is a starting set; gaps get filled as we encounter them.

Do NOT pattern-match findings to entries here. Approval still requires a real reason; rejection still requires a concrete failure mode.

---

## §1 — Swift-native architecture defaults

These are the idioms the codebase already leans on. Deviation needs justification in the commit body.

### Protocol-Oriented Programming (POP) over class inheritance
- **Default to protocols + structs + composition.** Reach for class inheritance only when reference identity, shared mutable state, or Objective-C interop demands it.
- **Protocols define behavior; structs implement; extensions add default behavior.** A new `class Foo` in production code that could be a `struct Foo: FooProtocol` is a red flag — flag it unless reference identity is *actually* required (e.g. it owns a `URLSession`, is the target of a Combine `@Published`, or bridges to UIKit).
- **Anti-pattern:** "abstract base class" with template-method overrides. In Swift, that's a protocol with a default implementation extension, not a class with `open` methods.

### Value semantics for state, reference semantics for identity
- **State (models, view state, configuration, results) → struct/enum.** Copies are cheap; equality is structural; concurrency is safer.
- **Identity (services, coordinators, stores, session managers) → class.** Reference semantics for things that *are* a thing in the world (a network session, a download in flight, a persistent registry).
- **Mixed responsibility is the smell.** A "model" that owns a `URLSession` is two things. Split it.

### Composition over inheritance — and over conditionals
- Three concrete types implementing a protocol > one type with an enum switch over modes.
- Polymorphism via protocol dispatch is more testable than enum-driven `switch self` (each conformance gets its own tests; no exhaustive-switch pyramid).
- **Counter:** for closed sets where every case must be handled (state machines, error families), enums *with* exhaustive switches are the right call — the compiler enforces completeness. The smell is enums + open-ended `if case` checks scattered across the codebase. See [Palace's `.accountNotFound` round-trip lesson](../wall-failures/) for the canonical failure.

### Structured concurrency over GCD + closures
- New code uses `async`/`await`, `Task`, `actor`, `AsyncSequence`. Not `DispatchQueue.global().async { … completion(result) }`.
- **`@MainActor` on view models is the contract** that says "all my published state mutates on main." Adding background work via `Task.detached` inside a `@MainActor` type needs justification.
- **Actors are not "thread-safe classes."** They serialize access to their state, but `await`-suspension reopens the door to interleaving. If a critical section spans multiple `await`s, the actor isn't protecting you the way you think it is.
- **Continuation patterns:** wrapping a callback-based API in `withCheckedContinuation` requires a once-guard. The 3.2.0 LCPStreamingPlayer crash (`lcp_player_continuation_misuse_2026_05_26`) was exactly this — double-resume from a callback that fired twice under stress.

### Errors are typed; failures are explicit
- `throws` for recoverable failures the caller can handle. `Result<T, E>` when ownership of the failure crosses an async boundary or the caller wants to inspect-then-decide.
- **`fatalError()` is a contract assertion**, not error handling. Use only for "this branch is unreachable; if we hit it, the world is broken."
- **`try!` and `as!` in production code are findings.** Test code may have them for fixture brevity, but flag them if they leak into prod paths.
- **Force-unwrapping (`!`) is forbidden** per project rule. The "we know this is non-nil here" rationale is what `guard let … else { assertionFailure(); return … }` exists for.

---

## §2 — SOLID through a Swift lens

SOLID was written for class-heavy OO. The principles still apply, but Swift's mechanisms differ.

### S — Single Responsibility
- A type's responsibilities are what would *cause it to change*. If two unrelated bug categories both land in the same file, it has two responsibilities.
- Palace red flag: ViewModels that own (a) UI state, (b) business logic, (c) persistence calls. The reducer/store split exists to break this — see `Palace/AppInfrastructure/Store.swift`. Flag VMs that bypass it.

### O — Open/Closed
- In Swift, openness comes from protocols (new conformances) and generic constraints, not subclassing.
- Adding a `case` to an existing enum is *not* a violation when the enum is internal — the compiler shows you every consumer. It IS a violation when the enum is part of a public module surface (the contract is "exhaustive switch is safe"); new cases break callers.
- **Critical:** before adding a case to an enum that's switched in N places, verify with the architect lens that all N switches still produce correct behavior. PR #1018 arch3 ("dishonest migration — classifier called but outcome only logged") was a downstream consequence of this exact failure mode.

### L — Liskov Substitution
- For protocols: every conformance must satisfy the same behavioral contract as the protocol promises. A `MockNetworkExecutor` that returns synthetic data is fine; one that *silently no-ops a request* and returns success is a Liskov violation — it lies about what the protocol means.
- Test doubles ARE Liskov-evaluable. Spies that record but don't behave (e.g., a "download spy" that never fires its completion handler when the real one would) are why "fake wiring tests" pass in CI but fail in production. See `.forgeos/wall-failures/2026-05-28-cs847892e8-arch1.md`.

### I — Interface Segregation
- Big protocols force consumers to depend on methods they don't use AND force test doubles to stub everything.
- Swift makes segregation cheap: `protocol Borrowing { … }`, `protocol Returning { … }`, then `class BookService: Borrowing, Returning { … }`. Consumers depend on what they use.
- **The "god protocol" smell** is a protocol with 15+ requirements that every implementer must stub. If a mock has more `// no-op` methods than real ones, the protocol is wrong.

### D — Dependency Inversion
- High-level policy doesn't import low-level details. Both depend on abstractions.
- In Palace: `BookReturnService` depends on `BookRegistryProtocol`, not on `TPPBookRegistry.shared`. The shared singleton is wired in at the composition root (`AppContainer.production()`), not reached through globally.
- **Singleton reads in new code are the canonical DIP violation here.** The codebase is actively reducing `.shared` (732 → 344 over the modernization sprint). New `.shared` reads need a *very* good reason or they fail review.

---

## §3 — GoF translation table

GoF in 2026 Swift mostly maps to language features. **Suggesting "use the Strategy pattern" when the right answer is "take a closure parameter" is an architect anti-pattern.** This table prevents that.

| GoF pattern | Swift idiom | When the literal pattern still applies |
|---|---|---|
| **Strategy** | `(Input) -> Output` closure parameter, or a protocol with one method | Multiple strategies share state or need named identity (e.g. for logging/metrics). Otherwise: closure. |
| **Observer** | `@Published` + Combine, or `AsyncSequence`, or delegate protocol | When you need fan-out with explicit subscriber lifecycle and the receiver isn't reactive. Otherwise: Combine. |
| **Factory Method / Abstract Factory** | Static `make(…)` on the type, or a protocol with a `make` method, or just an initializer | When the construction logic is non-trivial AND swappable (test doubles for the factory itself). Otherwise: `init` is enough. |
| **Singleton** | **Don't.** Use `AppContainer` composition. | Only for OS-level resources with truly one instance per process (e.g. `FileManager.default`). Never for project state. |
| **Adapter** | Extension that adds the missing protocol conformance, or a wrapper struct | Always — but in Swift it's usually a 10-line extension, not a class. |
| **Decorator** | Protocol wrapper struct that holds the inner instance and forwards calls | When you need behavior layering at runtime (e.g. retry-wrapping a network executor). The pattern survives. |
| **Facade** | A focused service or coordinator type | When a subsystem has 5+ entry points and consumers only need 2. The pattern survives. |
| **Command** | A struct conforming to a `Command` protocol with `execute()`, or an enum of actions + a reducer | The reducer form is what we use (see `BorrowReducer`, `HoldsReducer`). The pattern *strongly* survives — it's TCA-shaped. |
| **State** | Enum with associated values + reducer dispatch | The reducer form is the Swift-idiomatic translation. Avoid "state classes with polymorphic `handle()` methods" — that's Java. |
| **Iterator** | `Sequence`/`IteratorProtocol`, or `AsyncSequence` | Always — but conform to the standard library protocols, don't invent your own. |
| **Visitor** | Enum + `switch` (compiler enforces exhaustiveness) | When the type hierarchy is open and operations are closed — rare in Swift. Usually you want a protocol with an operation method instead. |
| **Template Method** | Protocol with default implementations in an extension | Always. The "abstract class with `open` methods to override" form is an anti-translation. |
| **Chain of Responsibility** | Array of handlers + `first(where:)`, or a reducer with case-priority ordering | When the handlers are independent and order is data-driven. Otherwise: just a switch. |
| **Mediator** | Coordinator/router type | When N components need to talk and you want to avoid N² coupling. Survives as the Coordinator pattern in iOS. |
| **Memento** | Codable snapshot struct | Always. The pattern is invisible because Swift makes it free. |
| **Composite** | Recursive enum, or protocol + array conformance | When the recursion is genuine (UI trees, AST nodes). Skip for shallow groupings. |
| **Flyweight** | Value types + ARC | Invisible in Swift — struct copies are cheap, ARC handles shared reference state. Don't engineer it manually. |
| **Bridge** | Protocol + concrete implementer split | The most common GoF pattern in Swift; we just don't call it that. |
| **Builder** | Method chaining on a struct that returns `Self` (consuming) | When construction has 5+ optional parameters AND order matters. Otherwise: an init with default values is clearer. |
| **Prototype** | `Copyable` (Swift 5.9+) or `init(copying: Self)` | Rare — usually value semantics give you this for free. |
| **Interpreter** | Enum + recursive evaluator | When you really do have a small DSL to evaluate. Rare. |
| **Proxy** | Wrapper that forwards selectively, or `@dynamicMemberLookup` | When you need access control, lazy loading, or remote-procedure shape at the type boundary. |

### Anti-translation rule
**If suggesting a GoF pattern would require introducing a class hierarchy, fight the suggestion.** Ask: "Can a protocol + struct + closure express this in fewer lines?" If yes, that's the better recommendation.

---

## §4 — Code smells worth naming

These are the smells the canon recognizes. If you see one, name it in the finding so the author has a shared vocabulary.

- **Primitive obsession** — passing `String` book IDs everywhere instead of a `BookID` newtype. Compiler can't catch swaps; tests can't fail meaningfully. In Swift, `struct BookID: Hashable { let raw: String }` is free.
- **Feature envy** — a method that reaches into another type's state more than its own. Often a sign the method belongs on the other type, or the boundary is wrong.
- **Shotgun surgery** — one logical change requires edits to N unrelated files. The abstraction is missing or wrong.
- **Divergent change** — one type changes for N unrelated reasons. SRP violation.
- **Speculative generality** — a protocol with one conformer, or a parameter that's never anything but the default. Delete it.
- **Long parameter list** — 5+ params is a struct in disguise. Bundle them.
- **Data clumps** — the same 3 params travel together everywhere. Make them a type.
- **Refused bequest** — a class inherits and overrides nearly everything to no-op. The inheritance is wrong; use composition.
- **God object** — one type that knows everything. Common in iOS in the form of "ViewController owns all the logic." Reducers + services exist to fix this.
- **Temporal coupling** — method A must be called before method B, but the type doesn't enforce it. Encode it in the type (state machine, builder, or two-phase init).
- **Boolean parameter trap** — `borrow(book, force: true)` reads worse than `borrow(book) { … } / forceBorrow(book) { … }`. Two methods or an enum, not a bool.
- **Stringly typed APIs** — `Notification.Name("BookDidBorrow")` everywhere. Wrap in a typed namespace.

### Smells specific to this codebase
- **`.shared` reads outside the composition root.** See [singleton audit](`memory/singleton_audit_2026_04_24.md`).
- **GCD + closure hybrids in new code.** Use `async`/`await`.
- **ViewModels that import the SwiftUI environment for non-UI reasons** (e.g., to reach navigation state). Inject a coordinator instead.
- **Direct `UserDefaults.standard` reads outside `UserDefaultsService`.** Wrap it.
- **Test files named `<SUT>Tests.swift` that never instantiate `<SUT>(…)`.** Fake-wiring tests. See `scripts/check-test-name-vs-body.py` and PR #1018 qa2/qa3.

---

## §5 — Wall-failure cross-reference

The empirically-grounded catalog of what we've actually shipped that broke. When the canon's theory and the wall-failures' practice agree, the finding is strong. When they disagree, **trust the wall-failures** — they're real incidents from this codebase.

Pin these:
- `2026-05-27-pr1018-arch1.md` — fake-test-instantiation (canon §SRP / §LSP)
- `2026-05-27-pr1018-arch3.md` — dishonest migration (canon §OCP / §discipline)
- `2026-05-28-cs847892e8-arch1.md` — fake wiring test (canon §LSP for test doubles)
- `2026-05-28-cs9a267b63-arch1.md` — repeat of arch1 — recurrence is the signal that the **structural** fix matters more than the **finding** itself

If a current changeset rhymes with one of these, cite the wall-failure entry in your finding. Recurrence prevention is the whole point of the catalog.

---

## §6 — Curated reading (Swift/iOS)

Not exhaustive. These are the sources whose ideas, when invoked, sharpen review without inviting cargo-cult.

**Primary (Swift-native):**
- *Swift API Design Guidelines* (Apple) — the codebase already follows these; deviations should be flagged.
- *swift-evolution* proposals for the features you're reviewing (search by feature name; the rationale section is the canon).
- *objc.io* — *Advanced Swift* (Eidhof, Kugler, Wouter) — value types, generics, async semantics. *App Architecture* — coordinator/store/reducer patterns in iOS specifically.
- John Sundell — *swiftbysundell.com* — strongest single source for idiomatic refactor recipes.
- Point-Free — episodes on dependencies, navigation, reducers. TCA is heavyweight for our use case but the principles transfer.

**Secondary (translate, don't transplant):**
- *Design Patterns: Elements of Reusable Object-Oriented Software* (GoF) — read for vocabulary; use the §3 translation table to map.
- *Refactoring* (Fowler) — smell catalog and refactoring recipes. The Swift translation is usually shorter; the *names* of the smells are the value.
- *Clean Code* (Martin) — applies in spirit. Some specific rules (e.g. "functions should do one thing") translate; others (class-heavy DI patterns) don't.
- *Working Effectively with Legacy Code* (Feathers) — seam-finding, test-around-untested-code techniques. Most relevant for the modernization sprint.
- *xUnit Test Patterns* (Meszaros) — belongs to the QA reviewer canon, but the test-double taxonomy is useful for architect findings on test doubles too.

**Avoid:**
- Java/C# pattern books transplanted directly.
- "Clean architecture in iOS" tutorials that recreate three-layer enterprise architectures — Swift's type system flattens most of those layers into free functions and protocols.

---

## §7 — When the canon and the diff disagree

Sometimes a change deliberately breaks an idiom because the local constraints justify it. Examples that have happened:
- Using a class instead of a struct because UIKit demands `NSObject` conformance.
- A `.shared` read because the call site is a category extension on a UIKit type where DI isn't available.
- A GCD+closure pattern because the API being wrapped is itself callback-based and async-await bridging adds more risk than benefit.

When you see this, the architect's job is to confirm the commit body says *why*. If it does, that's a `pass` observation noting the deviation is justified. If it doesn't, that's a `warning` — not a block, but the rationale needs to be captured before this becomes a precedent.

---

*Maintenance: when a wall-failure entry's "permanent fix" updates this doc, add the change and link the entry. When a Swift evolution proposal lands that changes idiom (e.g. typed throws, parameter packs), update §1. The canon is alive; stale advice is worse than no advice.*
