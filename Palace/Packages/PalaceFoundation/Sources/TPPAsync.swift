import Foundation

/// Helper for async dispatch.
public final class TPPAsyncHelper: NSObject {

  /// Dispatches a block asynchronously on the default global queue.
  public static func dispatch(_ block: @escaping () -> Void) {
    DispatchQueue.global(qos: .default).async(execute: block)
  }
}

/// Dispatches a block asynchronously on the default global queue.
/// Equivalent to dispatch_async with DISPATCH_QUEUE_PRIORITY_DEFAULT.
public func TPPAsyncDispatch(_ block: @escaping () -> Void) {
  TPPAsyncHelper.dispatch(block)
}
