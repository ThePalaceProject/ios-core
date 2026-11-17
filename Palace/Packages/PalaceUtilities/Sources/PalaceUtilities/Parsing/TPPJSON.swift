import Foundation

func TPPJSONDataFromObject(_ object: Any) -> Data? {
  return try? JSONSerialization.data(withJSONObject: object, options: [])
}

public func TPPJSONObjectFromData(_ data: Data) -> Any? {
  return try? JSONSerialization.jsonObject(with: data, options: [])
}
