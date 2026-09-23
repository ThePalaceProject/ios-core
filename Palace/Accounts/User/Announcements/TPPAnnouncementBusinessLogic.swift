import Foundation
import PalaceCatalog

private let announcementsFilename: String = "TPPPresentedAnnouncementsList"

/// UIKit-driving announcement presentation logic. Main-actor-isolated:
/// the presentation methods (`presentAnnouncements`, `alert`) build and
/// present `UIAlertController`s, and the mutable `presentedAnnouncements`
/// `Set` is read/written only from those flows plus the file-persistence
/// helpers. This is why the class was already documented "not thread safe"
/// and "should be called on main thread," and why its sole production caller
/// (`Account.loadAuthenticationDocument`) already invokes `presentAnnouncements`
/// inside `MainActor.assumeIsolated`.
///
/// Isolating the class to `@MainActor` makes `static let shared`
/// concurrency-safe (Swift 6 Phase B: clears "static property 'shared' is not
/// concurrency-safe because non-Sendable type … may have shared mutable
/// state") without changing any announcement logic — this is additive
/// isolation only. The pure, stateless `chainAttachmentIndices` helper is
/// kept `nonisolated` (see the extension below) so it remains freely callable.
@MainActor
class TPPAnnouncementBusinessLogic {
    typealias DisplayStrings = Strings.Announcments

    static let shared = TPPAnnouncementBusinessLogic()

    private var presentedAnnouncements: Set<String> = Set<String>()

    init() {
        restorePresentedAnnouncements()
    }

    /// Present the announcement in a view controller
    /// This method should be called on main thread
    @MainActor
    func presentAnnouncements(_ announcements: [Announcement]) {
        let presentableAnnouncements = announcements.filter {
            shouldPresentAnnouncement(id: $0.id)
        }
        guard let alert = self.alert(announcements: presentableAnnouncements) else {
            return
        }
        TPPPresentationUtils.safelyPresent(alert, animated: true, completion: nil)
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
            let codedData = try NSKeyedArchiver.archivedData(withRootObject: presentedAnnouncements, requiringSecureCoding: false)
            try codedData.write(to: filePathURL)
        } catch {
            TPPErrorLogger.logError(error,
                                    summary: "Fail to write Presented Announcements file to local storage",
                                    metadata: ["filePathURL": filePathURL,
                                               "presentedAnnouncements": presentedAnnouncements])
        }
    }

    // MARK: - Helper

    /**
     Generates an alert view that presents another alert when being dismissed
     - Parameter announcements: an array of announcements that goes into alert message.
     - Returns: The alert controller to be presented.
     */
    @MainActor
    private func alert(announcements: [Announcement]) -> UIAlertController? {
        let title = DisplayStrings.alertTitle
        var currentAlert: UIAlertController?

        let alerts = announcements.map {
            UIAlertController.init(title: title, message: $0.content, preferredStyle: .alert)
        }

        // Present another alert when the current alert is being dismiss.
        // For announcement count N, alerts[k-1] gets the action that presents
        // alerts[k] and marks announcements[k-1] as presented (1 ≤ k ≤ N-1).
        for pair in Self.chainAttachmentIndices(forAnnouncementCount: alerts.count) {
            let nextAlert = alerts[pair.present]
            let action = UIAlertAction.init(title: DisplayStrings.ok,
                                            style: .default) { [weak self] _ in
                // Defer the next chained alert until the current alert's dismiss
                // transition has settled. Presenting synchronously from the dismiss
                // handler races that dismiss (fe741015 CA-commit race); a main-queue
                // hop lets the dismiss complete so safelyPresent's coordinator-wait
                // sees a stable view-controller hierarchy.
                DispatchQueue.main.async {
                    TPPPresentationUtils.safelyPresent(nextAlert, animated: true, completion: nil)
                }
                self?.addPresentedAnnouncement(id: announcements[pair.attach].id)
            }
            alerts[pair.attach].addAction(action)
        }
        if let last = alerts.last {
            currentAlert = last
        }

        // Add dismiss button to the last announcement
        if let last = announcements.last {
            currentAlert?.addAction(UIAlertAction.init(title: DisplayStrings.ok, style: .default) { [weak self] _ in
                self?.addPresentedAnnouncement(id: last.id)
            })
        }

        return alerts.first
    }
}

extension TPPAnnouncementBusinessLogic {
    /// For an announcement count of N, returns N-1 (attach, present) pairs:
    /// `alerts[attach]` gets a tap-action that presents `alerts[present]`.
    /// Pure helper extracted from `alert(announcements:)` so the i > 0 / i - 1
    /// conditional logic that was previously embedded in the loop body can
    /// be exercised by unit tests.
    nonisolated static func chainAttachmentIndices(forAnnouncementCount count: Int) -> [(attach: Int, present: Int)] {
        guard count > 1 else { return [] }
        return (1..<count).map { i in (attach: i - 1, present: i) }
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
