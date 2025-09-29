import XCTest
@testable import Palace

class TPPAnnouncementManagerTests: XCTestCase {
  let announcementId = "test_announcement_id"

  override func tearDown() {
    TPPAnnouncementBusinessLogic.shared.testing_deletePresentedAnnouncement(id: announcementId)
  }

  func testShouldPresentAnnouncement() {
    XCTAssertTrue(TPPAnnouncementBusinessLogic.shared.testing_shouldPresentAnnouncement(id: announcementId))
  }

  func testAddPresentedAnnouncement() {
    TPPAnnouncementBusinessLogic.shared.addPresentedAnnouncement(id: announcementId)
    XCTAssertFalse(TPPAnnouncementBusinessLogic.shared.testing_shouldPresentAnnouncement(id: announcementId))
  }

  func testDeletePresentedAnnouncement() {
    TPPAnnouncementBusinessLogic.shared.testing_deletePresentedAnnouncement(id: announcementId)
    XCTAssertTrue(TPPAnnouncementBusinessLogic.shared.testing_shouldPresentAnnouncement(id: announcementId))
  }
}
