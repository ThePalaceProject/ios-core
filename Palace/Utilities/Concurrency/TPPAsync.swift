import Foundation

/// ObjC-accessible wrapper for async dispatch.
@objcMembers
class TPPAsyncHelper: NSObject {

  /// Dispatches a block asynchronously on the default global queue.
  static func dispatch(_ block: @escaping () -> Void) {
    DispatchQueue.global(qos: .default).async(execute: block)
  }
}

/// Dispatches a block asynchronously on the default global queue.
/// Equivalent to dispatch_async with DISPATCH_QUEUE_PRIORITY_DEFAULT.
func TPPAsyncDispatch(_ block: @escaping () -> Void) {
  TPPAsyncHelper.dispatch(block)
}
