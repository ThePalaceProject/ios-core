//
//  TPPBackgroundExecutor.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 2/6/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import UIKit
import Dispatch

/**
 Protocol that should be implemented by a class that wants to schedule work
 in the background using `TPPBackgroundExecutor`.
 */
@objc protocol NYPLBackgroundWorkOwner {
  /// Implementors should do 2 things:
  ///
  /// 1. Create the work item.
  /// If you're calling this function from ObjC, the work item must be
  /// created via `dispatch_block_create` to avoid undefined
  /// behavior (see docs for `dispatch_block_cancel()`).
  ///
  /// 2. Invoke the `backgroundWork` block parameter from inside the work item.
  ///
  /// E.g.:
  /// ```objc
  /// - (dispatch_block_t)setUpWorkItemWrappingBackgroundWork:(void(^)(void))backgroundWork
  /// {
  ///   dispatch_block_t workItem = dispatch_block_create(0, ^{
  ///     backgroundWork();
  ///   });
  ///   return workItem;
  /// }
  /// ```
  ///
  /// Then when used in conjunction with `TPPBackgroundExecutor`,
  /// `TPPBackgroundExecutor::dispatchBackgroundWork()` will call
  /// `setUpWorkItem(wrapping:)` at the right time. The executor takes
  /// care of starting and ending the background task for you,
  /// performing the appropriate logging.
  ///
  /// - Parameter backgroundWork: The block that the owning class should invoke
  /// from inside the work-item / dispatch-block it created.
  ///
  /// - Returns: The created work item. Callers are not required to retain
  /// this since it will be retained TPPBackgroundExecutor's queue.
  ///
  @objc(setUpWorkItemWrappingBackgroundWork:)
  func setUpWorkItem(wrapping backgroundWork: @escaping () -> Void) -> (() -> Void)?

  /// The actual expensive / long running work. Don't add any background task
  /// handling in here!
  func performBackgroundWork()
}

/**
 This class wraps the logic of initiating and ending a background task on behalf
 of a `owner` in a thread-safe manner.

 The work defined in `NYPLBackgroundWorkOwner::performBackgroundWork` is
 executed concurrently on the global background queue with the assumption that
 it is thread-safe.
 */
@objc class TPPBackgroundExecutor: NSObject {
  private let taskName: String
  private weak var owner: NYPLBackgroundWorkOwner?
  private let queue = DispatchQueue.global(qos: .background)
  private let endLock = NSLock()
  private var isEndingTask = false
  
  //----------------------------------------------------------------------------

  /// - Parameters:
  ///   - owner: The object wanting to run an expensive task in the background.
  ///   - taskName: A name for the task, for debugging/logging purposes.
  @objc init(owner: NYPLBackgroundWorkOwner, taskName: String) {
    self.taskName = taskName
    self.owner = owner
    super.init()
  }
  
  //----------------------------------------------------------------------------

  /// The owner needs to call this function to perform in the background the
  ///  work specified in `NYPLBackgroundWorkOwner::performBackgroundWork`.
  /// All the mechanics of starting and ending a background task (including
  /// the related logging) are handled here.
  @objc func dispatchBackgroundWork() {
    var bgTask: UIBackgroundTaskIdentifier = .invalid

    let endQueue = DispatchQueue(label: "com.thepalaceproject.backgroundEndQueue", qos: .userInitiated)

    func endTaskIfNeeded(context: String) {
      endQueue.async { [weak self] in
        guard let self = self else { return }
        
        self.endLock.lock()
        defer { self.endLock.unlock() }
        
        // Prevent multiple end task calls
        if self.isEndingTask {
          return
        }
        self.isEndingTask = true
        
        let timeRemaining: TimeInterval = DispatchQueue.main.sync {
          UIApplication.shared.backgroundTimeRemaining
        }

        Log.info(#file, """
          \(context) \(self.taskName) background task \(bgTask.rawValue). \
          Time remaining: \(timeRemaining)
          """)

        if bgTask != .invalid {
          UIApplication.shared.endBackgroundTask(bgTask)
          bgTask = .invalid
        }
        
        self.isEndingTask = false
      }
    }

    let startBackground: () -> Void = {
      bgTask = UIApplication.shared.beginBackgroundTask(withName: self.taskName) {
        endTaskIfNeeded(context: "Expiring")
      }

      Log.debug(#file, "Beginning \(self.taskName) background task \(bgTask.rawValue)")

      if bgTask == .invalid {
        Log.warn(#file, "Unable to run background task \(self.taskName)")
      }

      guard let workItem = self.owner?.setUpWorkItem(wrapping: { [weak self] in
        self?.owner?.performBackgroundWork()

        endTaskIfNeeded(context: "Finishing up")
      }) else {
        Log.warn(#file,
                 "No work item for \(self.taskName) background task \(bgTask.rawValue)!")
        endTaskIfNeeded(context: "No work item")
        return
      }

      self.queue.async(execute: workItem)
    }

    if Thread.isMainThread {
      startBackground()
    } else {
      DispatchQueue.main.async(execute: startBackground)
    }
  }
}
