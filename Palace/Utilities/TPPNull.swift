import Foundation

@objc func TPPNullFromNil(_ object: Any?) -> Any {
  return object ?? NSNull()
}

@objc func TPPNullToNil(_ object: Any?) -> Any? {
  if object is NSNull {
    return nil
  }
  return object
}
