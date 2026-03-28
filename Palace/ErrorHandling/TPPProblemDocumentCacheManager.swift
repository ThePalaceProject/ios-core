extension Notification.Name {
    static let TPPProblemDocumentWasCached = Notification.Name("TPPProblemDocumentWasCached")
}

@objc extension NSNotification {
    public static let TPPProblemDocumentWasCached = Notification.Name.TPPProblemDocumentWasCached
}

@objcMembers class TPPProblemDocumentCacheManager: NSObject {
    struct DocWithTimestamp {
        let doc: TPPProblemDocument
        let timestamp: Date

        init(_ document: TPPProblemDocument) {
            doc = document
            timestamp = Date.init()
        }
    }

    // Static values
    static let CACHE_SIZE = 5
    static let shared = TPPProblemDocumentCacheManager()

    // For Objective-C classes
    class func sharedInstance() -> TPPProblemDocumentCacheManager {
        return TPPProblemDocumentCacheManager.shared
    }

    private var cache = [String: [DocWithTimestamp]]()
    // NSLock blocks at the OS/kernel level and never consumes a GCD thread-pool slot.
    // DispatchQueue.sync-based approaches can exhaust the 64-thread GCD pool when
    // many callers block simultaneously, causing deadlocks in the whole process.
    private let lock = NSLock()

    override init() {
        super.init()
    }

    // MARK: - Write

    func cacheProblemDocument(_ doc: TPPProblemDocument, key: String) {
        let timeStampDoc = DocWithTimestamp(doc)
        lock.lock()
        var vals = cache[key] ?? []
        if vals.count >= TPPProblemDocumentCacheManager.CACHE_SIZE {
            vals.removeFirst(1)
        }
        vals.append(timeStampDoc)
        cache[key] = vals
        lock.unlock()
        NotificationCenter.default.post(name: NSNotification.Name.TPPProblemDocumentWasCached, object: doc)
    }

    @objc(clearCachedDocForBookIdentifier:)
    func clearCachedDoc(_ key: String) {
        lock.lock()
        cache[key] = nil
        lock.unlock()
    }

    // MARK: - Read

    func getLastCachedDoc(_ key: String) -> TPPProblemDocument? {
        lock.lock()
        defer { lock.unlock() }
        return cache[key]?.last?.doc
    }
}
