//
//  StreamingReaderProgressStore.swift
//  Palace
//
//  PP-4161: per-book scroll/fragment persistence for the streaming-media
//  reader. UserDefaults-backed by default; protocol-fronted so tests
//  inject a fake without hitting the standard defaults.
//

import CoreGraphics
import Foundation

/// Round-tripped payload stored per book under
/// `palace.streamingReader.progress.<bookID>`.
public struct StreamingReaderProgress: Codable, Equatable {
    public let scrollOffset: CGFloat
    public let fragment: String?

    public init(scrollOffset: CGFloat, fragment: String?) {
        self.scrollOffset = scrollOffset
        self.fragment = fragment
    }
}

/// Persistence seam injected into `StreamingReaderViewModel`. Tests use
/// `FakeStreamingReaderProgressStore` to record calls and pre-seed reads.
public protocol StreamingReaderProgressStoring: AnyObject {
    func save(scrollOffset: CGFloat, fragment: String?, forBookID bookID: String)
    func read(forBookID bookID: String) -> StreamingReaderProgress?
}

/// Default implementation backed by `UserDefaults`. Key prefix is namespaced
/// so we don't collide with arbitrary keys elsewhere in the app and the
/// `<bookID>` segment scopes reads/writes per title.
public final class StreamingReaderProgressStore: StreamingReaderProgressStoring {

    private static let keyPrefix = "palace.streamingReader.progress."

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func save(scrollOffset: CGFloat, fragment: String?, forBookID bookID: String) {
        let progress = StreamingReaderProgress(scrollOffset: scrollOffset, fragment: fragment)
        do {
            let data = try JSONEncoder().encode(progress)
            userDefaults.set(data, forKey: Self.keyPrefix + bookID)
        } catch {
            // Encoding a Codable struct of (CGFloat, String?) should never
            // fail under normal conditions. Swallow to avoid crashing the
            // reader dismiss path; the user simply loses this save.
        }
    }

    public func read(forBookID bookID: String) -> StreamingReaderProgress? {
        let key = Self.keyPrefix + bookID
        guard let data = userDefaults.data(forKey: key) else {
            return nil
        }
        return try? JSONDecoder().decode(StreamingReaderProgress.self, from: data)
    }
}
