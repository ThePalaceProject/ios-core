import Foundation

let DownloadingKey = "downloading"
let DownloadFailedKey = "download-failed"
let DownloadNeededKey = "download-needed"
let DownloadSuccessfulKey = "download-successful"
let UnregisteredKey = "unregistered"
let HoldingKey = "holding"
let UsedKey = "used"
let UnsupportedKey = "unsupported"
let ReturningKey = "returning"
let SAMLStartedKey = "saml-started"

// MARK: - TPPBookState

@objc public enum TPPBookState: Int, CaseIterable {
  case unregistered = 0
  case downloadNeeded = 1
  case downloading
  case downloadFailed
  case downloadSuccessful
  case returning
  case holding
  case used
  case unsupported
  // This state means that user is logged using SAML environment and app begun download process, but didn't transition to download center yet
  case SAMLStarted

  init?(_ stringValue: String) {
    switch stringValue {
    case DownloadingKey:
      self = .downloading
    case DownloadFailedKey:
      self = .downloadFailed
    case DownloadNeededKey:
      self = .downloadNeeded
    case DownloadSuccessfulKey:
      self = .downloadSuccessful
    case UnregisteredKey:
      self = .unregistered
    case HoldingKey:
      self = .holding
    case UsedKey:
      self = .used
    case UnsupportedKey:
      self = .unsupported
    case SAMLStartedKey:
      self = .SAMLStarted
    default:
      return nil
    }
  }

  func stringValue() -> String {
    switch self {
    case .downloading:
      DownloadingKey
    case .downloadFailed:
      DownloadFailedKey
    case .downloadNeeded:
      DownloadNeededKey
    case .downloadSuccessful:
      DownloadSuccessfulKey
    case .unregistered:
      UnregisteredKey
    case .holding:
      HoldingKey
    case .used:
      UsedKey
    case .unsupported:
      UnsupportedKey
    case .returning:
      ReturningKey
    case .SAMLStarted:
      SAMLStartedKey
    }
  }
}

// MARK: - TPPBookStateHelper

// For Objective-C, since Obj-C enum is not allowed to have methods
// TODO: Remove when migration to Swift completed
class TPPBookStateHelper: NSObject {
  @objc(stringValueFromBookState:)
  static func stringValue(from state: TPPBookState) -> String {
    state.stringValue()
  }

  @objc(bookStateFromString:)
  static func bookState(fromString string: String) -> NSNumber? {
    guard let state = TPPBookState(string) else {
      return nil
    }

    return NSNumber(integerLiteral: state.rawValue)
  }

  @objc static func allBookStates() -> [TPPBookState.RawValue] {
    TPPBookState.allCases.map(\.rawValue)
  }
}
