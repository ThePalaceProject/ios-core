import Foundation

/// Serializes an object to JSON data. Returns nil on failure.
func TPPJSONDataFromObject(_ object: Any) -> Data? {
  return try? JSONSerialization.data(withJSONObject: object, options: [])
}

/// Deserializes JSON data to a Foundation object. Returns nil on failure.
func TPPJSONObjectFromData(_ data: Data) -> Any? {
  return try? JSONSerialization.jsonObject(with: data, options: [])
}
