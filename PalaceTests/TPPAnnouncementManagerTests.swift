import XCTest
@testable import Palace

class TPPAnnouncementManagerTests: XCTestCase {
  let announcementId = "test_announcement_id"
    
  override func tearDown() {
    NYPLAnnouncementBusinessLogic.shared.testing_deletePresentedAnnouncement(id: announcementId)
  }
    
  func testShouldPresentAnnouncement() {
    XCTAssertTrue(NYPLAnnouncementBusinessLogic.shared.testing_shouldPresentAnnouncement(id:announcementId))
  }
    
  func testAddPresentedAnnouncement() {
    NYPLAnnouncementBusinessLogic.shared.addPresentedAnnouncement(id: announcementId)
    XCTAssertFalse(NYPLAnnouncementBusinessLogic.shared.testing_shouldPresentAnnouncement(id:announcementId))
  }
  
  func testDeletePresentedAnnouncement() {
    NYPLAnnouncementBusinessLogic.shared.testing_deletePresentedAnnouncement(id: announcementId)
    XCTAssertTrue(NYPLAnnouncementBusinessLogic.shared.testing_shouldPresentAnnouncement(id:announcementId))
  }
}
