import UserNotifications

let HoldNotificationCategoryIdentifier = "NYPLHoldToReserveNotificationCategory"
let CheckOutActionIdentifier = "NYPLCheckOutNotificationAction"
let DefaultActionIdentifier = "UNNotificationDefaultActionIdentifier"

@objcMembers class TPPUserNotifications: NSObject
{
  typealias DisplayStrings = Strings.UserNotifications
  private let unCenter = UNUserNotificationCenter.current()

  /// If a user has not yet been presented with Notifications authorization,
  /// defer the presentation for later to maximize acceptance rate. Otherwise,
  /// Apple documents authorization to be preformed at app-launch to correctly
  /// enable the delegate.
  func authorizeIfNeeded()
  {
    unCenter.delegate = self
    unCenter.getNotificationSettings { (settings) in
      if settings.authorizationStatus == .notDetermined {
      } else {
        self.registerNotificationCategories()
        TPPUserNotifications.requestAuthorization()
      }
    }
  }

  class func requestAuthorization()
  {
    let unCenter = UNUserNotificationCenter.current()
    unCenter.requestAuthorization(options: [.badge,.sound,.alert]) { (granted, error) in
      Log.info(#file, "Notification Authorization Results: 'Granted': \(granted)." +
        " 'Error': \(error?.localizedDescription ?? "nil")")
    }
  }

  /// Create a local notification if a book has moved from the "holds queue" to
  /// the "reserved queue", and is available for the patron to checkout.
  class func compareAvailability(cachedRecord:TPPBookRegistryRecord, andNewBook newBook:TPPBook)
  {
    var wasOnHold = false
    var isNowReady = false
    let oldAvail = cachedRecord.book.defaultAcquisition?.availability
    oldAvail?.matchUnavailable(nil,
                               limited: nil,
                               unlimited: nil,
                               reserved: { _ in wasOnHold = true },
                               ready: nil)
    let newAvail = newBook.defaultAcquisition?.availability
    newAvail?.matchUnavailable(nil,
                               limited: nil,
                               unlimited: nil,
                               reserved: nil,
                               ready: { _ in isNowReady = true })

    if (wasOnHold && isNowReady) {
      createNotificationForReadyCheckout(book: newBook)
    }
  }

  /// Updates the app icon badge to show the count of holds ready to borrow.
  /// Called after background refresh to update badge even when app is not in foreground.
  class func updateAppIconBadge(heldBooks: [TPPBook]) {
    var readyBooks = 0
    for book in heldBooks {
      book.defaultAcquisition?.availability.matchUnavailable(nil,
                                                               limited: nil,
                                                               unlimited: nil,
                                                               reserved: nil,
                                                               ready: { _ in readyBooks += 1 })
    }
    if UIApplication.shared.applicationIconBadgeNumber != readyBooks {
      UIApplication.shared.applicationIconBadgeNumber = readyBooks
    }
  }
  
  /// Depending on which Notificaitons are supported, only perform an expensive
  /// network operation if it's needed.
  class func backgroundFetchIsNeeded() -> Bool {
    Log.info(#file, "[backgroundFetchIsNeeded] Held Books: \(TPPBookRegistry.shared.heldBooks.count)")
    return TPPBookRegistry.shared.heldBooks.count > 0
  }

  private class func createNotificationForReadyCheckout(book: TPPBook)
  {
    let unCenter = UNUserNotificationCenter.current()
    unCenter.getNotificationSettings { (settings) in
      guard settings.authorizationStatus == .authorized else { return }

      let title = DisplayStrings.downloadReady
      let content = UNMutableNotificationContent()
      content.body = NSLocalizedString("The title you reserved, \(book.title), is available.", comment: "")
      content.title = title
      content.sound = UNNotificationSound.default
      content.categoryIdentifier = HoldNotificationCategoryIdentifier
      content.userInfo = ["bookID" : book.identifier]

      let request = UNNotificationRequest.init(identifier: book.identifier,
                                               content: content,
                                               trigger: nil)
      unCenter.add(request) { error in
        if let error = error {
          TPPErrorLogger.logError(error as NSError,
                                   summary: "Error creating notification for ready checkout",
                                   metadata: ["book": book.loggableDictionary()])
        }
      }
    }
  }

  private func registerNotificationCategories()
  {
    let checkOutNotificationAction = UNNotificationAction(identifier: CheckOutActionIdentifier,
                                                          title: DisplayStrings.checkoutTitle,
                                                          options: [])
    let holdToReserveCategory = UNNotificationCategory(identifier: HoldNotificationCategoryIdentifier,
                                                       actions: [checkOutNotificationAction],
                                                       intentIdentifiers: [],
                                                       options: [])
    UNUserNotificationCenter.current().setNotificationCategories([holdToReserveCategory])
  }
}

@available(iOS 10.0, *)
extension TPPUserNotifications: UNUserNotificationCenterDelegate
{
  func userNotificationCenter(_ center: UNUserNotificationCenter,
                              willPresent notification: UNNotification,
                              withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void)
  {
    completionHandler([.alert])
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter,
                              didReceive response: UNNotificationResponse,
                              withCompletionHandler completionHandler: @escaping () -> Void)
  {
    if response.actionIdentifier == DefaultActionIdentifier {
      guard let currentAccount = AccountsManager.shared.currentAccount else {
        Log.error(#file, "Error moving to Holds tab from notification; there was no current account.")
        completionHandler()
        return
      }

      if currentAccount.details?.supportsReservations == true {
        Task { @MainActor in
          AppTabRouterHub.shared.router?.selected = .holds
        }
      }
      completionHandler()
    }
    else if response.actionIdentifier == CheckOutActionIdentifier {
      let userInfo = response.notification.request.content.userInfo
      let downloadCenter = MyBooksDownloadCenter.shared

      guard let bookID = userInfo["bookID"] as? String else {
        completionHandler()
        return
      }
      guard let book = TPPBookRegistry.shared.book(forIdentifier: bookID) else {
          completionHandler()
          return
      }

      borrow(book, inBackgroundFrom: downloadCenter, completion: completionHandler)
    }
    else {
      completionHandler()
    }
  }

  private func borrow(_ book: TPPBook,
                      inBackgroundFrom downloadCenter: MyBooksDownloadCenter,
                      completion: @escaping () -> Void) {
    var bgTask: UIBackgroundTaskIdentifier = .invalid
    bgTask = UIApplication.shared.beginBackgroundTask {
      if bgTask != .invalid {
        Log.warn(#file, "Expiring background borrow task \(bgTask.rawValue)")
        completion()
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
      }
    }

    Task {
      do {
        _ = try await downloadCenter.borrowAsync(book, attemptDownload: false)
      } catch {
        Log.error(#file, "Background borrow failed: \(error.localizedDescription)")
      }
      
      completion()
      guard bgTask != .invalid else {
        return
      }
      UIApplication.shared.endBackgroundTask(bgTask)
      bgTask = .invalid
    }
  }
}
