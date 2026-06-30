//
//  URL+Extensions.swift
//  Palace
//
//  Created by Vladimir Fedorov on 12/05/2023.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

extension URL {
    func replacingScheme(with scheme: String) -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        components.scheme = scheme
        return components.url ?? self
    }

    /// Returns the URL with the given query item set to `value`: any existing
    /// items with the same `name` are removed and a single `name=value` item is
    /// appended. All other query items are preserved in order.
    func settingQueryItem(name: String, value: String) -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        var items = (components.queryItems ?? []).filter { $0.name != name }
        items.append(URLQueryItem(name: name, value: value))
        components.queryItems = items
        return components.url ?? self
    }
}
