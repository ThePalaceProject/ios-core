//
//  NotificationService.swift
//  Palace
//
//  Created by Vladimir Fedorov on 07.10.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import UserNotifications
import FirebaseCore
import FirebaseMessaging

// MARK: - Notification Constants

/// Category identifier for local hold availability notifications
let HoldNotificationCategoryIdentifier = "NYPLHoldToReserveNotificationCategory"
/// Action identifier for checkout action on local notifications
let CheckOutActionIdentifier = "NYPLCheckOutNotificationAction"
/// Default action identifier for notification taps
let DefaultActionIdentifier = "UNNotificationDefaultActionIdentifier"

// MARK: - NotificationService

/// Consolidated notification service for the Palace app.
///
/// Handles:
/// - Push notifications from Firebase Cloud Messaging (FCM)
/// - Local notifications for hold availability (reserved → ready transitions)
/// - App icon badge updates for ready holds
/// - FCM token management with the library server
///
/// This service is the sole `UNUserNotificationCenterDelegate` for the app.
@objcMembers
class NotificationService: NSObject, UNUserNotificationCenterDelegate, MessagingDelegate {
  
  /// Token data structure
  ///
  /// Based on API documentation
  /// https://www.notion.so/lyrasis/Send-push-notifications-for-reservation-availability-and-loan-expiry-2866943ebe774cbd90b5df81db811648
  struct TokenData: Codable {
    let device_token: String
    let token_type: String
    
    init(token: String) {
      self.device_token = token
      self.token_type = "FCMiOS"
    }
    
    var data: Data? {
      try? JSONEncoder().encode(self)
    }
  }

  private let notificationCenter = UNUserNotificationCenter.current()
  
  static let shared = NotificationService()
  
  override init() {
    super.init()
    
    // Update library token when the user changes library account.
    NotificationCenter.default.addObserver(forName: NSNotification.Name.TPPCurrentAccountDidChange, object: nil, queue: nil) { _ in
      self.updateToken()
    }
    // Update library token when the user signes in (but has already added the library)
    NotificationCenter.default.addObserver(forName: NSNotification.Name.TPPIsSigningIn, object: nil, queue: nil) { notification in
      if let isSigningIn = notification.object as? Bool, !isSigningIn {
        self.updateToken()
      }
    }
  }
  
  @objc
  static func sharedService() -> NotificationService {
    return shared
  }
  
  @objc
  /// Runs configuration function, registers the app for remote notifications.
  func setupPushNotifications(completion: ((_ granted: Bool) -> Void)? = nil) {
    notificationCenter.delegate = self
    notificationCenter.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
      if granted {
        DispatchQueue.main.async {
          UIApplication.shared.registerForRemoteNotifications()
        }
      }
      completion?(granted)
    }
    Messaging.messaging().delegate = self
  }
  
  func getNotificationStatus(completion: @escaping (_ areEnabled: Bool) -> Void) {
    notificationCenter.getNotificationSettings { notificationSettings in
      switch notificationSettings.authorizationStatus {
      case .authorized, .provisional: completion(true)
      default: completion(false)
      }
    }
  }
  
  /// Check if token exists on the server
  /// - Parameters:
  ///   - token: FCM token value
  ///   - completion: `(exists: Bool, error: Error?) -> Void`
  ///
  /// The existence of the token is based on the server response status code:
  /// - 200: exists
  /// - 404 doesn't exist
  /// `exists` is `nil` for any other response status code.
  private func checkTokenExists(_ token: String, endpointUrl: URL, completion: @escaping (Bool?, Error?) -> Void) {
    guard
      let requestUrl = URL(string: "\(endpointUrl.absoluteString)?device_token=\(token)")
    else {
      return
    }
    let request = URLRequest(url: requestUrl, applyingCustomUserAgent: true)
    _ = TPPNetworkExecutor.shared.addBearerAndExecute(request) { result, response, error in
      let status = (response as? HTTPURLResponse)?.statusCode
      // Token exists if status code is 200, doesn't exist if 404.
      switch status {
      case 200: completion(true, error)
      case 404: completion(false, error)
      default: completion(nil, error)
      }
    }
  }
  
  /// Save token to the server
  /// - Parameter token: FCM token value
  private func saveToken(_ token: String, endpointUrl: URL) {
    guard let requestBody = TokenData(token: token).data else {
      return
    }
    var request = URLRequest(url: endpointUrl, applyingCustomUserAgent: true)
    request.httpMethod = "PUT"
    request.httpBody = requestBody
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    _ = TPPNetworkExecutor.shared.addBearerAndExecute(request) { result, response, error in
      if let error = error {
        TPPErrorLogger.logError(error,
                                summary: "Couldn't upload token data",
                                metadata: [
                                  "requestURL": endpointUrl,
                                  "tokenData": String(data: requestBody, encoding: .utf8) ?? "",
                                  "statusCode": (response as? HTTPURLResponse)?.statusCode ?? 0
                                ]
        )
      }
    }
  }
  
  /// Sends FCM to the backend
  ///
  /// Update token when user account changes
  func updateToken() {
    guard !(AccountsManager.shared.currentAccount?.hasUpdatedToken ?? false) else {
      return
    }

    AccountsManager.shared.currentAccount?.hasUpdatedToken = true
    AccountsManager.shared.currentAccount?.getProfileDocument { profileDocument in
      guard let endpointHref = profileDocument?.linksWith(.deviceRegistration).first?.href,
            let endpointUrl = URL(string: endpointHref)
      else {
        return
      }
      Messaging.messaging().token { token, _ in
        if let token {
          self.checkTokenExists(token, endpointUrl: endpointUrl) { exists, _ in
            if let exists = exists, !exists {
              self.saveToken(token, endpointUrl: endpointUrl)
            }
          }
        }
      }
    }
  }
    
  private func deleteToken(_ token: String, endpointUrl: URL) {
    guard let requestBody = TokenData(token: token).data else {
      return
    }
    var request = URLRequest(url: endpointUrl, applyingCustomUserAgent: true)
    request.httpMethod = "DELETE"
    request.httpBody = requestBody
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    _ = TPPNetworkExecutor.shared.addBearerAndExecute(request) { result, response, error in
      if let error = error {
        TPPErrorLogger.logError(error,
                                summary: "Couldn't delete token data",
                                metadata: [
                                  "requestURL": endpointUrl,
                                  "tokenData": String(data: requestBody, encoding: .utf8) ?? "",
                                  "statusCode": (response as? HTTPURLResponse)?.statusCode ?? 0
                                ]
        )
      }
    }
  }

  func deleteToken(for account: Account) {
    account.getProfileDocument { profileDocument in
      guard let endpointHref = profileDocument?.linksWith(.deviceRegistration).first?.href,
            let endpointUrl = URL(string: endpointHref)
      else {
        return
      }
      Messaging.messaging().token { token, _ in
        if let token {
          self.deleteToken(token, endpointUrl: endpointUrl)
        }
      }
    }
  }
  
  // MARK: - Messaging Delegate
  
  /// Notofies that the token is updated
  public func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
    updateToken()
  }

  
  // MARK: - Notification Center Delegate Methods
  
  /// Called when app receives a notification while in foreground.
  /// Shows the notification banner and triggers a throttled sync.
  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    completionHandler([.banner, .badge, .sound])
    
    logNotificationReceived(notification.request.content, context: "foreground")
    
    // Sync with throttle to avoid redundant network calls
    // The registry already protects against concurrent syncs (.syncing state check)
    syncWithThrottle()
  }
  
  /// Called when user taps a notification to open the app.
  /// Triggers sync and navigates to Holds tab for hold-related notifications.
  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
    logNotificationReceived(response.notification.request.content, context: "tapped")
    
    let userInfo = response.notification.request.content.userInfo
    let isHoldNotification = isHoldRelatedNotification(userInfo)
    
    // Sync to fetch fresh data from server
    // Uses throttle shared with applicationDidBecomeActive to avoid duplicate syncs
    // Note: Server may send notifications before OPDS feed reflects availability
    syncWithThrottle { [weak self] errorDocument, newBooks in
      if let errorDocument = errorDocument {
        Log.error(#file, "[Notification] Sync failed: \(errorDocument)")
      } else {
        Log.info(#file, "[Notification] Sync completed. New books: \(newBooks)")
        self?.logHeldBooksState()
      }
    }
    
    // Navigate to Holds tab for hold-related notifications
    if isHoldNotification {
      Task { @MainActor in
        guard let currentAccount = AccountsManager.shared.currentAccount,
              currentAccount.details?.supportsReservations == true else {
          Log.warn(#file, "[Notification] Cannot navigate to Holds - account doesn't support reservations")
          completionHandler()
          return
        }
        
        AppTabRouterHub.shared.router?.selected = .holds
        Log.info(#file, "[Notification] Navigated to Holds tab")
        completionHandler()
      }
    } else {
    completionHandler()
    }
  }
  
  // MARK: - Sync Throttling
  
  /// Shared throttle key - same as TPPAppDelegate.syncIfUserHasHolds
  /// Ensures notification sync and foreground sync don't duplicate each other
  private static let lastSyncTimestampKey = "lastForegroundSyncTimestamp"
  private static let syncThrottleSeconds: TimeInterval = 30
  
  /// Syncs the book registry with throttling to prevent redundant network calls.
  /// Uses the same throttle as applicationDidBecomeActive to coordinate syncs.
  private func syncWithThrottle(completion: ((_ errorDocument: [AnyHashable: Any]?, _ newBooks: Bool) -> Void)? = nil) {
    // Skip if user isn't authenticated
    guard TPPUserAccount.sharedAccount().hasCredentials() else {
      completion?(nil, false)
      return
    }
    
    // Check throttle
    let lastSync = UserDefaults.standard.double(forKey: Self.lastSyncTimestampKey)
    let now = Date().timeIntervalSince1970
    
    guard (now - lastSync) > Self.syncThrottleSeconds else {
      Log.debug(#file, "[Notification Sync] Skipped - synced recently")
      completion?(nil, false)
      return
    }
    
    // Update timestamp before sync to prevent concurrent triggers
    UserDefaults.standard.set(now, forKey: Self.lastSyncTimestampKey)
    
    Log.info(#file, "[Notification Sync] Starting sync")
    TPPBookRegistry.shared.sync(completion: completion)
  }
  
  // MARK: - Notification Classification
  
  /// Determines if a notification is related to holds/reservations.
  /// Checks notification type, title, and body for hold-related keywords.
  private func isHoldRelatedNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
    // Check explicit type field from push payload
    if let type = userInfo["type"] as? String {
      return type.lowercased().contains("hold") || type.lowercased().contains("reservation")
    }
    
    // Check APS alert content for hold-related keywords
    if let aps = userInfo["aps"] as? [String: Any],
       let alert = aps["alert"] as? [String: Any] {
      let title = (alert["title"] as? String)?.lowercased() ?? ""
      let body = (alert["body"] as? String)?.lowercased() ?? ""
      let keywords = ["available", "ready", "hold", "reservation"]
      return keywords.contains { title.contains($0) || body.contains($0) }
    }
    
    // Default to hold-related to ensure proper navigation
    return true
  }
  
  // MARK: - Debug Logging
  
  /// Logs notification details for debugging
  private func logNotificationReceived(_ content: UNNotificationContent, context: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    Log.info(#file, """
      [Notification] Received (\(context)) at \(timestamp)
        Title: \(content.title)
        Body: \(content.body)
        UserInfo: \(content.userInfo)
      """)
  }
  
  /// Logs current held books state for debugging availability sync issues
  private func logHeldBooksState() {
    let heldBooks = TPPBookRegistry.shared.heldBooks
    Log.info(#file, "[Notification] Held books count: \(heldBooks.count)")
    
    for book in heldBooks {
      var status = "unknown"
      var position: UInt = 0
      
      book.defaultAcquisition?.availability.matchUnavailable(
        { _ in status = "unavailable" },
        limited: { _ in status = "limited" },
        unlimited: { _ in status = "unlimited" },
        reserved: { reserved in
          status = "reserved"
          position = reserved.holdPosition
        },
        ready: { _ in status = "READY" }
      )
      
      Log.info(#file, "[Notification] '\(book.title)' - \(status), position: \(position)")
    }
  }
  
  // MARK: - Local Hold Notifications
  
  /// Requests notification authorization from the user.
  /// Called when placing a hold so the user can receive availability notifications.
  class func requestAuthorization() {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.badge, .sound, .alert]) { granted, error in
      Log.info(#file, "Notification Authorization: granted=\(granted), error=\(error?.localizedDescription ?? "nil")")
    }
  }
  
  /// Compares cached book availability with new data to detect when a hold becomes ready.
  /// Creates a local notification if a book transitions from "reserved" to "ready".
  ///
  /// Called by `TPPBookRegistry.updateBook()` during sync. If local notifications appear
  /// before the book is actually borrowable, it indicates the server OPDS feed returned
  /// "ready" status before the book was available (server-side timing issue).
  ///
  /// - Parameters:
  ///   - cachedRecord: The previously cached book record
  ///   - newBook: The newly fetched book data
  class func compareAvailability(cachedRecord: TPPBookRegistryRecord, andNewBook newBook: TPPBook) {
    var wasOnHold = false
    var isNowReady = false
    var oldStatus = "unknown"
    var newStatus = "unknown"
    var holdPosition: UInt = 0
    
    let oldAvail = cachedRecord.book.defaultAcquisition?.availability
    oldAvail?.matchUnavailable(
      { _ in oldStatus = "unavailable" },
      limited: { _ in oldStatus = "limited" },
      unlimited: { _ in oldStatus = "unlimited" },
      reserved: { reserved in
        oldStatus = "reserved (pos: \(reserved.holdPosition))"
        holdPosition = reserved.holdPosition
        wasOnHold = true
      },
      ready: { _ in oldStatus = "ready" }
    )
    
    let newAvail = newBook.defaultAcquisition?.availability
    newAvail?.matchUnavailable(
      { _ in newStatus = "unavailable" },
      limited: { _ in newStatus = "limited" },
      unlimited: { _ in newStatus = "unlimited" },
      reserved: { reserved in newStatus = "reserved (pos: \(reserved.holdPosition))" },
      ready: { _ in
        newStatus = "ready"
        isNowReady = true
      }
    )
    
    // Log availability changes for debugging
    if oldStatus != newStatus {
      Log.info(#file, "[Hold Availability] '\(newBook.title)' changed: \(oldStatus) → \(newStatus)")
    }

    if wasOnHold && isNowReady {
      Log.info(#file, "[Hold Notification] Creating for '\(newBook.title)' - was position \(holdPosition), now ready")
      createNotificationForReadyCheckout(book: newBook)
    }
  }
  
  /// Updates the app icon badge to show the count of holds ready to borrow.
  /// Called after sync to reflect current ready-to-borrow count.
  ///
  /// - Parameter heldBooks: Array of books currently on hold
  class func updateAppIconBadge(heldBooks: [TPPBook]) {
    var readyCount = 0
    for book in heldBooks {
      book.defaultAcquisition?.availability.matchUnavailable(
        nil,
        limited: nil,
        unlimited: nil,
        reserved: nil,
        ready: { _ in readyCount += 1 }
      )
    }
    if UIApplication.shared.applicationIconBadgeNumber != readyCount {
      UIApplication.shared.applicationIconBadgeNumber = readyCount
    }
  }
  
  /// Determines if a background fetch is needed based on held books count.
  /// Skips expensive network operations if user has no holds.
  ///
  /// - Returns: `true` if the user has held books and should fetch updates
  class func backgroundFetchIsNeeded() -> Bool {
    let count = TPPBookRegistry.shared.heldBooks.count
    Log.info(#file, "[Background Fetch] Held books: \(count)")
    return count > 0
  }
  
  /// Creates a local notification when a hold becomes ready to checkout.
  ///
  /// - Parameter book: The book that is now ready to borrow
  private class func createNotificationForReadyCheckout(book: TPPBook) {
    let center = UNUserNotificationCenter.current()
    center.getNotificationSettings { settings in
      guard settings.authorizationStatus == .authorized else { return }

      let content = UNMutableNotificationContent()
      content.title = Strings.UserNotifications.downloadReady
      content.body = NSLocalizedString("The title you reserved, \(book.title), is available.", comment: "")
      content.sound = UNNotificationSound.default
      content.categoryIdentifier = HoldNotificationCategoryIdentifier
      content.userInfo = ["bookID": book.identifier]

      let request = UNNotificationRequest(
        identifier: book.identifier,
        content: content,
        trigger: nil
      )
      
      center.add(request) { error in
        if let error = error {
          TPPErrorLogger.logError(
            error as NSError,
            summary: "Error creating notification for ready checkout",
            metadata: ["book": book.loggableDictionary()]
          )
        }
      }
    }
  }
}
