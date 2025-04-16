import Foundation

let DownloadingKey = "downloading"
let DownloadFailedKey = "download-failed"
let DownloadNeededKey = "download-needed"
let DownloadSuccessfulKey = "download-successful"
let UnregisteredKey = "unregistered"
let HoldingKey = "holding"
let UsedKey = "used"
let UnsupportedKey = "unsupported"
let SAMLStartedKey = "saml-started"

@objc public enum TPPBookState : Int, CaseIterable {
  case unregistered = 0
  case downloadNeeded = 1
  case downloading
  case downloadFailed
  case downloadSuccessful
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
        return DownloadingKey;
      case .downloadFailed:
        return DownloadFailedKey;
      case .downloadNeeded:
        return DownloadNeededKey;
      case .downloadSuccessful:
        return DownloadSuccessfulKey;
      case .unregistered:
        return UnregisteredKey;
      case .holding:
        return HoldingKey;
      case .used:
        return UsedKey;
      case .unsupported:
        return UnsupportedKey;
    case .SAMLStarted:
      return SAMLStartedKey;
    }
  }
}

// For Objective-C, since Obj-C enum is not allowed to have methods
// TODO: Remove when migration to Swift completed
class TPPBookStateHelper : NSObject {
  @objc(stringValueFromBookState:)
  static func stringValue(from state: TPPBookState) -> String {
    return state.stringValue()
  }
    
  @objc(bookStateFromString:)
  static func bookState(fromString string: String) -> NSNumber? {
    guard let state = TPPBookState(string) else {
      return nil
    }

    return NSNumber(integerLiteral: state.rawValue)
  }
    
  @objc static func allBookStates() -> [TPPBookState.RawValue] {
    return TPPBookState.allCases.map{ $0.rawValue }
  }
}

