import Foundation

let NYPLOverdriveDomain = "OverdriveAPI"

@objc enum NYPLOverdriveErrorCode: Int {
  // Network
  case nilHTTPResponse = 100
  case authorizationFail = 101
  case nilData = 102
  case parseJsonFail = 103
  case invalidResponseHeader = 104
  case parseTokenError = 105
  case invalidToken = 106
}
