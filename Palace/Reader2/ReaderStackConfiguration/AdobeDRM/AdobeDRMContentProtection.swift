//
//  AdobeDRMContentProtection.swift
//  The Palace Project
//
//  Created by Vladimir Fedorov on 20.01.2021.
//  Copyright © 2021 NYPL Labs. All rights reserved.
//

#if FEATURE_DRM_CONNECTOR

import Foundation
import ReadiumShared
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
      var result: Data?
      let semaphore = DispatchSemaphore(value: 0)
      self.retrieveDataSynchronously(for: path) { retrievedData in
        result = retrievedData
        semaphore.signal()
      }
      semaphore.wait()
      return result
    }()

    guard let data else {
      return nil
    }

    return DRMDataResource(encryptedData: data, path: path, drmContainer: self, sourceURL: sourceURL)
  }

  private func retrieveDataSynchronously(for path: String, completion: @escaping (Data?) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
      let runLoop = CFRunLoopGetCurrent()
      var retrievedData: Data?
      var isCompleted = false
      Task {
        do {
          retrievedData = try await self.retrieveData(for: path)
        } catch {
          retrievedData = nil
        }

        isCompleted = true
        CFRunLoopStop(runLoop)
      }

      while !isCompleted {
        CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.1, false)

        if Date() > Date(timeIntervalSinceNow: 10) {
          break
        }
      }

      completion(retrievedData)
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

  public func stream(range: Range<UInt64>?, consume: @escaping (Data) -> Void) async -> ReadResult<Void> {
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
    get { self["length"] }
    set { self["length"] = newValue }
  }
}

#endif
