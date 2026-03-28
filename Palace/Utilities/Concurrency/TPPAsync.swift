// Swift replacement for TPPAsync.m
//
// Convenience wrapper for dispatching to a global background queue.

import Foundation

/// Dispatches a block asynchronously on the default-priority global queue.
func TPPAsyncDispatchSwift(_ block: @escaping () -> Void) {
  DispatchQueue.global(qos: .default).async(execute: block)
}
