//
//  AdobeDRMContentProtection.swift
//  The Palace Project
//
//  Created by Vladimir Fedorov on 20.01.2021.
//  Copyright © 2021 NYPL Labs. All rights reserved.
//

#if FEATURE_DRM_CONNECTOR

import Foundation
// `@preconcurrency`: ReadiumShared's `Resource` protocol requirements
// (`stream(consume:)`, `properties() -> ReadResult<ResourceProperties>`) are not
// Sendable-audited, so the `DRMDataResource` actor witnessing them crosses
// non-Sendable types owned by that module. Downgrading module-origin Sendable
// diagnostics here is the idiomatic fix until Readium ships a concurrency-audited
// API; DRMDataResource stays an `actor` — no behavior change.
@preconcurrency import ReadiumShared
import ReadiumZIPFoundation

final class AdobeDRMContentProtection: ContentProtection, Loggable {

    func open(
        asset: Asset,
        credentials: String?,
        allowUserInteraction: Bool,
        sender: Any?
    ) async -> Result<ContentProtectionAsset, ContentProtectionOpenError> {

        guard asset.format.conformsTo(.adept) else {
            return .failure(.assetNotSupported(DebugError("The asset is not protected by Adobe DRM")))
        }

        guard case .container(let container) = asset else {
            return .failure(.assetNotSupported(DebugError("Only local file assets are supported with Adobe DRM")))
        }

        return await parseEncryptionData(in: container.container)
            .mapError { ContentProtectionOpenError.reading(.decoding($0)) }
            .asyncFlatMap { encryptionData in
                guard let sourceURL = container.container.sourceURL?.url else {
                    return .failure(.assetNotSupported(DebugError("Invalid source URL")))
                }

                let decryptedContainer = AdobeDRMContainer(url: sourceURL, encryptionData: encryptionData)

                // iPad-on-Mac watchdog-exit guard (WS-4): mark that Adobe DRM is
                // being exercised this session. Every ungated RMSDK op that can
                // construct Adobe's faulting static recursive_mutex (decode,
                // displayUntilDate license-read, init → GPFile::lock) runs inside
                // an AdobeDRMContainer method, and EVERY AdobeDRMContainer is
                // created here (the sole `.adept` content-protection entry; the
                // gated AdobeDRMService/NYPLADEPT fulfillment path does not run on
                // iPad-on-Mac). Marking at construction therefore dominates all
                // mutex-constructing paths and precedes any of them. The actual
                // atexit{_exit(0)} interceptor is installed later, at
                // applicationDidEnterBackground, only when this flag is set.
                AdobeDRMService.markAdobeDRMUsed()

                let newContainerAsset = ContainerAsset(container: decryptedContainer, format: container.format)
                let cpAsset = ContentProtectionAsset(asset: .container(newContainerAsset)) { manifest, _, services in
                    let copyManifest = manifest

                    services.setContentProtectionServiceFactory { factory in
                        AdobeContentProtectionService(
                            context: PublicationServiceContext(
                                publication: factory.publication,
                                manifest: copyManifest,
                                container: decryptedContainer
                            )
                        )
                    }
                }

                return .success(cpAsset)
            }
    }
}

extension Container {
    func url(forEntryPath path: String) -> AnyURL? {
        entries.first { $0.string == path }
    }
}

private extension AdobeDRMContentProtection {

    private func parseEncryptionData(in container: Container) async -> Result<Data, Error> {
        let pathsToTry = ["META-INF/encryption.xml"]

        for path in pathsToTry {
            guard let resourceURL = container.url(forEntryPath: path),
                  let resource = container[resourceURL] else {
                log(.debug, "Failed to resolve resource at path: \(path)")
                continue
            }

            if let encryptionData = try? await resource.read().get() {
                return .success(encryptionData)
            }
        }

        return .failure(DebugError("Invalid encryption.xml path"))
    }
}

// Swift 6 `complete`: `@unchecked Sendable`. `AdobeDRMContainer` (Obj-C) is passed
// into the `DRMDataResource` actor and captured by the `@Sendable` async bridge in
// the `Container` subscript. Its one hot operation — `decodeData:at:` — is fully
// serialized in the `.mm` behind `@synchronized(acsdrm_lock)`. The `epubDecodingError`
// / `displayUntilDate` properties are NOT lock-covered, but they are accessed only
// during single-threaded publication *open* (service-factory construction), which
// completes before the lazy `decodeData:at:` decrypt path (invoked during *reading*)
// ever runs — i.e. sequenced, not concurrent. So sharing the instance across
// concurrency domains introduces no unsynchronized *concurrent* access. (Follow-up:
// `acsdrm_lock` is reassigned per-init in the `.mm` — track making it a
// `dispatch_once` immutable. Non-blocking, pre-existing.) Precedent:
// `AdobeDRMService` in `AdobeCertificate.swift`.
extension AdobeDRMContainer: @unchecked Sendable {}

extension AdobeDRMContainer: Container {

    public var sourceURL: AbsoluteURL? {
        guard let fileURL else { return nil }
        return FileURL(url: fileURL)
    }

    public var entries: Set<AnyURL> {
        guard let resourcePaths = listPathsFromArchive() else {
            return []
        }

        return Set(resourcePaths.compactMap { AnyURL(string: $0) })
    }

    public subscript(url: any URLConvertible) -> Resource? {
        let path = url.anyURL.string

        let data: Data? = {
            // Swift 6 `complete`: the completion runs on a background queue (a
            // `@Sendable` closure), so the result is carried out through the
            // lock-backed `SyncDataBridge` box rather than a captured mutable `var`.
            // The semaphore still provides the synchronous wait; behavior unchanged.
            let bridge = SyncDataBridge()
            let semaphore = DispatchSemaphore(value: 0)
            self.retrieveDataSynchronously(for: path) { retrievedData in
                bridge.complete(with: retrievedData)
                semaphore.signal()
            }
            semaphore.wait()
            return bridge.data
        }()

        guard let data else {
            return nil
        }

        return DRMDataResource(encryptedData: data, path: path, drmContainer: self, sourceURL: sourceURL)
    }

    private func retrieveDataSynchronously(for path: String, completion: @escaping @Sendable (Data?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let runLoop = CFRunLoopGetCurrent()
            // Swift 6 `complete`: the async-bridge result + done-flag are shared
            // between the `@Sendable` `Task` (writer) and this run-loop-pumping
            // closure (reader), so they cannot be captured as plain local `var`s.
            // The lock-backed `SyncDataBridge` box is the single serialization
            // point; behavior (spin the run loop until the Task finishes or the
            // 10s cap elapses, then hand the data back) is unchanged.
            let bridge = SyncDataBridge()
            Task {
                let data = try? await self.retrieveData(for: path)
                bridge.complete(with: data)
                CFRunLoopStop(runLoop)
            }

            while !bridge.isCompleted {
                CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.1, false)

                if Date() > Date(timeIntervalSinceNow: 10) {
                    break
                }
            }

            completion(bridge.data)
        }
    }

    // MARK: - Helpers
    /// Retrieves encrypted data for the resource at a given path.
    private func retrieveData(for path: String) async throws -> Data {
        guard let rawData = try await readDataFromArchive(at: path) else {
            throw DebugError("Failed to locate resource at path: \(path)")
        }
        return rawData
    }

    private func listPathsFromArchive() -> [String]? {
        return ["META-INF/container.xml", "OEBPS/content.opf"]
    }

    private func readDataFromArchive(at path: String) async throws -> Data? {
        guard let fileURL else { return nil }
        let archive = try await Archive(url: fileURL, accessMode: .read)

        guard let entry = try await archive.get(path) else {
            return nil
        }

        do {
            var data = Data()
            _ = try await archive.extract(entry, consumer: { data.append($0) })
            return data
        } catch {
            return nil
        }
    }
}

/// A DRM-enabled Resource that decrypts (decodes) its data once and then serves
/// range requests (to support pagination) using the cached decrypted data.
public actor DRMDataResource: Resource {
    public let sourceURL: AbsoluteURL?

    private let encryptedData: Data
    private let path: String
    private let drmContainer: AdobeDRMContainer

    // Cache for the decrypted data once computed.
    private var _decryptedData: ReadResult<Data>?

    /// Initializes the resource with the encrypted data and related DRM container.
    public init(encryptedData: Data, path: String, drmContainer: AdobeDRMContainer, sourceURL: AbsoluteURL? = nil) {
        self.encryptedData = encryptedData
        self.path = path
        self.drmContainer = drmContainer
        self.sourceURL = sourceURL
    }

    /// Returns the decrypted data, caching it after the first decryption.
    private func decryptedData() async -> ReadResult<Data> {
        if let cached = _decryptedData {
            return cached
        }
        let decrypted = drmContainer.decode(encryptedData, at: path)
        let result: ReadResult<Data> = .success(decrypted)
        _decryptedData = result
        return result
    }

    public func read(range: Range<UInt64>?) async throws -> Data {
        let fullData = try await decryptedData().get()
        if let range = range {
            let start = Int(range.lowerBound)
            let end = Int(range.upperBound)
            let intRange = start..<end
            guard intRange.lowerBound >= 0, intRange.upperBound <= fullData.count else {
                throw ReadError.access(.fileSystem(.fileNotFound(nil)))
            }
            return fullData.subdata(in: intRange)
        }
        return fullData
    }

    // `nonisolated`: the `Streamable.stream(range:consume:)` requirement declares
    // `consume` as a plain `@escaping (Data) -> Void` (NOT `@Sendable`), so the
    // witness cannot strengthen it to `@Sendable` — function parameters are
    // contravariant and Readium passes a non-Sendable closure. Marking the witness
    // `nonisolated` removes the actor-isolation boundary the closure would otherwise
    // be *sent* across (the Swift 6 error), keeping the closure in the caller's
    // domain. Decryption is unchanged: the actual decrypt + cache still happens on
    // the actor inside the isolated `read(range:)` helper we `await` below; only the
    // `consume` callback now runs in this nonisolated async context, which is where
    // the Streamable contract expects callers to accumulate chunks anyway.
    public nonisolated func stream(range: Range<UInt64>?, consume: @escaping (Data) -> Void) async -> ReadResult<Void> {
        do {
            let chunk = try await read(range: range)
            consume(chunk)
            return .success(())
        } catch {
            return .failure(.access(.other(error)))
        }
    }

    public func properties() async -> ReadResult<ResourceProperties> {
        let fullData = try? await decryptedData().get()
        var props = ResourceProperties()
        props.length = fullData.map { UInt64($0.count) }
        return .success(props)
    }

    public func estimatedLength() async -> ReadResult<UInt64?> {
        let fullData = try? await decryptedData().get()
        return .success(fullData.map { UInt64($0.count) })
    }
}

extension ResourceProperties {
    public var length: UInt64? {
        // Readium 3.9.0: ResourceProperties values must be JSONValueEncodable
        // *and* JSONValueDecodable. UInt64 is only Encodable, so persist as Int
        // (which conforms to both) and bridge to UInt64 at this typed accessor.
        get {
            let value: Int? = self["length"]
            return value.map(UInt64.init)
        }
        set { self["length"] = newValue.map { Int($0) } }
    }
}

/// Lock-backed carrier for the async→sync bridge in `AdobeDRMContainer`'s
/// `Container` subscript.
///
/// Swift 6 `complete`: replaces the mutable local `var retrievedData` / `var
/// isCompleted` that were shared between the `@Sendable` `Task` (the writer) and
/// the run-loop / semaphore reader. `@unchecked Sendable` is honest because every
/// field access is serialized by `lock`. `complete(with:)` is idempotent-safe:
/// the bridge is used for exactly one round trip per subscript call.
private final class SyncDataBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var _data: Data?
    private var _isCompleted = false

    var data: Data? {
        lock.lock(); defer { lock.unlock() }
        return _data
    }

    var isCompleted: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isCompleted
    }

    func complete(with data: Data?) {
        lock.lock(); defer { lock.unlock() }
        _data = data
        _isCompleted = true
    }
}

#endif
