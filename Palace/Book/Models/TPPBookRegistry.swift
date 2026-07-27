import Foundation
import Combine
import UIKit
import PalaceLogging
import PalaceBookModel

/// `Sendable` (Swift 6 `complete`): the registry is passed to, and captured by,
/// closures/`Task`s across ~60 consumer files (MyBooks, CatalogUI, Reader2,
/// Audiobooks, CarPlay, …). Making the abstraction Sendable is what lets those
/// consumers hold and hop it without each capture site tripping a
/// "non-Sendable `TPPBookRegistryProvider`" diagnostic. Both conformers satisfy
/// it: the production `TPPBookRegistry` is `@unchecked Sendable` (its mutable
/// `_state` is lock-guarded, `syncState` self-synchronised, everything else an
/// immutable `let`); `TPPBookRegistryMock` is `@unchecked Sendable` for
/// single-threaded test use (documented at its declaration).
protocol TPPBookRegistryProvider: Sendable {
    var registryPublisher: AnyPublisher<[String: TPPBookRegistryRecord], Never> { get }
    var bookStatePublisher: AnyPublisher<(String, TPPBookState), Never> { get }
    var syncStatePublisher: AnyPublisher<Bool, Never> { get }
    /// Registry LIFECYCLE stream (unloaded → loading → loaded → syncing → synced).
    /// Distinct from `bookStatePublisher`: it fires on load/sync transitions even
    /// when NO per-book state changes — so lifecycle-driven consumers (launch
    /// download reconciliation, post-sign-in sync, the holds badge) don't hang on
    /// a fresh empty-registry sign-in that emits zero per-book events.
    var registryStatePublisher: AnyPublisher<TPPBookRegistry.RegistryState, Never> { get }
    /// Fires when the reservations set changes in a way that leaves book state
    /// untouched (a background sync flipping a hold reserved→ready keeps the book
    /// at `.holding`), so the holds badge can refresh. Hand-fired via
    /// `notifyHoldsChanged()` from the holds/reservation flows.
    var holdsDidChangePublisher: AnyPublisher<Void, Never> { get }
    func notifyHoldsChanged()
    var heldBooks: [TPPBook] { get }
    var myBooks: [TPPBook] { get }
    var isSyncing: Bool { get }
    var state: TPPBookRegistry.RegistryState { get }
    var registryState: TPPBookRegistry.RegistryState { get }

    func sync(completion: ((_ errorDocument: [AnyHashable: Any]?, _ newBooks: Bool) -> Void)?)
    func sync()
    func load()
    func updatedBookMetadata(_ book: TPPBook) -> TPPBook?
    func coverImage(for book: TPPBook, handler: @escaping (_ image: UIImage?) -> Void)
    func setProcessing(_ processing: Bool, for bookIdentifier: String)
    func processing(forIdentifier bookIdentifier: String) -> Bool
    func state(for bookIdentifier: String?) -> TPPBookState
    func readiumBookmarks(forIdentifier identifier: String) -> [TPPReadiumBookmark]
    func setLocation(_ location: TPPBookLocation?, forIdentifier identifier: String)
    func location(forIdentifier identifier: String) -> TPPBookLocation?
    func add(_ bookmark: TPPReadiumBookmark, forIdentifier identifier: String)
    func delete(_ bookmark: TPPReadiumBookmark, forIdentifier identifier: String)
    func replace(_ oldBookmark: TPPReadiumBookmark, with newBookmark: TPPReadiumBookmark, forIdentifier identifier: String)
    func genericBookmarksForIdentifier(_ bookIdentifier: String) -> [TPPBookLocation]
    func addOrReplaceGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String)
    func addGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String)
    func deleteGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String)
    func replaceGenericBookmark(_ oldLocation: TPPBookLocation, with newLocation: TPPBookLocation, forIdentifier: String)
    func addBook(_ book: TPPBook, location: TPPBookLocation?, state: TPPBookState, fulfillmentId: String?, readiumBookmarks: [TPPReadiumBookmark]?, genericBookmarks: [TPPBookLocation]?)
    func removeBook(forIdentifier bookIdentifier: String)
    func updateAndRemoveBook(_ book: TPPBook)
    func setState(_ state: TPPBookState, for bookIdentifier: String)
    func book(forIdentifier bookIdentifier: String?) -> TPPBook?
    func fulfillmentId(forIdentifier bookIdentifier: String?) -> String?
    func setFulfillmentId(_ fulfillmentId: String, for bookIdentifier: String)
    func with(account: String, perform block: (_ registry: TPPBookRegistry) -> Void)

    // Image loading methods
    func cachedThumbnailImage(for book: TPPBook) -> UIImage?
    func thumbnailImage(for book: TPPBook?, handler: @escaping (_ image: UIImage?) -> Void)
    func thumbnailImages(forBooks books: Set<TPPBook>, handler: @escaping (_ bookIdentifiersToImages: [String: UIImage]) -> Void)
}

// TPPBookRegistryData and TPPBookRegistryKey defined in TPPBookRegistryRecord.swift

/// Sendable holder for the `AnyCancellable` of a self-cancelling `@Sendable`
/// Combine subscription (the one-shot `waitForLoadThenRunSync` sink). The
/// subscription's own closure clears the box on first match, so the closure must
/// reference a stable box rather than capture-and-mutate a `var` (which the
/// `targeted` checker rejects as "mutated after capture by sendable closure").
/// The cancellable is written exactly once, right after `sink` returns, and set
/// to `nil` from inside the sink — write-once-then-clear confinement on `.main`,
/// not a race waiver.
private final class CancellableBox: @unchecked Sendable {
    var cancellable: AnyCancellable?
}

/// Sendable carrier for the sync-completion closure captured by the `@Sendable`
/// state-change observer block in `waitForLoadThenRunSync`. The closure is a
/// non-Sendable `(([AnyHashable: Any]?, Bool) -> Void)?`; wrapping it lets the
/// observer capture this box instead of the raw value, clearing the
/// `complete`-mode "capture … in a '@Sendable' closure" diagnostic without
/// rippling `@Sendable` onto `sync`/`runSync`'s public completion parameter.
///
/// `@unchecked Sendable` invariant: `completion` is stored once at construction
/// and only ever READ, then invoked on the main queue (where the observer fires
/// and `runSync` runs). No cross-thread mutation. Mirrors `SyncCallbacks` in
/// `BookRegistrySync`.
private final class SyncCompletionBox: @unchecked Sendable {
    let completion: ((_ errorDocument: [AnyHashable: Any]?, _ newBooks: Bool) -> Void)?
    init(_ completion: ((_ errorDocument: [AnyHashable: Any]?, _ newBooks: Bool) -> Void)?) {
        self.completion = completion
    }
}

/// A `Bool` that auto-resets to `false` after `delay` seconds, firing `onChange`
/// on every edge. Used by `TPPBookRegistry` to post `TPPSyncBegan`/`TPPSyncEnded`.
///
/// `@unchecked Sendable` invariant: `_value` and `resetTask` are the only mutable
/// state and BOTH are guarded by `lock`. The setter's edge callback (`onChange`)
/// and its reset scheduling run OUTSIDE the lock (only reading a snapshotted flag
/// captured inside it) so a re-entrant `value = false` from the reset work item —
/// which runs on a fresh main-queue stack after the lock has been released — takes
/// the lock cleanly rather than deadlocking. `onChange` is invoked with the SAME
/// old!=new edge semantics as the former `willSet`, preserving notification
/// ordering; the reset scheduling matches the former `didSet` exactly.
/// Being self-synchronised means `TPPBookRegistry` does NOT need its own
/// `stateLock` to guard `syncState` — this type owns its concurrency.
private final class BoolWithDelay: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let switchBackDelay: Double
    private var resetTask: DispatchWorkItem?
    private let onChange: ((_ value: Bool) -> Void)?
    private var _value: Bool = false

    init(delay: Double = 5, onChange: ((_ value: Bool) -> Void)? = nil) {
        self.switchBackDelay = delay
        self.onChange = onChange
    }

    var value: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            let didChange = _value != newValue
            _value = newValue
            let task: DispatchWorkItem?
            let previousTask = resetTask
            if newValue {
                let work = DispatchWorkItem { [weak self] in
                    self?.value = false
                }
                resetTask = work
                task = work
            } else {
                resetTask = nil
                task = nil
            }
            lock.unlock()

            // Fire the edge callback + (re)schedule the reset OUTSIDE the lock,
            // preserving the former willSet(edge)/didSet(schedule) ordering and
            // side effects without holding the lock across `onChange` or the
            // async dispatch.
            if didChange {
                onChange?(newValue)
            }
            previousTask?.cancel()
            if let task {
                DispatchQueue.main.asyncAfter(deadline: .now() + switchBackDelay, execute: task)
            }
        }
    }
}

/// Thin facade over three focused collaborators, completing the decomposition
/// started in commit `5a1ae2a42`:
///   - `BookRegistryStore` owns the in-memory record dictionary + Combine publishers.
///   - `BookRegistrySync` owns disk load, server sync, save, and orphan recovery.
///   - `BookmarkManager` owns bookmark + reading-location CRUD.
///
/// The facade keeps:
///   - the `RegistryState` enum + public `state` getter
///   - the `BoolWithDelay` that posts `TPPSyncBegan` / `TPPSyncEnded`
///   - the `TPPCurrentAccountDidChange` observer
///   - the `TPPBookRegistrySyncing` / `TPPBookRegistryProvider` conformance
///   - the shared singleton + account-scoped temporary-instance factory
///
/// Every mutation captures `accountsManager.currentAccount?.uuid` synchronously
/// at dispatch time and passes it through to the collaborators. A mutation
/// queued on account A executing after the user has switched to account B
/// still persists to A's registry file — otherwise cross-account
/// contamination produces the "books downloaded, but opens to 401 re-auth
/// loop" symptom captured in PP-4129.
///
/// `@unchecked Sendable` (Swift 6 `complete`): the facade's only mutable stored
/// state is `_state` (guarded by `stateLock`) and `syncState` (a self-synchronised
/// `BoolWithDelay`). Every other stored property is an immutable `let`: the three
/// collaborators (`store` — itself `@unchecked Sendable` via its `syncQueue`;
/// `syncEngine` — `@unchecked Sendable`; `bookmarks` — a `BookmarkManager`
/// whose every stored property is an immutable `let` that routes all mutation
/// through `store`'s barriers, thread-safe though not itself annotated
/// `Sendable`), the external deps
/// (`accountsManager`, `imageLoader`), and `syncStateSubject`. The one remaining
/// `var accountDidChangeCancellable` is written once during `init`'s
/// `setupAccountDidChangeObserver()` (on the constructing thread, before the
/// instance escapes) and only read/torn-down thereafter, so it carries no
/// cross-thread write race. This is a documented invariant, not a bare waiver.
@objcMembers
class TPPBookRegistry: NSObject, TPPBookRegistrySyncing, @unchecked Sendable {
    static let syncFailureErrorDocumentKey = "TPPBookRegistrySyncFailureErrorDocument"

    @objc enum RegistryState: Int, Sendable {
        case unloaded, loading, loaded, syncing, synced
    }

    // MARK: - Collaborators

    private let store: BookRegistryStore
    private let syncEngine: BookRegistrySync
    private let bookmarks: BookmarkManager

    // MARK: - External dependencies

    private let accountsManager: AccountsManager
    /// Image-loading umbrella. Required — must be threaded through from the
    /// `AppContainer` graph (or a test mock). NEVER take a default that
    /// resolves via `AppContainer.production()` here — TPPBookRegistry is
    /// constructed inside `_cached`'s own dispatch_once, so a default arg
    /// would re-enter the once and SIGTRAP (the cycle that motivated Phase
    /// 6.6's singleton kill).
    private let imageLoader: ImageLoading

    private var accountDidChangeCancellable: AnyCancellable?

    private func setupAccountDidChangeObserver() {
        accountDidChangeCancellable = NotificationCenter.default.publisher(for: .TPPCurrentAccountDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // Invalidate UI-visible state synchronously BEFORE kicking off the
                // async load. Without this, MyBooks keeps showing the previous
                // account's registry for the duration of the load — the user can
                // tap a book that belongs to the wrong account and trigger
                // mutations against a mismatched auth context (PP-4129).
                //
                // CurrentValueSubject is thread-safe; emitting the empty dictionary
                // on the main thread is the lightest-weight way to force UI readers
                // (`heldBooks`, `myBooks`, `allBooks`, `state(for:)` derived from
                // the subject) to see an empty list until the new load completes.
                self.store.registrySubject.send([:])
                self.state = .loading
                // Chain sync() off load's completion so it never runs against an
                // empty in-memory store. Previously this used an `asyncAfter(+1s)`
                // heuristic, which raced on slow disks: if load's disk I/O hadn't
                // finished when sync() fired, sync would rebuild the registry from
                // feed-only data and save it to disk, wiping every previously-
                // downloaded book's state back to .downloadNeeded.
                self.load { [weak self] in
                    self?.sync()
                }
            }
    }

    // MARK: - State + publishers

    /// Guards every read and write of `_state`.
    ///
    /// `@unchecked Sendable` invariant (the crux of this type's thread-safety):
    ///   `_state` is written from BookRegistrySync's background `Task`/main-thread
    ///   `setState:` callbacks (`self?.state = newState`), from `reset(_:)`, and
    ///   from the account-change observer; it is read cross-thread by the `sync()`
    ///   guard (`state == .unloaded`), by `registryState`, and by the
    ///   `TPPBookRegistryProvider.state` accessor. Serialising all `_state` access
    ///   through this lock, together with `syncState` being self-synchronised
    ///   (`BoolWithDelay` owns its own lock), is what lets the facade be
    ///   `@unchecked Sendable`.
    ///
    ///   The lock is held ONLY for the trivial get/set of `_state`; no store call,
    ///   disk I/O, notification post, or `syncState` access happens inside it. The
    ///   `syncState.value` derivation and the `NotificationCenter.post` both run
    ///   AFTER the lock is released, preserving the former `didSet` ordering
    ///   (`_state` write → derive syncState → async-post) while keeping the
    ///   critical section incapable of deadlocking against
    ///   `BookRegistryStore.syncQueue` or `BoolWithDelay.lock`.
    private let stateLock = NSLock()

    private var _state: RegistryState = .unloaded

    /// Transition ordering is IDENTICAL to the pre-lock `didSet`: write `_state`,
    /// derive `syncState.value`, then emit the lifecycle signal — all preserved,
    /// only the `_state` storage is now serialised.
    private(set) var state: RegistryState {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _state }
        set {
            stateLock.lock()
            _state = newValue
            stateLock.unlock()
            // Same side effects the former `didSet` performed, in the same order,
            // now outside the lock. `syncState` is self-synchronised so it needs
            // no help from `stateLock`. The former async `NotificationCenter.post`
            // of `.TPPBookRegistryStateDidChange` is replaced by feeding the
            // Combine `registryStateSubject` (its publisher delivers on `.main`),
            // completing the dual-write kill (swarm_8ce6f5ae WS3).
            syncState.value = (newValue == .syncing)
            registryStateSubject.send(newValue)
        }
    }

    private let syncState = BoolWithDelay { value in
        if value {
            NotificationCenter.default.post(name: .TPPSyncBegan, object: nil, userInfo: nil)
        } else {
            NotificationCenter.default.post(name: .TPPSyncEnded, object: nil, userInfo: nil)
        }
    }

    private(set) var isSyncing: Bool {
        get { syncState.value }
        set { }
    }

    private let syncStateSubject = CurrentValueSubject<Bool, Never>(false)

    var syncStatePublisher: AnyPublisher<Bool, Never> {
        syncStateSubject.eraseToAnyPublisher()
    }

    /// Lifecycle stream, fed from the `state` setter on every transition.
    /// `CurrentValueSubject` (not `Passthrough`) so a late subscriber immediately
    /// sees the current lifecycle state plus every future transition — the
    /// level-triggered semantics the deleted notification's observers relied on
    /// (they re-read `self.state` on each post). Seeded `.unloaded` to match the
    /// initial `_state`.
    private let registryStateSubject = CurrentValueSubject<RegistryState, Never>(.unloaded)

    var registryStatePublisher: AnyPublisher<RegistryState, Never> {
        registryStateSubject
            .receive(on: RunLoop.main)
            .eraseToAnyPublisher()
    }

    /// Hand-fired holds-changed signal (see protocol doc). `PassthroughSubject`
    /// because there is no meaningful "current" holds-change value to replay.
    private let holdsDidChangeSubject = PassthroughSubject<Void, Never>()

    var holdsDidChangePublisher: AnyPublisher<Void, Never> {
        holdsDidChangeSubject
            .receive(on: RunLoop.main)
            .eraseToAnyPublisher()
    }

    func notifyHoldsChanged() {
        holdsDidChangeSubject.send(())
    }

    // MARK: - Transition enforcement

    /// Invoked by `setState` when asked to perform a transition that is NOT in
    /// `TPPBookState.allowedTransitions`. The write still happens (state is never
    /// dropped); this only reports the violation. Injectable so tests can observe
    /// the DEBUG path without tripping `assertionFailure` and crashing the suite.
    typealias IllegalTransitionHandler =
        @Sendable (_ from: TPPBookState, _ to: TPPBookState, _ bookIdentifier: String) -> Void

    static let defaultIllegalTransitionHandler: IllegalTransitionHandler = { from, to, bookIdentifier in
        let message = "🚫 Illegal book-state transition for '\(bookIdentifier)': "
            + "\(from.stringValue()) → \(to.stringValue()) — not in TPPBookState.allowedTransitions. "
            + "Applying anyway (state is never dropped)."
        #if DEBUG
        assertionFailure(message)
        #else
        Log.error(#file, message)
        #endif
    }

    private let onIllegalTransition: IllegalTransitionHandler

    var registryPublisher: AnyPublisher<[String: TPPBookRegistryRecord], Never> {
        store.registrySubject
            .receive(on: RunLoop.main)
            .eraseToAnyPublisher()
    }

    var bookStatePublisher: AnyPublisher<(String, TPPBookState), Never> {
        store.bookStateSubject
            .receive(on: RunLoop.main)
            .eraseToAnyPublisher()
    }

    // MARK: - Init

    /// Construct the app-scoped registry. `accountsManager` is the only
    /// external dependency the registry needs at init time — every other
    /// collaborator (download center, OPDS feed service) is lazily resolved
    /// via the AppContainer providers below.
    ///
    /// AppContainer is the sole production caller (see
    /// `AppContainer._cached`); pass the explicitly-constructed
    /// AccountsManager so we never re-enter `AppContainer.production()`'s
    /// dispatch_once during app launch (the failure mode that motivated
    /// killing the `static let shared` singleton in Phase 6.6).
    init(
        accountsManager: AccountsManager,
        imageLoader: ImageLoading,
        onIllegalTransition: @escaping IllegalTransitionHandler = TPPBookRegistry.defaultIllegalTransitionHandler
    ) {
        self.accountsManager = accountsManager
        self.imageLoader = imageLoader
        self.onIllegalTransition = onIllegalTransition
        let store = BookRegistryStore()
        let sync = BookRegistrySync(
            store: store,
            accountsManager: accountsManager,
            downloadCenterProvider: { AppContainer.production().downloadCenter },
            opdsFeedServiceProvider: { AppContainer.production().opdsFeedService },
            // Side-loaded books are exempt from loans-feed reconciliation.
            // Provider resolved lazily (same AppContainer-cycle avoidance).
            sideloadedIDsProvider: { AppContainer.production().sideloadedBookRegistry.identifiers }
        )
        self.store = store
        self.syncEngine = sync
        // The save / saveSync closures always persist to the account the CALLER
        // passes in — never `accountsManager.currentAccount` looked up at
        // closure-execution time. Every caller (facade mutation or bookmark
        // wrapper) captures currentAccount synchronously at the moment of
        // dispatch.
        self.bookmarks = BookmarkManager(
            store: store,
            save: { [weak sync] account in sync?.save(for: account) },
            saveSync: { [weak sync] account in sync?.saveSync(for: account) }
        )
        super.init()
        setupAccountDidChangeObserver()
    }

    /// Account-scoped temporary instance used by `with(account:perform:)` to
    /// run a block against a *different* registry file than the current one.
    /// Inherits `accountsManager` from the calling facade — no default arg, no
    /// AppContainer lookup, so the cycle that motivated 6.6 can't sneak back.
    fileprivate init(account: String, accountsManager: AccountsManager, imageLoader: ImageLoading) {
        self.accountsManager = accountsManager
        self.imageLoader = imageLoader
        self.onIllegalTransition = TPPBookRegistry.defaultIllegalTransitionHandler
        let store = BookRegistryStore()
        let sync = BookRegistrySync(
            store: store,
            accountsManager: accountsManager,
            downloadCenterProvider: { AppContainer.production().downloadCenter },
            opdsFeedServiceProvider: { AppContainer.production().opdsFeedService },
            // Side-loaded books are exempt from loans-feed reconciliation.
            // Provider resolved lazily (same AppContainer-cycle avoidance).
            sideloadedIDsProvider: { AppContainer.production().sideloadedBookRegistry.identifiers }
        )
        self.store = store
        self.syncEngine = sync
        self.bookmarks = BookmarkManager(
            store: store,
            save: { [weak sync] account in sync?.save(for: account) },
            saveSync: { [weak sync] account in sync?.saveSync(for: account) }
        )
        super.init()
        syncEngine.load(account: account) { [weak self] newState in self?.state = newState }
    }

    func with(account: String, perform block: (_ registry: TPPBookRegistry) -> Void) {
        block(TPPBookRegistry(account: account, accountsManager: accountsManager, imageLoader: imageLoader))
    }

    // MARK: - Load / sync / save / reset (delegate to BookRegistrySync)

    func registryUrl(for account: String) -> URL? {
        return syncEngine.registryUrl(for: account)
    }

    func load(account: String? = nil, completion: (() -> Void)? = nil) {
        syncEngine.load(account: account, setState: { [weak self] newState in
            self?.state = newState
        }, completion: completion)
    }

    func load() { load(account: nil, completion: nil) }

    func sync(completion: ((_ errorDocument: [AnyHashable: Any]?, _ newBooks: Bool) -> Void)? = nil) {
        // `BookRegistrySync.sync` bails when state is `.unloaded`/`.loading`
        // to protect against the feed-only reconciliation path overwriting
        // on-disk records — but post-sign-in (and any other caller hitting
        // a not-yet-loaded registry) legitimately wants a sync.
        //
        // Two races land us here in production for SAML re-auth:
        //   (a) state == .unloaded — sign-out cleared the in-memory store
        //       and nothing has triggered a re-load yet.
        //   (b) state == .loading — a load is already in flight; calling
        //       `load()` again returns its completion immediately via the
        //       duplicate-skip guard inside BookRegistrySync, so chaining
        //       sync off `load()`'s completion misses the in-flight load
        //       and runs sync against still-unloaded state.
        //
        // Both cases: subscribe to `registryStatePublisher` and run
        // sync once state reaches `.loaded`/`.synced`. Then kick off a
        // load (no-op if one is already in flight). Either path drives
        // the lifecycle publisher to the .loaded transition.
        if state == .unloaded || state == .loading {
            waitForLoadThenRunSync(completion: completion)
            if state == .unloaded {
                load()
            }
            return
        }
        runSync(completion: completion)
    }

    func sync() { sync(completion: nil) }

    /// Subscribes to `registryStatePublisher` and runs sync the first time state
    /// reaches `.loaded`/`.synced`. The subscription cancels itself on first match
    /// so it's a one-shot.
    ///
    /// This MUST key on the lifecycle publisher, not `bookStatePublisher`: a fresh
    /// empty-registry sign-in (SAML re-auth) loads zero books, so no per-book event
    /// is ever emitted — a `bookStatePublisher` subscriber would wait forever and
    /// the post-sign-in sync would never run.
    private func waitForLoadThenRunSync(completion: ((_ errorDocument: [AnyHashable: Any]?, _ newBooks: Bool) -> Void)?) {
        // Box `completion` (a non-Sendable function value) so the `@Sendable` sink
        // captures a Sendable carrier instead of the raw closure — otherwise
        // `complete` mode reports "capture of 'completion' … in a '@Sendable'
        // closure". The sink fires on `.main` (publisher's `receive(on:)`), where
        // `runSync` (and thus the completion) already runs; boxing is behavior-neutral.
        let completionBox = SyncCompletionBox(completion)
        // The self-cancelling one-shot sink lives in a Sendable box for the same
        // reason the old token did: the `@Sendable` closure must reference a stable
        // box, never capture-and-mutate a `var`.
        let cancellableBox = CancellableBox()
        cancellableBox.cancellable = registryStatePublisher.sink { [weak self] newState in
            guard let self else {
                cancellableBox.cancellable = nil
                return
            }
            if newState == .loaded || newState == .synced {
                cancellableBox.cancellable = nil
                self.runSync(completion: completionBox.completion)
            }
        }
    }

    private func runSync(completion: ((_ errorDocument: [AnyHashable: Any]?, _ newBooks: Bool) -> Void)?) {
        let priorState = state
        syncEngine.sync(currentState: priorState, setState: { [weak self] newState in
            self?.state = newState
        }, completion: { [weak self] errorDocument, newBooks in
            if let errorDocument {
                self?.postSyncFailure(errorDocument)
            }
            completion?(errorDocument, newBooks)
        })
    }

    func validateDownloadedContent() {
        syncEngine.validateDownloadedContent()
    }

    func reset(_ account: String) {
        state = .unloaded
        syncEngine.reset(account)
    }

    func saveSync() {
        guard let account = accountsManager.currentAccount?.uuid else { return }
        syncEngine.saveSync(for: account)
    }

    private func postSyncFailure(_ errorDocument: [AnyHashable: Any]?) {
        var userInfo: [AnyHashable: Any] = [:]
        if let errorDocument {
            userInfo[TPPBookRegistry.syncFailureErrorDocumentKey] = errorDocument
        }
        NotificationCenter.default.post(name: .TPPSyncFailed, object: nil, userInfo: userInfo)
    }

    // MARK: - Read-only queries (delegate directly to store — thread-safe via its sync queue)

    var allBooks: [TPPBook] { store.allBooks }
    var heldBooks: [TPPBook] { store.heldBooks }
    var myBooks: [TPPBook] { store.myBooks }

    func book(forIdentifier bookIdentifier: String?) -> TPPBook? {
        return store.book(forIdentifier: bookIdentifier)
    }

    func state(for bookIdentifier: String?) -> TPPBookState {
        return store.state(for: bookIdentifier)
    }

    func fulfillmentId(forIdentifier bookIdentifier: String?) -> String? {
        return store.fulfillmentId(forIdentifier: bookIdentifier)
    }

    func processing(forIdentifier bookIdentifier: String) -> Bool {
        return store.processing(forIdentifier: bookIdentifier)
    }

    // MARK: - Mutations

    func addBook(
        _ book: TPPBook,
        location: TPPBookLocation? = nil,
        state: TPPBookState = .downloadNeeded,
        fulfillmentId: String? = nil,
        readiumBookmarks: [TPPReadiumBookmark]? = nil,
        genericBookmarks: [TPPBookLocation]? = nil
    ) {
        imageLoader.thumbnailImage(for: book) { _ in }
        Log.info(#file, "📚 ADDING BOOK to registry: \(book.identifier), state: \(state.stringValue())")
        Log.info(#file, "📚 Initial bookmarks - readium: \(readiumBookmarks?.count ?? 0), generic: \(genericBookmarks?.count ?? 0)")

        let account = accountsManager.currentAccount?.uuid
        store.addBook(
            book,
            location: location,
            state: state,
            fulfillmentId: fulfillmentId,
            readiumBookmarks: readiumBookmarks,
            genericBookmarks: genericBookmarks
        ) { [weak self, syncEngine] _ in
            guard let self else { return }
            if let account { syncEngine.save(for: account) }
            DispatchQueue.main.async {
                self.store.bookStateSubject.send((book.identifier, state))
            }
        }
    }

    func removeBook(forIdentifier bookIdentifier: String) {
        guard !bookIdentifier.isEmpty else {
            Log.error(#file, "removeBook called with empty bookIdentifier")
            return
        }
        let account = accountsManager.currentAccount?.uuid
        store.removeBook(forIdentifier: bookIdentifier) { [weak self, syncEngine] removedBook, _ in
            guard let self else { return }
            Log.info(#file, "📚 REMOVING BOOK from registry: \(bookIdentifier)")
            if let account { syncEngine.save(for: account) }
            DispatchQueue.main.async {
                self.store.bookStateSubject.send((bookIdentifier, .unregistered))
                if let book = removedBook {
                    self.imageLoader.thumbnailImage(for: book) { _ in }
                }
            }
        }
    }

    func updateBook(_ book: TPPBook) {
        let account = accountsManager.currentAccount?.uuid
        store.updateBook(book) { [weak self, syncEngine] previousState, nextState, _ in
            guard let self else { return }
            if let account { syncEngine.save(for: account) }
            if nextState != previousState {
                DispatchQueue.main.async {
                    self.store.bookStateSubject.send((book.identifier, nextState))
                }
            }
        }
    }

    func updateAndRemoveBook(_ book: TPPBook) {
        imageLoader.thumbnailImage(for: book) { _ in }
        let account = accountsManager.currentAccount?.uuid
        store.updateAndRemoveBook(book) { [weak self, syncEngine] _ in
            guard let self else { return }
            if let account { syncEngine.save(for: account) }
            DispatchQueue.main.async {
                self.store.bookStateSubject.send((book.identifier, .unregistered))
            }
        }
    }

    func setState(_ state: TPPBookState, for bookIdentifier: String) {
        let previousState = self.state(for: bookIdentifier)
        if previousState != state {
            Log.debug(#file, "📊 State transition for '\(bookIdentifier)': \(previousState.stringValue()) → \(state.stringValue())")
            // Enforce the declared legal-transition set at the single mutation
            // seam. On violation, report (assert in DEBUG, log in RELEASE) but
            // STILL APPLY the write below — a dropped state would strand a book.
            if !TPPBookState.canTransition(from: previousState, to: state) {
                onIllegalTransition(previousState, state, bookIdentifier)
            }
        }
        let account = accountsManager.currentAccount?.uuid
        store.setState(state, for: bookIdentifier) { [weak self, syncEngine] in
            guard let self else { return }
            if let account { syncEngine.save(for: account) }
            DispatchQueue.main.async {
                self.store.bookStateSubject.send((bookIdentifier, state))
            }
        }
    }

    func setFulfillmentId(_ fulfillmentId: String, for bookIdentifier: String) {
        let account = accountsManager.currentAccount?.uuid
        store.setFulfillmentId(fulfillmentId, for: bookIdentifier)
        if let account { syncEngine.save(for: account) }
    }

    func setProcessing(_ processing: Bool, for bookIdentifier: String) {
        store.setProcessing(processing, for: bookIdentifier)
    }

    func updatedBookMetadata(_ book: TPPBook) -> TPPBook? {
        let account = accountsManager.currentAccount?.uuid
        let result = store.updatedBookMetadata(book)
        if result != nil, let account { syncEngine.save(for: account) }
        return result
    }

    // MARK: - Test-only deterministic-join seam

    /// Test-only: await the store's pending barrier writes (S1) THEN one
    /// main-queue hop, so the registry's state broadcasts have been delivered.
    ///
    /// Bounded in both stages:
    ///  1. `store._awaitPendingWritesForTesting()` drains the write barrier —
    ///     every prior mutation block plus its `onComplete` has run. Each of
    ///     those synchronously enqueues its `DispatchQueue.main.async`
    ///     re-broadcast (`registry` `didSet` snapshot post, and the per-mutation
    ///     `bookStateSubject.send` hops at ~617/633/648/661/682) BEFORE the
    ///     barrier completes.
    ///  2. One `DispatchQueue.main.async` hop then runs strictly AFTER all those
    ///     already-enqueued broadcasts by FIFO ordering on the main queue, and
    ///     resumes the continuation exactly once — never a bare `await` that
    ///     could hang, and no sleep/poll/clock.
    ///
    /// Deliberately does NOT await the account switch-back debounce
    /// (`asyncAfter` ~line 160): that is a UX timer, not fire-and-forget work;
    /// tests asserting switch-back drive it explicitly.
    func _awaitPendingWritesForTesting() async {
        await store._awaitPendingWritesForTesting()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { cont.resume() }
        }
    }

    // MARK: - Cover / thumbnail images

    func cachedThumbnailImage(for book: TPPBook) -> UIImage? {
        let simpleKey = book.identifier
        let thumbnailKey = "\(book.identifier)_thumbnail"
        return book.imageCache.get(for: simpleKey) ?? book.imageCache.get(for: thumbnailKey)
    }

    func thumbnailImage(
        for book: TPPBook?,
        handler: @escaping (_ image: UIImage?) -> Void
    ) {
        guard let book else { handler(nil); return }
        imageLoader.thumbnailImage(for: book, completion: handler)
    }

    func thumbnailImages(
        forBooks books: Set<TPPBook>,
        handler: @escaping (_ bookIdentifiersToImages: [String: UIImage]) -> Void
    ) {
        let group = DispatchGroup()
        var result = [String: UIImage]()
        for book in books {
            group.enter()
            imageLoader.thumbnailImage(for: book) { image in
                if let img = image { result[book.identifier] = img }
                group.leave()
            }
        }
        group.notify(queue: .main) { handler(result) }
    }

    func coverImage(
        for book: TPPBook,
        handler: @escaping (_ image: UIImage?) -> Void
    ) {
        imageLoader.coverImage(for: book, completion: handler)
    }
}

// MARK: - TPPBookRegistryProvider conformance — bookmark + location CRUD
//
// Each mutating bookmark wrapper captures `currentAccountId` synchronously and
// passes it through to the collaborator, so a save queued here lands in the
// registry owned by the account that issued the mutation — regardless of
// whether the user has switched libraries while the async barrier was pending.

extension TPPBookRegistry: TPPBookRegistryProvider {
    var registryState: RegistryState { state }

    // Bookmark/location mutations mirror the addBook pattern in the main class:
    // capture `currentAccount?.uuid` synchronously (so a library switch mid-flight
    // can't retarget the save to the wrong account — PP-4129), then pass it
    // through to the collaborator. BookmarkManager performs the in-memory mutation
    // unconditionally and skips save-to-disk when account is nil.

    func setLocation(_ location: TPPBookLocation?, forIdentifier bookIdentifier: String) {
        bookmarks.setLocation(location, forIdentifier: bookIdentifier,
                               account: accountsManager.currentAccount?.uuid)
    }

    func setLocationSync(_ location: TPPBookLocation?, forIdentifier bookIdentifier: String) {
        bookmarks.setLocationSync(location, forIdentifier: bookIdentifier,
                                   account: accountsManager.currentAccount?.uuid)
    }

    func location(forIdentifier bookIdentifier: String) -> TPPBookLocation? {
        return bookmarks.location(forIdentifier: bookIdentifier)
    }

    func readiumBookmarks(forIdentifier bookIdentifier: String) -> [TPPReadiumBookmark] {
        return bookmarks.readiumBookmarks(forIdentifier: bookIdentifier)
    }

    func add(_ bookmark: TPPReadiumBookmark, forIdentifier bookIdentifier: String) {
        bookmarks.addReadiumBookmark(bookmark, forIdentifier: bookIdentifier,
                                      account: accountsManager.currentAccount?.uuid)
    }

    func delete(_ bookmark: TPPReadiumBookmark, forIdentifier bookIdentifier: String) {
        bookmarks.deleteReadiumBookmark(bookmark, forIdentifier: bookIdentifier,
                                         account: accountsManager.currentAccount?.uuid)
    }

    func replace(_ oldBookmark: TPPReadiumBookmark, with newBookmark: TPPReadiumBookmark, forIdentifier bookIdentifier: String) {
        bookmarks.replaceReadiumBookmark(oldBookmark, with: newBookmark,
                                          forIdentifier: bookIdentifier,
                                          account: accountsManager.currentAccount?.uuid)
    }

    func genericBookmarksForIdentifier(_ bookIdentifier: String) -> [TPPBookLocation] {
        return bookmarks.genericBookmarks(forIdentifier: bookIdentifier)
    }

    func addOrReplaceGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {
        bookmarks.addOrReplaceGenericBookmark(location, forIdentifier: bookIdentifier,
                                               account: accountsManager.currentAccount?.uuid)
    }

    func addGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {
        bookmarks.addGenericBookmark(location, forIdentifier: bookIdentifier,
                                      account: accountsManager.currentAccount?.uuid)
    }

    func deleteGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {
        bookmarks.deleteGenericBookmark(location, forIdentifier: bookIdentifier,
                                         account: accountsManager.currentAccount?.uuid)
    }

    func replaceGenericBookmark(_ oldLocation: TPPBookLocation, with newLocation: TPPBookLocation, forIdentifier bookIdentifier: String) {
        bookmarks.replaceGenericBookmark(oldLocation, with: newLocation,
                                          forIdentifier: bookIdentifier,
                                          account: accountsManager.currentAccount?.uuid)
    }
}

// TPPBookLocation extensions in TPPBookLocation.swift
