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
            timestamp = Date()
        }
    }

    static let CACHE_SIZE = 5
    static let shared = TPPProblemDocumentCacheManager()

    class func sharedInstance() -> TPPProblemDocumentCacheManager {
        return TPPProblemDocumentCacheManager.shared
    }

    private var cache = [String: [DocWithTimestamp]]()
    private let queue = DispatchQueue(label: "org.thepalaceproject.problemDocumentCache")

    override init() {
        super.init()
    }

    // MARK: - Write

    func cacheProblemDocument(_ doc: TPPProblemDocument, key: String) {
        let timeStampDoc = DocWithTimestamp(doc)
        queue.sync {
            var vals = cache[key] ?? []
            if vals.count >= TPPProblemDocumentCacheManager.CACHE_SIZE {
                vals.removeFirst(1)
            }
            vals.append(timeStampDoc)
            cache[key] = vals
        }
        NotificationCenter.default.post(name: NSNotification.Name.TPPProblemDocumentWasCached, object: doc)
    }

    @objc(clearCachedDocForBookIdentifier:)
    func clearCachedDoc(_ key: String) {
        queue.sync {
            cache[key] = nil
        }
    }

    // MARK: - Read

    func getLastCachedDoc(_ key: String) -> TPPProblemDocument? {
        queue.sync {
            cache[key]?.last?.doc
        }
    }
}
