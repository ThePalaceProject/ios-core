//
//  TPPCredentials.swift
//  The Palace Project
//
//  Created by Jacek Szyja on 22/05/2020.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
import WebKit

enum TPPCredentials {
  case token(authToken: String, barcode: String?  = nil, pin: String? = nil)
  case barcodeAndPin(barcode: String, pin: String)
  case cookies([HTTPCookie])
}

extension TPPCredentials: Codable {
  // warning, order is important for proper decoding!
  enum TypeID: Int, Codable {
    case token
    case barcodeAndPin
    case cookies
  }

  private var typeID: TypeID {
    switch self {
    case .token: return .token
    case .barcodeAndPin: return .barcodeAndPin
    case .cookies: return .cookies
    }
  }

  enum CodingKeys: String, CodingKey {
    case type
    case associatedTokenData
    case associatedBarcodeAndPinData
    case associatedCookiesData
  }

  enum TokenKeys: String, CodingKey {
    case authToken
  }

  enum BarcodeAndPinKeys: String, CodingKey {
    case barcode
    case pin
  }

  enum CookiesKeys: String, CodingKey {
    case cookiesData
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let type = try values.decode(TypeID.self, forKey: .type)

    switch type {
    case .token:
      let additionalInfo = try values.nestedContainer(keyedBy: TokenKeys.self, forKey: .associatedTokenData)
      let token = try additionalInfo.decode(String.self, forKey: .authToken)
      
      let barcodePinInfo = try values.nestedContainer(keyedBy: BarcodeAndPinKeys.self, forKey: .associatedBarcodeAndPinData)
      let barcode = try barcodePinInfo.decode(String.self, forKey: .barcode)
      let pin = try barcodePinInfo.decode(String.self, forKey: .pin)

      self = .token(authToken: token, barcode: barcode, pin: pin)

    case .barcodeAndPin:
      let additionalInfo = try values.nestedContainer(keyedBy: BarcodeAndPinKeys.self, forKey: .associatedBarcodeAndPinData)
      let barcode = try additionalInfo.decode(String.self, forKey: .barcode)
      let pin = try additionalInfo.decode(String.self, forKey: .pin)
      self = .barcodeAndPin(barcode: barcode, pin: pin)

    case .cookies:
      let additionalInfo = try values.nestedContainer(keyedBy: CookiesKeys.self, forKey: .associatedCookiesData)
      let cookiesData = try additionalInfo.decode(Data.self, forKey: .cookiesData)
      guard let properties = try JSONSerialization.jsonObject(with: cookiesData, options: .allowFragments) as? [[HTTPCookiePropertyKey : Any]] else {
        throw NSError()
      }
      let cookies = properties.compactMap { HTTPCookie(properties: $0) }
      self = .cookies(cookies)
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(typeID, forKey: .type)

    switch self {
    case let .token(authToken: token, barcode: barcode, pin: pin):
      var additionalInfo = container.nestedContainer(keyedBy: TokenKeys.self, forKey: .associatedTokenData)
      try additionalInfo.encode(token, forKey: .authToken)
      
      var barCodePinInfo = container.nestedContainer(keyedBy: BarcodeAndPinKeys.self, forKey: .associatedBarcodeAndPinData)
      try barCodePinInfo.encode(barcode, forKey: .barcode)
      try barCodePinInfo.encode(pin, forKey: .pin)

    case let .barcodeAndPin(barcode: barcode, pin: pin):
      var additionalInfo = container.nestedContainer(keyedBy: BarcodeAndPinKeys.self, forKey: .associatedBarcodeAndPinData)
      try additionalInfo.encode(barcode, forKey: .barcode)
      try additionalInfo.encode(pin, forKey: .pin)

    case let .cookies(cookies):
      var additionalInfo = container.nestedContainer(keyedBy: CookiesKeys.self, forKey: .associatedCookiesData)
      let properties: [[HTTPCookiePropertyKey : Any]] = cookies.compactMap { $0.properties }
      let data = try JSONSerialization.data(withJSONObject: properties, options: [])
      try additionalInfo.encode(data, forKey: .cookiesData)
    }
  }
}

extension String {
  func asKeychainVariable<VariableType>(with accountInfoLock: NSRecursiveLock) -> TPPKeychainVariable<VariableType> {
    return TPPKeychainVariable<VariableType>(key: self, accountInfoLock: accountInfoLock)
  }

  func asKeychainCodableVariable<VariableType: Codable>(with accountInfoLock: NSRecursiveLock) -> TPPKeychainCodableVariable<VariableType> {
    return TPPKeychainCodableVariable<VariableType>(key: self, accountInfoLock: accountInfoLock)
  }
}
