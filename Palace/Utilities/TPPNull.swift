import Foundation

/// ObjC-accessible wrapper for null conversion utilities.
@objcMembers
class TPPNullHelper: NSObject {

  /// Converts nil to NSNull for use in collections that don't accept nil.
  static func fromNil(_ object: Any?) -> Any {
    return object ?? NSNull()
  }

  /// Converts NSNull back to nil.
  static func toNil(_ object: Any?) -> Any? {
    if object is NSNull {
      return nil
    }
    return object
  }
}

/// Converts nil to NSNull for use in collections that don't accept nil.
func TPPNullFromNil(_ object: Any?) -> Any {
  return TPPNullHelper.fromNil(object)
}

/// Converts NSNull back to nil.
func TPPNullToNil(_ object: Any?) -> Any? {
  return TPPNullHelper.toNil(object)
}
