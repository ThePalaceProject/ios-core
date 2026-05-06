import Foundation

/// Wrapper for null conversion utilities.
public final class TPPNullHelper: NSObject {

  /// Converts nil to NSNull for use in collections that don't accept nil.
  public static func fromNil(_ object: Any?) -> Any {
    return object ?? NSNull()
  }

  /// Converts NSNull back to nil.
  public static func toNil(_ object: Any?) -> Any? {
    if object is NSNull {
      return nil
    }
    return object
  }
}

/// Converts nil to NSNull for use in collections that don't accept nil.
public func TPPNullFromNil(_ object: Any?) -> Any {
  return TPPNullHelper.fromNil(object)
}

/// Converts NSNull back to nil.
public func TPPNullToNil(_ object: Any?) -> Any? {
  return TPPNullHelper.toNil(object)
}
