import Foundation

/// A small Swift adapter over the Obj-C++ AdobeDRMServiceBridge.
actor AdobeDRMBridge {
  static let shared = AdobeDRMBridge()
  private let bridge = AdobeDRMServiceBridge.shared()

  func authorize(userID: String, password: String) async throws {
    try await withCheckedThrowingContinuation { cont in
      bridge.authorizeDevice(
        withUserID: userID,
        password: password
      ) { success, error in
        if success {
          cont.resume()
        } else {
          cont.resume(throwing: error ?? NSError(
            domain: "com.myapp.drm",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Unknown DRM error"]
          ))
        }
      }
    }
  }

  func fulfill(acsmData: Data, userID: String, deviceID: String) async throws -> URL {
    try await withCheckedThrowingContinuation { cont in
      bridge.fulfill(
        withACSMData: acsmData,
        tag: "",          // you can pass through a tag if you like
        userID: userID,
        deviceID: deviceID
      ) { success, error in
        if success {
          // AdobeDRMServiceBridge currently doesn’t hand you back a URL
          // in the completion block, but you can peek at its delegate callback
          // or extend its API.  For now just say “done.”
          cont.resume(returning: URL(fileURLWithPath: ""))
        } else {
          cont.resume(throwing: error!)
        }
      }
    }
  }

  func returnLoan(loanID: String, userID: String, deviceID: String) async throws {
    try await withCheckedThrowingContinuation { cont in
      bridge.returnLoan(
        withID: loanID,
        userID: userID,
        deviceID: deviceID
      ) { success, error in
        if success {
          cont.resume()
        } else {
          cont.resume(throwing: error!)
        }
      }
    }
  }
}
