import Foundation
import Combine
import UIKit

protocol TPPBookRegistryProvider {
    var registryPublisher: AnyPublisher<[String: TPPBookRegistryRecord], Never> { get }
    var bookStatePublisher: AnyPublisher<(String, TPPBookState), Never> { get }
    var heldBooks: [TPPBook] { get }

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

// MARK: - TPPBookRegistry facade

@objcMembers
class TPPBookRegistry: NSObject, TPPBookRegistrySyncing {

    @objc enum RegistryState: Int {
        case unloaded, loading, loaded, syncing, synced
    }

    // MARK: - Internal components

    private let store = BookRegistryStore()
    private lazy var syncManager = BookRegistrySync(store: store)
    private lazy var bookmarkManager = BookmarkManager(
        store: store,
        save: { [weak self] in self?.syncManager.save() },
        saveSync: { [weak self] in self?.syncManager.saveSync() }
    )

    // MARK: - Singleton

    static let shared = TPPBookRegistry()

    // MARK: - State

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

    private(set) var state: RegistryState = .unloaded {
        didSet {
            syncState.value = (state == .syncing)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .TPPBookRegistryStateDidChange, object: nil, userInfo: nil)
            }
        }
    }

    // MARK: - Publishers

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

    // MARK: - Account change observer

    private var accountDidChange = NotificationCenter.default.publisher(for: .TPPCurrentAccountDidChange)
        .receive(on: RunLoop.main)
        .sink { _ in
            TPPBookRegistry.shared.load()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                TPPBookRegistry.shared.sync()
            }
        }

    // MARK: - Init

    private override init() {
        super.init()
    }

    fileprivate init(account: String) {
        super.init()
        load(account: account)
    }

    func with(account: String, perform block: (_ registry: TPPBookRegistry) -> Void) {
        block(TPPBookRegistry(account: account))
    }

    func registryUrl(for account: String) -> URL? {
        return syncManager.registryUrl(for: account)
    }

    func load(account: String? = nil) {
        syncManager.load(account: account) { [weak self] newState in
            self?.state = newState
        }
    }

    func load() { load(account: nil) }

    func sync(completion: ((_ errorDocument: [AnyHashable: Any]?, _ newBooks: Bool) -> Void)? = nil) {
        syncManager.sync(
            currentState: state,
            setState: { [weak self] newState in self?.state = newState },
            save: { [weak self] in self?.syncManager.save() ?? () },
            completion: completion
        )
    }

    func sync() { sync(completion: nil) }

    func save() { syncManager.save() }
    func saveSync() { syncManager.saveSync() }

    func reset(_ account: String) {
        state = .unloaded
        syncManager.reset(account)
    }

    func validateDownloadedContent() {
        syncManager.validateDownloadedContent()
    }

    var allBooks: [TPPBook] { store.allBooks }
    var heldBooks: [TPPBook] { store.heldBooks }
    var myBooks: [TPPBook] { store.myBooks }

    func book(forIdentifier bookIdentifier: String?) -> TPPBook? {
        store.book(forIdentifier: bookIdentifier)
    }

    func state(for bookIdentifier: String?) -> TPPBookState { store.state(for: bookIdentifier) }
    func fulfillmentId(forIdentifier bookIdentifier: String?) -> String? { store.fulfillmentId(forIdentifier: bookIdentifier) }

    func addBook(
        _ book: TPPBook,
        location: TPPBookLocation? = nil,
        state: TPPBookState = .downloadNeeded,
        fulfillmentId: String? = nil,
        readiumBookmarks: [TPPReadiumBookmark]? = nil,
        genericBookmarks: [TPPBookLocation]? = nil
    ) {
        TPPBookCoverRegistryBridge.shared.thumbnailImageForBook(book) { _ in }

        Log.info(#file, "ADDING BOOK to registry: \(book.identifier), state: \(state.stringValue())")
        Log.info(#file, "Initial bookmarks - readium: \(readiumBookmarks?.count ?? 0), generic: \(genericBookmarks?.count ?? 0)")

        store.addBook(book, location: location, state: state, fulfillmentId: fulfillmentId, readiumBookmarks: readiumBookmarks, genericBookmarks: genericBookmarks) { [weak self] snapshot in
            self?.syncManager.save()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.store.registrySubject.send(snapshot)
                self.store.bookStateSubject.send((book.identifier, state))
                self.postStateNotification(bookIdentifier: book.identifier, state: state)
            }
        }
    }

    func updateAndRemoveBook(_ book: TPPBook) {
        TPPBookCoverRegistryBridge.shared.thumbnailImageForBook(book) { _ in }

        store.updateAndRemoveBook(book) { [weak self] snapshot in
            self?.syncManager.save()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.store.registrySubject.send(snapshot)
                self.store.bookStateSubject.send((book.identifier, .unregistered))
                self.postStateNotification(bookIdentifier: book.identifier, state: .unregistered)
            }
        }
    }

    func removeBook(forIdentifier bookIdentifier: String) {
        guard !bookIdentifier.isEmpty else {
            Log.error(#file, "removeBook called with empty bookIdentifier")
            return
        }

        store.removeBook(forIdentifier: bookIdentifier) { [weak self] removedBook, snapshot in
            self?.syncManager.save()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.store.registrySubject.send(snapshot)
                self.store.bookStateSubject.send((bookIdentifier, .unregistered))
                self.postStateNotification(bookIdentifier: bookIdentifier, state: .unregistered)
                if let book = removedBook {
                    TPPBookCoverRegistryBridge.shared.thumbnailImageForBook(book) { _ in }
                }
            }
        }
    }

    func updateBook(_ book: TPPBook) {
        store.updateBook(book) { [weak self] previousState, nextState, snapshot in
            self?.syncManager.save()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.store.registrySubject.send(snapshot)
                if nextState != previousState {
                    self.store.bookStateSubject.send((book.identifier, nextState))
                    self.postStateNotification(bookIdentifier: book.identifier, state: nextState)
                }
            }
        }
    }

    func updatedBookMetadata(_ book: TPPBook) -> TPPBook? {
        let result = store.updatedBookMetadata(book)
        syncManager.save()
        return result
    }

    func setState(_ state: TPPBookState, for bookIdentifier: String) {
        let previousState = self.state(for: bookIdentifier)
        if previousState != state {
            Log.debug(#file, "State transition for '\(bookIdentifier)': \(previousState.stringValue()) -> \(state.stringValue())")
        }

        store.setState(state, for: bookIdentifier) { [weak self] in
            self?.postStateNotification(bookIdentifier: bookIdentifier, state: state)
            self?.syncManager.save()
            DispatchQueue.main.async {
                self?.store.bookStateSubject.send((bookIdentifier, state))
            }
        }
    }

    func setFulfillmentId(_ fulfillmentId: String, for bookIdentifier: String) {
        store.setFulfillmentId(fulfillmentId, for: bookIdentifier)
        syncManager.save()
    }

    func setProcessing(_ processing: Bool, for bookIdentifier: String) { store.setProcessing(processing, for: bookIdentifier) }
    func processing(forIdentifier bookIdentifier: String) -> Bool { store.processing(forIdentifier: bookIdentifier) }

    func cachedThumbnailImage(for book: TPPBook) -> UIImage? {
        let simpleKey = book.identifier
        let thumbnailKey = "\(book.identifier)_thumbnail"
        return book.imageCache.get(for: simpleKey) ?? book.imageCache.get(for: thumbnailKey)
    }

    func thumbnailImage(for book: TPPBook?, handler: @escaping (_ image: UIImage?) -> Void) {
        guard let book else { handler(nil); return }
        TPPBookCoverRegistryBridge.shared.thumbnailImageForBook(book, completion: handler)
    }

    func thumbnailImages(forBooks books: Set<TPPBook>, handler: @escaping (_ bookIdentifiersToImages: [String: UIImage]) -> Void) {
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

    func coverImage(for book: TPPBook, handler: @escaping (_ image: UIImage?) -> Void) {
        TPPBookCoverRegistryBridge.shared.coverImageForBook(book, completion: handler)
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
}

// MARK: - TPPBookRegistryProvider conformance (bookmarks & location)

extension TPPBookRegistry: TPPBookRegistryProvider {
    func setLocation(_ location: TPPBookLocation?, forIdentifier bookIdentifier: String) {
        bookmarkManager.setLocation(location, forIdentifier: bookIdentifier)
    }

    func setLocationSync(_ location: TPPBookLocation?, forIdentifier bookIdentifier: String) {
        bookmarkManager.setLocationSync(location, forIdentifier: bookIdentifier)
    }

    func location(forIdentifier bookIdentifier: String) -> TPPBookLocation? {
        bookmarkManager.location(forIdentifier: bookIdentifier)
    }

    func readiumBookmarks(forIdentifier bookIdentifier: String) -> [TPPReadiumBookmark] {
        bookmarkManager.readiumBookmarks(forIdentifier: bookIdentifier)
    }

    func add(_ bookmark: TPPReadiumBookmark, forIdentifier bookIdentifier: String) {
        bookmarkManager.addReadiumBookmark(bookmark, forIdentifier: bookIdentifier)
    }

    func delete(_ bookmark: TPPReadiumBookmark, forIdentifier bookIdentifier: String) {
        bookmarkManager.deleteReadiumBookmark(bookmark, forIdentifier: bookIdentifier)
    }

    func replace(_ oldBookmark: TPPReadiumBookmark, with newBookmark: TPPReadiumBookmark, forIdentifier bookIdentifier: String) {
        bookmarkManager.replaceReadiumBookmark(oldBookmark, with: newBookmark, forIdentifier: bookIdentifier)
    }

    func genericBookmarksForIdentifier(_ bookIdentifier: String) -> [TPPBookLocation] {
        bookmarkManager.genericBookmarks(forIdentifier: bookIdentifier)
    }

    func addOrReplaceGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {
        bookmarkManager.addOrReplaceGenericBookmark(location, forIdentifier: bookIdentifier)
    }

    func addGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {
        bookmarkManager.addGenericBookmark(location, forIdentifier: bookIdentifier)
    }

    func deleteGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {
        bookmarkManager.deleteGenericBookmark(location, forIdentifier: bookIdentifier)
    }

    func replaceGenericBookmark(_ oldLocation: TPPBookLocation, with newLocation: TPPBookLocation, forIdentifier bookIdentifier: String) {
        bookmarkManager.replaceGenericBookmark(oldLocation, with: newLocation, forIdentifier: bookIdentifier)
    }
}

