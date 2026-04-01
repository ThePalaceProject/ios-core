import Foundation

func TPPNullFromNil(_ object: Any?) -> Any {
  return object ?? NSNull()
}

func TPPNullToNil(_ object: Any?) -> Any? {
  if object is NSNull {
    return nil
  }
  return object
}
