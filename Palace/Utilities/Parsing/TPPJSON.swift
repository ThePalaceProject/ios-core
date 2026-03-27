// Swift replacement for TPPJSON.m
//
// Convenience wrappers around JSONSerialization.

import Foundation

/// Serializes a JSON-compatible object to Data, returning nil on failure.
@objc func TPPJSONDataFromObject(_ object: Any) -> Data? {
  return try? JSONSerialization.data(withJSONObject: object, options: [])
}

/// Deserializes Data into a JSON object, returning nil on failure.
@objc func TPPJSONObjectFromData(_ data: Data) -> Any? {
  return try? JSONSerialization.jsonObject(with: data, options: [])
}
