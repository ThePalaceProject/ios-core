import Foundation

/// Returns the URL of the directory used for storing content and metadata.
/// The directory is not guaranteed to exist at the time this method is called.
@objcMembers final class TPPBookContentMetadataFilesHelper : NSObject {
  
  class func currentAccountDirectory() -> URL? {
    guard let accountId = AccountsManager.shared.currentAccountId else {
      return nil
    }
    return directory(for: accountId)
  }
  
  class func directory(for account: String) -> URL? {
    let paths = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true)
    
    if paths.count < 1 {
      TPPErrorLogger.logError(withCode: .missingSystemPaths,
                               summary: "No valid search paths in iOS's ApplicationSupport directory in UserDomain",
                               metadata: ["account": account])
      return nil
    }

    let bundleID = Bundle.main.object(forInfoDictionaryKey: "CFBundleIdentifier") as! String
    var dirURL = URL(fileURLWithPath: paths[0]).appendingPathComponent(bundleID)
    
    if (account != AccountsManager.TPPAccountUUIDs[0]) {
      dirURL = dirURL.appendingPathComponent(String(account))
    }
    
    return dirURL
  }
}
