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
  
  /// Called when the app is in foreground
  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    // Shows notification banner on screen
    completionHandler([.banner, .badge, .sound])
    // Update loans
    TPPBookRegistry.shared.sync()
  }
  
  /// Called when the user responded to the notification by opening the application, dismissing the notification or choosing a UNNotificationAction
  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
    completionHandler()
    // Update loans
    TPPBookRegistry.shared.sync()
  }
}
