//
//  ResponseHeaderProcessor.swift
//  Palace
//
//  Created by Maurice Carrier on 6/19/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

class ResponseHeaderProcessor {
  func processHeaders(_ headers: [String: String]) {
    let scope = getHeaderValue(forKey: "x-overdrive-scope", in: headers) ?? getHeaderValue(forKey: "X-Overdrive-Scope", in: headers)
    let patronAuthorization = getHeaderValue(forKey: "x-overdrive-patron-authorization", in: headers) ?? getHeaderValue(forKey: "X-Overdrive-Patron-Authorization", in: headers)
    let location = getHeaderValue(forKey: "location", in: headers) ?? getHeaderValue(forKey: "Location", in: headers)
    
    // Process the extracted values as needed
    if let scope = scope, let patronAuthorization = patronAuthorization, let location = location {
      // Do something with the extracted values
      print("Scope: \(scope), Patron Authorization: \(patronAuthorization), Location: \(location)")
    }
  }
  
  private func getHeaderValue(forKey key: String, in headers: [String: String]) -> String? {
    return headers[key]
  }
}
