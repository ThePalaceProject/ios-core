//
//  MockSyncBackend.swift
//  PalaceTests
//
//  In-memory annotation backend for cross-device sync E2E tests.
//
//  Serves the Palace annotation protocol (LD+JSON `AnnotationCollection`)
//  over a single endpoint. Two TPPNetworkExecutor instances pointing at
//  this backend simulate two devices on the same patron account.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Foundation
@testable import Palace

/// Single-process annotation server. Stores annotations keyed by their
/// server-assigned URL ID, lets test code:
///   1. POST a new annotation (server assigns an ID, returns the canonical body)
///   2. GET the full annotation collection for a book
///   3. DELETE an annotation by URL ID
///   4. Force a server-wins conflict by directly mutating state out of band
///
/// Thread-safe; all mutations and reads go through `queue`.
final class MockSyncBackend {

    // MARK: - Stored annotation

    struct StoredAnnotation: Equatable {
        let id: String
        let bookID: String
        let motivation: String
        let device: String
        let time: String
        let selectorValue: String
        let chapterTitle: String
        let progressWithinBook: Double
    }

    // MARK: - State

    /// Base URL the backend answers on. POST goes to this URL; the assigned
    /// annotation ID is `<baseURL>/<uuid>`. GET on `baseURL` returns the
    /// AnnotationCollection. DELETE on the assigned ID removes it.
    let baseURL: URL

    private let queue = DispatchQueue(label: "MockSyncBackend.queue")
    private var annotations: [String: StoredAnnotation] = [:]

    private(set) var postCount: Int = 0
    private(set) var getCount: Int = 0
    private(set) var deleteCount: Int = 0

    init(baseURL: URL = URL(string: "https://mock.library.test/annotations/")!) {
        self.baseURL = baseURL
    }

    // MARK: - Direct state manipulation (for setup / server-wins simulation)

    /// Insert a server-side annotation without going through POST. Used by
    /// tests that want to seed "what device A wrote" or "what the server
    /// already has" before another device reads.
    func seed(_ annotation: StoredAnnotation) {
        queue.sync {
            annotations[annotation.id] = annotation
        }
    }

    /// Replace an annotation by ID. Used in conflict tests to overwrite an
    /// in-flight client write with the canonical server value.
    func replace(id: String, with annotation: StoredAnnotation) {
        queue.sync {
            annotations[id] = annotation
        }
    }

    func allAnnotations(forBook bookID: String) -> [StoredAnnotation] {
        queue.sync {
            return annotations.values
                .filter { $0.bookID == bookID }
                .sorted { $0.time < $1.time }
        }
    }

    func clear() {
        queue.sync {
            annotations.removeAll()
            postCount = 0
            getCount = 0
            deleteCount = 0
        }
    }

    // MARK: - Request handling

    /// Resolve a `URLRequest` to a stubbed response. Plug this into
    /// `HTTPStubURLProtocol.register`.
    ///
    /// Matches any URL whose path contains `/annotations/` — the real
    /// production code derives `TPPAnnotations.annotationsURL` from
    /// `TPPConfiguration.mainFeedURL()` (which points at the live DPLA
    /// host in the test environment), not from the test's mock URL. Rather
    /// than mutate global TPPConfiguration, we intercept any annotation
    /// traffic and serve it from our in-memory store.
    func handle(_ request: URLRequest) -> HTTPStubURLProtocol.StubbedResponse? {
        guard let url = request.url else { return nil }

        let path = url.path
        let looksLikeAnnotationCollection = path.hasSuffix("/annotations/") || path.hasSuffix("/annotations")
        let looksLikeAnnotationID = path.contains("/annotations/") && !looksLikeAnnotationCollection
        guard looksLikeAnnotationCollection || looksLikeAnnotationID else { return nil }

        switch request.httpMethod ?? "GET" {
        case "GET":
            return handleGET(forBook: bookFilter(from: url))
        case "POST":
            return handlePOST(body: request.bodyData, postedTo: url)
        case "DELETE":
            return handleDELETE(id: url.absoluteString)
        default:
            return HTTPStubURLProtocol.StubbedResponse(statusCode: 405, headers: nil, body: nil)
        }
    }

    // MARK: - GET (return collection)

    private func bookFilter(from url: URL) -> String? {
        // Tests can pass `?book=<id>` to scope the response. Default: return
        // everything (matches the real server's per-patron-not-per-book layout).
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return comps?.queryItems?.first(where: { $0.name == "book" })?.value
    }

    private func handleGET(forBook bookFilter: String?) -> HTTPStubURLProtocol.StubbedResponse {
        let items: [[String: Any]] = queue.sync {
            getCount += 1
            return annotations.values
                .filter { bookFilter == nil || $0.bookID == bookFilter }
                .sorted { $0.time < $1.time }
                .map { storedAnnotationToServerJSON($0) }
        }

        let envelope: [String: Any] = [
            "@context": "http://www.w3.org/ns/anno.jsonld",
            "total": items.count,
            "type": "AnnotationCollection",
            "first": [
                "items": items,
                "type": "AnnotationPage"
            ]
        ]
        let data = try? JSONSerialization.data(withJSONObject: envelope, options: [])
        return HTTPStubURLProtocol.StubbedResponse(statusCode: 200,
                                                   headers: ["Content-Type": "application/json"],
                                                   body: data)
    }

    // MARK: - POST (create + return server-assigned ID)

    private func handlePOST(body: Data?, postedTo url: URL) -> HTTPStubURLProtocol.StubbedResponse {
        guard let body = body,
              let raw = try? JSONSerialization.jsonObject(with: body, options: []),
              let json = raw as? [String: Any] else {
            return HTTPStubURLProtocol.StubbedResponse(statusCode: 400, headers: nil, body: nil)
        }

        let bookID = extractBookID(from: json) ?? "unknown"
        let motivation = (json[TPPBookmarkSpec.Motivation.key] as? String) ?? ""
        let bodyDict = (json[TPPBookmarkSpec.Body.key] as? [String: Any]) ?? [:]
        let device = (bodyDict[TPPBookmarkSpec.Body.Device.key] as? String) ?? ""
        let time = (bodyDict[TPPBookmarkSpec.Body.Time.key] as? String) ?? ISO8601DateFormatter().string(from: Date())
        let chapter = (bodyDict[TPPBookmarkSpec.Body.ChapterTitle.key] as? String) ?? ""
        let progress = (bodyDict[TPPBookmarkSpec.Body.ProgressWithinBook.key] as? Double) ?? 0.0
        let selectorValue = extractSelectorValue(from: json) ?? "{}"

        // Assigned ID is rooted at the URL the client posted to, so a
        // subsequent DELETE on the ID hits a URL the production code can
        // build (it uses the server-returned `id` string verbatim).
        let prefix = url.absoluteString.hasSuffix("/")
            ? url.absoluteString
            : url.absoluteString + "/"
        let assignedID = prefix + UUID().uuidString
        let stored = StoredAnnotation(
            id: assignedID,
            bookID: bookID,
            motivation: motivation,
            device: device,
            time: time,
            selectorValue: selectorValue,
            chapterTitle: chapter,
            progressWithinBook: progress
        )

        queue.sync {
            postCount += 1
            annotations[assignedID] = stored
        }

        let responseJSON: [String: Any] = [
            TPPBookmarkSpec.Id.key: assignedID,
            TPPBookmarkSpec.Body.key: [
                TPPBookmarkSpec.Body.Time.key: time
            ]
        ]
        let data = try? JSONSerialization.data(withJSONObject: responseJSON, options: [])
        return HTTPStubURLProtocol.StubbedResponse(statusCode: 200,
                                                   headers: ["Content-Type": "application/json"],
                                                   body: data)
    }

    // MARK: - DELETE

    private func handleDELETE(id: String) -> HTTPStubURLProtocol.StubbedResponse {
        let existed: Bool = queue.sync {
            deleteCount += 1
            let had = annotations[id] != nil
            annotations.removeValue(forKey: id)
            return had
        }
        let code = existed ? 200 : 404
        return HTTPStubURLProtocol.StubbedResponse(statusCode: code, headers: nil, body: nil)
    }

    // MARK: - JSON helpers

    private func storedAnnotationToServerJSON(_ s: StoredAnnotation) -> [String: Any] {
        return [
            TPPBookmarkSpec.Id.key: s.id,
            "@context": "http://www.w3.org/ns/anno.jsonld",
            "type": "Annotation",
            TPPBookmarkSpec.Motivation.key: s.motivation,
            TPPBookmarkSpec.Body.key: [
                TPPBookmarkSpec.Body.Time.key: s.time,
                TPPBookmarkSpec.Body.Device.key: s.device,
                TPPBookmarkSpec.Body.ChapterTitle.key: s.chapterTitle,
                TPPBookmarkSpec.Body.ProgressWithinBook.key: s.progressWithinBook
            ],
            TPPBookmarkSpec.Target.key: [
                TPPBookmarkSpec.Target.Source.key: s.bookID,
                TPPBookmarkSpec.Target.Selector.key: [
                    TPPBookmarkSpec.Target.Selector.type.key: TPPBookmarkSpec.Target.Selector.type.value,
                    TPPBookmarkSpec.Target.Selector.Value.key: s.selectorValue
                ]
            ]
        ]
    }

    private func extractBookID(from json: [String: Any]) -> String? {
        let target = json[TPPBookmarkSpec.Target.key] as? [String: Any]
        return target?[TPPBookmarkSpec.Target.Source.key] as? String
    }

    private func extractSelectorValue(from json: [String: Any]) -> String? {
        guard let target = json[TPPBookmarkSpec.Target.key] as? [String: Any],
              let selector = target[TPPBookmarkSpec.Target.Selector.key] as? [String: Any] else {
            return nil
        }
        return selector[TPPBookmarkSpec.Target.Selector.Value.key] as? String
    }
}

// MARK: - URLRequest body extraction
//
// URLRequest.httpBody is nil when the body comes from an InputStream (which
// is what URLSession does for stubbed posts). Read from httpBodyStream as a
// fallback so we can inspect what the executor actually sent.
extension URLRequest {
    var bodyData: Data? {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}
