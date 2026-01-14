//
//  TPPUserAccountMock.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 10/14/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
@testable import Palace

class TPPUserAccountMock: TPPUserAccount {
  private static var shared = TPPUserAccountMock()
  override class func sharedAccount(libraryUUID: String?) -> TPPUserAccount {
    return shared
  }

  // MARK:- Variable redefinitions to avoid keychain

  var _authDefinition: AccountDetails.Authentication?
  override var authDefinition: AccountDetails.Authentication? {
    get {
      return _authDefinition
    }
    set {
      _authDefinition = newValue
    }
  }

  var _credentials: TPPCredentials?
  override var credentials: TPPCredentials? {
    get {
      return _credentials
    }
    set {
      _credentials = newValue
    }
  }

  private var _authorizationIdentifier: String?
  override var authorizationIdentifier: String? {
    return _authorizationIdentifier
  }
  override func setAuthorizationIdentifier(_ identifier: String) {
    _authorizationIdentifier = identifier
  }

  private var _deviceID: String?
  override var deviceID: String? {
    return _deviceID
  }
  override func setDeviceID(_ newValue: String) {
    _deviceID = newValue
  }

  private var _userID: String?
  override var userID: String? {
    return _userID
  }
  override func setUserID(_ newValue: String) {
    _userID = newValue
  }

  private var _adobeVendor: String?
  override var adobeVendor: String? {
    return _adobeVendor
  }
  override func setAdobeVendor(_ newValue: String) {
    _adobeVendor = newValue
  }

  private var _provider: String?
  override var provider: String? {
    return _provider
  }
  override func setProvider(_ newValue: String) {
    _provider = newValue
  }

  private var _patron: [String: Any]?
  override var patron: [String: Any]? {
    return _patron
  }
  override func setPatron(_ newValue: [String: Any]) {
    _patron = newValue
  }

  private var _adobeToken: String?
  override var adobeToken: String? {
    return _adobeToken
  }
  override func setAdobeToken(_ newValue: String) {
    _adobeToken = newValue
  }
  override func setAdobeToken(_ token: String, patron: [String : Any]) {
    _adobeToken = token
    _patron = patron
  }

  private var _licensor: [String: Any]?
  override var licensor: [String: Any]? {
    return _licensor
  }
  override func setLicensor(_ newValue: [String: Any]) {
    _licensor = newValue
  }

  private var _cookies: [HTTPCookie]?
  override var cookies: [HTTPCookie]? {
    return _cookies
  }
  override func setCookies(_ newValue: [HTTPCookie]) {
    _cookies = newValue
  }

  override var legacyAuthToken: String? {
    return nil
  }

  private var _authToken: String?
  override var authToken: String? {
    return _authToken
  }

  override func setAuthToken(_ token: String, barcode: String?, pin: String?, expirationDate: Date?) {
    _authToken = token
  }
  
  // MARK: - Auth State
  
  private var _authState: TPPAccountAuthState = .loggedOut
  override var authState: TPPAccountAuthState {
    // If we have credentials but state is loggedOut, derive loggedIn state
    if _authState == .loggedOut && hasCredentials() {
      return .loggedIn
    }
    return _authState
  }
  
  override func setAuthState(_ state: TPPAccountAuthState) {
    _authState = state
  }
  
  override func markCredentialsStale() {
    guard authState == .loggedIn else { return }
    _authState = .credentialsStale
  }
  
  override func markLoggedIn() {
    _authState = .loggedIn
  }

  // MARK:- Clean everything up
  
  override func removeAll() {
    _adobeToken = nil
    _patron = nil
    _adobeVendor = nil
    _provider = nil
    _userID = nil
    _deviceID = nil
    _authDefinition = nil
    _authToken = nil
    _credentials = nil
    _cookies = nil
    _authorizationIdentifier = nil
    _authState = .loggedOut
  }
}
