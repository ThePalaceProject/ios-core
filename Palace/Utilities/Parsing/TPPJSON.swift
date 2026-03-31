import Foundation

@objc func TPPJSONDataFromObject(_ object: Any) -> Data? {
  return try? JSONSerialization.data(withJSONObject: object, options: [])
}

@objc func TPPJSONObjectFromData(_ data: Data) -> Any? {
  return try? JSONSerialization.jsonObject(with: data, options: [])
}
