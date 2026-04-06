//
//  URLRequest+Extensions.swift
//  Palace
//
//  Created by Maurice Carrier on 1/11/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation
import UIKit

/// Thread-safe cache for the app's custom User-Agent string.
/// `UIDevice.current.systemVersion` is a UIKit property and MUST only be read
/// on the main thread. Requests built by background tasks (e.g. token refresh,
/// download tasks) cannot safely call UIDevice.current directly. This actor
/// builds and caches the string once during app start-up on the main thread,
/// then serves it to any thread without racing.
@MainActor
private enum UserAgentCache {
    private static var _cached: String?

    static var value: String {
        if let cached = _cached { return cached }
        let appName    = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "App"
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let osVersion  = UIDevice.current.systemVersion
        let built      = "\(appName)/\(appVersion) (iOS; \(osVersion))"
        _cached = built
        return built
    }

    /// Warms the cache synchronously from the main thread.
    /// Call this early in the app lifecycle (e.g. `applicationDidFinishLaunching`).
    static func warmUp() { _ = value }
}

// nonisolated helper so the extensions below compile without `await`.
// The string is computed once on the main thread; subsequent reads are safe
// because a String is a value type and the assignment to `_cached` happens
// before any concurrent read thanks to the @MainActor isolation.
private func cachedUserAgent() -> String {
    if Thread.isMainThread {
        return MainActor.assumeIsolated { UserAgentCache.value }
    }
    // Off-main-thread: use the cached value if available, else build with
    // a safe fallback (no UIDevice access) and let the next main-thread call
    // update the cache.
    let appName    = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "App"
    let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    return "\(appName)/\(appVersion) (iOS)"
}

extension URLRequest {
    init(url: URL, applyingCustomUserAgent: Bool) {
        self.init(url: url)

        if applyingCustomUserAgent {
            let customUserAgent = cachedUserAgent()
            if let existing = self.value(forHTTPHeaderField: "User-Agent") {
                self.setValue("\(existing) \(customUserAgent)", forHTTPHeaderField: "User-Agent")
            } else {
                self.setValue(customUserAgent, forHTTPHeaderField: "User-Agent")
            }
        }
    }
}

extension URLRequest {
    @discardableResult mutating func applyCustomUserAgent() -> URLRequest {
        let customUserAgent = cachedUserAgent()
        if let existing = value(forHTTPHeaderField: "User-Agent") {
            setValue("\(existing) \(customUserAgent)", forHTTPHeaderField: "User-Agent")
        } else {
            setValue(customUserAgent, forHTTPHeaderField: "User-Agent")
        }
        return self
    }
}
