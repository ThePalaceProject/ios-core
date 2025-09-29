//
//  URLRequest+Extensions.swift
//  Palace
//
//  Created by Maurice Carrier on 1/11/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

extension URLRequest {
  init(url: URL, applyingCustomUserAgent: Bool) {
    self.init(url: url)

    if applyingCustomUserAgent {
      let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "App"
      let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
      let customUserAgent = "\(appName)/\(appVersion) (iOS; \(UIDevice.current.systemVersion))"

      if let existingUserAgent = value(forHTTPHeaderField: "User-Agent") {
        setValue("\(existingUserAgent) \(customUserAgent)", forHTTPHeaderField: "User-Agent")
      } else {
        setValue(customUserAgent, forHTTPHeaderField: "User-Agent")
      }
    }
  }
}

extension URLRequest {
  @discardableResult mutating func applyCustomUserAgent() -> URLRequest {
    let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "App"
    let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    let customUserAgent = "\(appName)/\(appVersion) (iOS; \(UIDevice.current.systemVersion))"

    if let existingUserAgent = value(forHTTPHeaderField: "User-Agent") {
      setValue("\(existingUserAgent) \(customUserAgent)", forHTTPHeaderField: "User-Agent")
    } else {
      setValue(customUserAgent, forHTTPHeaderField: "User-Agent")
    }

    return self
  }
}
