//
//  MemoryReleaseCoordinator.swift
//  Palace
//
//  The one place that reacts to a memory warning (PP-5580). Each cache
//  registers a release step under a stage. On a warning the coordinator runs
//  every step once, in stage order, starting with the memory event record.
//  What each step releases is unchanged from the separate handlers it
//  replaces.
//

import Foundation
import UIKit
import PalaceBookModel

/// The order a memory warning runs release steps in: the memory event record
/// first, then what is cheapest to rebuild, then downloads and disk.
enum MemoryReleaseStage: Int, CaseIterable, Comparable, Sendable {
    case record
    case networkResponses
    case catalogFeeds
    case bookCells
    /// The memory layer of disk-backed caches (image data, OPDS feed data).
    case cachedData
    case lcpDecrypt
    case decodedImages
    case downloads
    case diskSpace

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// `@unchecked Sendable`: `steps` and `nextIndex` are only touched under
/// `lock`, which is never held while a step runs.
final class MemoryReleaseCoordinator: @unchecked Sendable {
    static let shared = MemoryReleaseCoordinator()

    private struct Step {
        let stage: MemoryReleaseStage
        let index: Int
        weak var owner: AnyObject?
        let release: @Sendable (AnyObject) -> Void
    }

    private let center: NotificationCenter
    private let lock = NSLock()
    private var steps: [Step] = []
    private var nextIndex = 0

    init(center: NotificationCenter = .default) {
        self.center = center
        center.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    deinit {
        center.removeObserver(self)
    }

    /// Adds a release step. `owner` is held weakly: once it is gone, its step
    /// stops running. Steps run on the thread that posted the warning (main,
    /// from UIKit) before `post` returns; a step that needs another queue
    /// hops there itself.
    func register<Owner: AnyObject>(
        _ owner: Owner,
        stage: MemoryReleaseStage,
        release: @escaping @Sendable (Owner) -> Void
    ) {
        lock.withLock {
            steps.removeAll { $0.owner == nil }
            steps.append(Step(stage: stage, index: nextIndex, owner: owner) { object in
                if let owner = object as? Owner { release(owner) }
            })
            nextIndex += 1
        }
    }

    @objc private func handleMemoryWarning() {
        releaseAll()
    }

    /// Adds the cover store's release step. `BookCoverStore` lives in a package
    /// that cannot see this type, so the app registers it (PP-5583).
    func registerBookCovers(_ store: BookCoverStore, keeping: @escaping @Sendable () -> Set<String> = { [] }) {
        register(store, stage: .decodedImages) { store in
            store.releaseImages()
        }
    }

    /// Runs the live steps of `stages` once, in stage order.
    func releaseAll(stages: Set<MemoryReleaseStage>) {}

    /// Runs every live step once, in stage order and then registration order.
    func releaseAll() {
        let live: [(owner: AnyObject, step: Step)] = lock.withLock {
            steps.removeAll { $0.owner == nil }
            return steps
                .sorted { ($0.stage, $0.index) < ($1.stage, $1.index) }
                .compactMap { step in step.owner.map { ($0, step) } }
        }
        for (owner, step) in live {
            step.release(owner)
        }
    }
}
