import XCTest
@testable import Palace

class TPPAnnouncementManagerTests: XCTestCase {
    let announcementId = "test_announcement_id"

    override func tearDown() {
        TPPAnnouncementBusinessLogic.shared.testing_deletePresentedAnnouncement(id: announcementId)
    }

    func testShouldPresentAnnouncement() {
        // Before any presentation: a new ID should be presentable
        XCTAssertTrue(TPPAnnouncementBusinessLogic.shared.testing_shouldPresentAnnouncement(id: announcementId))
        // A different ID should also be independently presentable
        let otherId = announcementId + "_other"
        XCTAssertTrue(TPPAnnouncementBusinessLogic.shared.testing_shouldPresentAnnouncement(id: otherId))
        // Cleanup other ID
        TPPAnnouncementBusinessLogic.shared.testing_deletePresentedAnnouncement(id: otherId)
    }

    func testAddPresentedAnnouncement() {
        TPPAnnouncementBusinessLogic.shared.addPresentedAnnouncement(id: announcementId)
        // After marking as presented, it should no longer be presentable
        XCTAssertFalse(TPPAnnouncementBusinessLogic.shared.testing_shouldPresentAnnouncement(id: announcementId))
        // Calling add again should be idempotent (still not presentable)
        TPPAnnouncementBusinessLogic.shared.addPresentedAnnouncement(id: announcementId)
        XCTAssertFalse(TPPAnnouncementBusinessLogic.shared.testing_shouldPresentAnnouncement(id: announcementId),
                       "Adding a presented announcement twice should remain non-presentable")
    }

    func testDeletePresentedAnnouncement() {
        // First present it so delete has something to remove
        TPPAnnouncementBusinessLogic.shared.addPresentedAnnouncement(id: announcementId)
        XCTAssertFalse(TPPAnnouncementBusinessLogic.shared.testing_shouldPresentAnnouncement(id: announcementId),
                       "Pre-condition: announcement should be non-presentable after being added")
        // Now delete it — should become presentable again
        TPPAnnouncementBusinessLogic.shared.testing_deletePresentedAnnouncement(id: announcementId)
        XCTAssertTrue(TPPAnnouncementBusinessLogic.shared.testing_shouldPresentAnnouncement(id: announcementId),
                      "After deletion, announcement should be presentable again")
    }
}
