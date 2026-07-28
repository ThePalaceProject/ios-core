//
//  TPPBookLocation.swift
//  Palace
//
//  Created by Vladimir Fedorov on 09.11.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

public typealias TPPBookLocationData = [String: Any]

public extension TPPBookLocationData {
    func string(for key: TPPBookLocationKey) -> String? {
        return self[key.rawValue] as? String
    }
}

public enum TPPBookLocationKey: String {
    case locationString = "locationString"
    case renderer = "renderer"
}

public class TPPBookLocation: NSObject {

    /// Due to differences in how different renderers (e.g. Readium, RMSDK, et cetera) want to handle
    /// location information, it is necessary to store location information in an unstructured manner.
    /// When creating an instance of this class, |locationString| is the renderer-specific data and
    /// `renderer` is a string that uniquely identifies the renderer that generated it. When loading a
    /// location, renderers can inspect `renderer` to ensure the location string they're about to use is
    /// compatible with their underlying systems.
    public var locationString: String

    // Renderer
    public var renderer: String

    public init?(locationString: String, renderer: String) {
        self.locationString = locationString
        self.renderer = renderer
    }
    public init?(dictionary: [String: Any]) {
        let locationData = dictionary as TPPBookLocationData
        guard let locationString = locationData.string(for: .locationString),
              let renderer = locationData.string(for: .renderer)
        else {
            return nil
        }
        self.locationString = locationString
        self.renderer = renderer
    }
    public var dictionaryRepresentation: [String: Any] {
        return [
            TPPBookLocationKey.locationString.rawValue: self.locationString,
            TPPBookLocationKey.renderer.rawValue: self.renderer
        ]
    }
}

extension TPPBookLocation {
    public func locationStringDictionary() -> [String: Any]? {
        guard let data = locationString.data(using: .utf8),
              let dictionary = try? JSONSerialization.jsonObject(with: data, options: .allowFragments) as? [String: Any]
        else { return nil }
        return dictionary
    }

    public func isSimilarTo(_ location: TPPBookLocation) -> Bool {
        guard renderer == location.renderer,
              let locationDict = locationStringDictionary(),
              let otherLocationDict = location.locationStringDictionary() else {
            return false
        }
        let excludedKeys = ["timeStamp", "annotationId"]
        let filteredDict = locationDict.filter { !excludedKeys.contains($0.key) }
        let filteredOtherDict = otherLocationDict.filter { !excludedKeys.contains($0.key) }
        return NSDictionary(dictionary: filteredDict).isEqual(to: filteredOtherDict)
    }
}
