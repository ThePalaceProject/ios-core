//
//  MyBooksSimplifiedBearerToken.swift
//  Palace
//
//  Created by Maurice Carrier on 6/13/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

class MyBooksSimplifiedBearerToken {
  var accessToken: String
  var expiration: Date
  var location: URL
  
  init(accessToken: String, expiration: Date, location: URL) {
    self.accessToken = accessToken
    self.expiration = expiration
    self.location = location
  }
  
  static func simplifiedBearerToken(with dictionary: [String: Any]) -> MyBooksSimplifiedBearerToken? {
    guard let locationString = dictionary["location"] as? String,
          let location = URL(string: locationString),
          let accessToken = dictionary["access_token"] as? String,
          let expirationNumber = dictionary["expiration"] as? Int else {
      return nil
    }
    
    let expirationSeconds = expirationNumber > 0 ? expirationNumber : Int(Date.distantFuture.timeIntervalSinceNow)
    let expiration = Date(timeIntervalSinceNow: TimeInterval(expirationSeconds))
    
    return MyBooksSimplifiedBearerToken(accessToken: accessToken, expiration: expiration, location: location)
  }
}
