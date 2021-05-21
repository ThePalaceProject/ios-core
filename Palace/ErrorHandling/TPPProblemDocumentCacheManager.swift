extension Notification.Name {
  static let TPPProblemDocumentWasCached = Notification.Name("TPPProblemDocumentWasCached")
}

@objc extension NSNotification {
  public static let TPPProblemDocumentWasCached = Notification.Name.TPPProblemDocumentWasCached
}

@objcMembers class TPPProblemDocumentCacheManager : NSObject {
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
  
  // Member values
  private var cache: [String : [DocWithTimestamp]]
  
  override init() {
    cache = [String : [DocWithTimestamp]]()
    super.init()
  }
  
  // MARK: - Write
  
  @objc func cacheProblemDocument(_ doc: TPPProblemDocument, key: String) {
    let timeStampDoc = DocWithTimestamp.init(doc)
    guard var vals = cache[key] else {
      cache[key] = [timeStampDoc]
      NotificationCenter.default.post(name: NSNotification.Name.TPPProblemDocumentWasCached, object: doc)
      return
    }
    
    if vals.count >= TPPProblemDocumentCacheManager.CACHE_SIZE {
      vals.removeFirst(1)
      vals.append(timeStampDoc)
      cache[key] = vals
    }
    NotificationCenter.default.post(name: NSNotification.Name.TPPProblemDocumentWasCached, object: doc)
  }
  
  @objc(clearCachedDocForBookIdentifier:)
  func clearCachedDoc(_ key: String) {
    cache[key] = []
  }
  
  // MARK: - Read
  
  func getLastCachedDoc(_ key: String) -> TPPProblemDocument? {
    guard let cachedDocuments = cache[key] else {
      return nil
    }
    return cachedDocuments.last?.doc
  }
}
