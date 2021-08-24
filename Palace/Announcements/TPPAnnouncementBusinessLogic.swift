import Foundation

private let announcementsFilename: String = "TPPPresentedAnnouncementsList"

/// This class is not thread safe
class TPPAnnouncementBusinessLogic {
  static let shared = TPPAnnouncementBusinessLogic()

  private var presentedAnnouncements: Set<String> = Set<String>()
    
  init() {
    restorePresentedAnnouncements()
  }
    
  /// Present the announcement in a view controller
  /// This method should be called on main thread
  func presentAnnouncements(_ announcements: [Announcement]) {
    for announcement in announcements {
      if shouldPresentAnnouncement(id: announcement.id) {
        let vc = TPPAnnouncementViewController(announcement: announcement)
        TPPRootTabBarController.shared()?.safelyPresentViewController(vc, animated: true, completion: nil)
      }
    }
  }
  
  // MARK: - Read
    
  private func restorePresentedAnnouncements() {
    guard let filePathURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(announcementsFilename),
      let filePathData = try? Data(contentsOf: filePathURL),
      let unarchived = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(filePathData),
      let presented = unarchived as? Set<String> else {
        return
    }
    presentedAnnouncements = presented
  }
    
  private func shouldPresentAnnouncement(id: String) -> Bool {
    return !presentedAnnouncements.contains(id)
  }
  
  // MARK: - Write

  func addPresentedAnnouncement(id: String) {
    presentedAnnouncements.insert(id)
    
    storePresentedAnnouncementsToFile()
  }

  private func deletePresentedAnnouncement(id: String) {
    presentedAnnouncements.remove(id)
    
    storePresentedAnnouncementsToFile()
  }
    
  private func storePresentedAnnouncementsToFile() {
    guard let filePathURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(announcementsFilename) else {
        TPPErrorLogger.logError(withCode: .directoryURLCreateFail, summary: "Unable to create directory URL for storing presented announcements")
      return
    }
    
    do {
      let codedData = NSKeyedArchiver.archivedData(withRootObject: presentedAnnouncements)
      try codedData.write(to: filePathURL)
    } catch {
      TPPErrorLogger.logError(error,
                               summary: "Fail to write Presented Announcements file to local storage",
                               metadata: ["filePathURL": filePathURL,
                                          "presentedAnnouncements": presentedAnnouncements])
    }
  }
}

// Wrapper for unit testing
extension TPPAnnouncementBusinessLogic {
  func testing_shouldPresentAnnouncement(id: String) -> Bool {
    shouldPresentAnnouncement(id: id)
  }
    
  func testing_deletePresentedAnnouncement(id: String) {
    deletePresentedAnnouncement(id: id)
  }
}
