import Foundation
import Combine
import UIKit

protocol TPPBookRegistryProvider {
    var registryPublisher: AnyPublisher<[String: TPPBookRegistryRecord], Never> { get }
    var bookStatePublisher: AnyPublisher<(String, TPPBookState), Never> { get }
    var syncStatePublisher: AnyPublisher<Bool, Never> { get }
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
}

// TPPBookRegistryData and TPPBookRegistryKey defined in TPPBookRegistryRecord.swift

private class BoolWithDelay {
    private var switchBackDelay: Double
    private var resetTask: DispatchWorkItem?
    private var onChange: ((_ value: Bool) -> Void)?
    init(delay: Double = 5, onChange: ((_ value: Bool) -> Void)? = nil) {
        self.switchBackDelay = delay
        self.onChange = onChange
    }
    var value: Bool = false {
        willSet {
            if value != newValue {
                onChange?(newValue)
            }
        }
        didSet {
            resetTask?.cancel()
            if value {
                let task = DispatchWorkItem { [weak self] in
                    self?.value = false
                }
                resetTask = task
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
@objcMembers
class TPPBookRegistry: NSObject, TPPBookRegistrySyncing {
    static let syncFailureErrorDocumentKey = "TPPBookRegistrySyncFailureErrorDocument"

    @objc enum RegistryState: Int {
        case unloaded, loading, loaded, syncing, synced
    }

    // MARK: - Collaborators

    private let store: BookRegistryStore
    private let syncEngine: BookRegistrySync
    private let bookmarks: BookmarkManager

    // MARK: - External dependencies

    private let accountsManager: AccountsManager
    private lazy var downloadCenter: MyBooksDownloadCenter = .shared
    private var coverRegistry = TPPBookCoverRegistry.shared

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

    // MARK: - Shared singleton

    static let shared = TPPBookRegistry()

    // MARK: - State + publishers

    private(set) var state: RegistryState = .unloaded {
        didSet {
            syncState.value = (state == .syncing)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .TPPBookRegistryStateDidChange, object: nil, userInfo: nil)
            }
        }
    }

    private var syncState = BoolWithDelay { value in
        if value {
            NotificationCenter.default.post(name: .TPPSyncBegan, object: nil, userInfo: nil)
        } else {
            NotificationCenter.default.post(name: .TPPSyncEnded, object: nil, userInfo: nil)
        }
    }

    private(set) var isSyncing: Bool {
        get { return syncState.value }
        set { }
    }

    private let syncStateSubject = CurrentValueSubject<Bool, Never>(false)

    var syncStatePublisher: AnyPublisher<Bool, Never> {
        syncStateSubject.eraseToAnyPublisher()
    }

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

    private override init() {
        self.accountsManager = .shared
        let store = BookRegistryStore()
        let sync = BookRegistrySync(store: store)
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

    fileprivate init(account: String, accountsManager: AccountsManager = .shared) {
        self.accountsManager = accountsManager
        let store = BookRegistryStore()
        let sync = BookRegistrySync(store: store)
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
        block(TPPBookRegistry(account: account))
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
        // Both cases: subscribe to `TPPBookRegistryStateDidChange` and run
        // sync once state reaches `.loaded`/`.synced`. Then kick off a
        // load (no-op if one is already in flight). Either path drives
        // the observer to the .loaded transition.
        if state == .unloaded || state == .loading {
            waitForLoadThenRunSync(completion: completion)
            if state == .unloaded {
                load()
            }
            return
        }
        runSync(completion: completion)
    }

    /// Subscribes to the registry state-change notification and runs sync
    /// the first time state reaches `.loaded`/`.synced`. The observer
    /// removes itself on first match so it's a one-shot.
    private func waitForLoadThenRunSync(completion: ((_ errorDocument: [AnyHashable: Any]?, _ newBooks: Bool) -> Void)?) {
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(
            forName: .TPPBookRegistryStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else {
                if let token { NotificationCenter.default.removeObserver(token) }
                return
            }
            if self.state == .loaded || self.state == .synced {
                if let token { NotificationCenter.default.removeObserver(token) }
                self.runSync(completion: completion)
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

    func sync() { sync(completion: nil) }

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
        TPPBookCoverRegistryBridge.shared.thumbnailImageForBook(book) { _ in }
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
                self.postStateNotification(bookIdentifier: book.identifier, state: state)
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
                self.postStateNotification(bookIdentifier: bookIdentifier, state: .unregistered)
                if let book = removedBook {
                    TPPBookCoverRegistryBridge.shared.thumbnailImageForBook(book) { _ in }
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
                    self.postStateNotification(bookIdentifier: book.identifier, state: nextState)
                }
            }
        }
    }

    func updateAndRemoveBook(_ book: TPPBook) {
        TPPBookCoverRegistryBridge.shared.thumbnailImageForBook(book) { _ in }
        let account = accountsManager.currentAccount?.uuid
        store.updateAndRemoveBook(book) { [weak self, syncEngine] _ in
            guard let self else { return }
            if let account { syncEngine.save(for: account) }
            DispatchQueue.main.async {
                self.store.bookStateSubject.send((book.identifier, .unregistered))
                self.postStateNotification(bookIdentifier: book.identifier, state: .unregistered)
            }
        }
    }

    func setState(_ state: TPPBookState, for bookIdentifier: String) {
        let previousState = self.state(for: bookIdentifier)
        if previousState != state {
            Log.debug(#file, "📊 State transition for '\(bookIdentifier)': \(previousState.stringValue()) → \(state.stringValue())")
        }
        let account = accountsManager.currentAccount?.uuid
        store.setState(state, for: bookIdentifier) { [weak self, syncEngine] in
            guard let self else { return }
            if let account { syncEngine.save(for: account) }
            self.postStateNotification(bookIdentifier: bookIdentifier, state: state)
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

    @available(*, deprecated, message: "Use Combine publishers instead.")
    private func postStateNotification(bookIdentifier: String, state: TPPBookState) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .TPPBookRegistryStateDidChange,
                object: nil,
                userInfo: [
                    "bookIdentifier": bookIdentifier,
                    "state": state.rawValue
                ]
            )
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
        TPPBookCoverRegistryBridge.shared.thumbnailImageForBook(book, completion: handler)
    }

    func thumbnailImages(
        forBooks books: Set<TPPBook>,
        handler: @escaping (_ bookIdentifiersToImages: [String: UIImage]) -> Void
    ) {
        let group = DispatchGroup()
        var result = [String: UIImage]()
        for book in books {
            group.enter()
            TPPBookCoverRegistryBridge.shared.thumbnailImageForBook(book) { image in
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
        TPPBookCoverRegistryBridge.shared.coverImageForBook(book, completion: handler)
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
