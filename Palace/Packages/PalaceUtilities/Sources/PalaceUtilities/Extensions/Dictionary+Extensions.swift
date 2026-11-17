//
//  Dictionary+Extensions.swift
//  Palace
//
//  Created by Maurice Carrier on 6/16/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

extension Dictionary {
    public func mapKeys<T>(_ transform: (Key) throws -> T) rethrows -> [T: Value] {
        var dictionary = [T: Value]()
        for (key, value) in self {
            dictionary[try transform(key)] = value
        }
        return dictionary
    }
}
