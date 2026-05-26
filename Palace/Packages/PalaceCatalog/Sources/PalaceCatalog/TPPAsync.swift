import Foundation

/// Equivalent to using dispatch_async with the default global priority queue.
public func TPPAsyncDispatch(_ block: @escaping () -> Void) {
  DispatchQueue.global(qos: .default).async(execute: block)
}
