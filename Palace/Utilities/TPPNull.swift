// Swift replacement for TPPNull.m
//
// Converts between nil and NSNull for ObjC interop.

import Foundation

/// Returns NSNull if object is nil, otherwise returns the object.
@objc func TPPNullFromNil(_ object: Any?) -> Any {
  return object ?? NSNull()
}

/// Returns nil if object is NSNull, otherwise returns the object.
@objc func TPPNullToNil(_ object: Any?) -> Any? {
  return object is NSNull ? nil : object
}
