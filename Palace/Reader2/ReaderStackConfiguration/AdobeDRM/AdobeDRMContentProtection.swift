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
import ZIPFoundation

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

    guard let data = try? retrieveData(for: path) else {
      return nil
    }

    // **Decryption strategy**
    let fullyDecryptedFiles = Set(["content.opf", "nav.xhtml", "toc.ncx", "encryption.xml"])
    let imageExtensions = Set(["jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff"])

    if fullyDecryptedFiles.contains(where: { path.hasSuffix($0) }) {
      return DataResource(data: self.decode(data, at: path), sourceURL: url.absoluteURL)
    }

    if let fileExtension = path.split(separator: ".").last,
       imageExtensions.contains(String(fileExtension)) {
      return DataResource(data: self.decode(data, at: path), sourceURL: url.absoluteURL)
    }

    return DRMResource(data: data, path: path, drmContainer: self)
  }

  // MARK: - Helpers
  /// Retrieves encrypted data for the resource at a given path.
  private func retrieveData(for path: String) throws -> Data {
    guard let rawData = readDataFromArchive(at: path) else {
      throw DebugError("Failed to locate resource at path: \(path)")
    }
    return rawData
  }

  private func listPathsFromArchive() -> [String]? {
    return ["META-INF/container.xml", "OEBPS/content.opf"]
  }

  private func readDataFromArchive(at path: String) -> Data? {
    guard let fileURL, let archive = try? Archive(url: fileURL, accessMode: .read, pathEncoding: nil) else {
      return nil
    }

    guard let entry = archive.first(where: { $0.path == path }) else {
      return nil
    }

    do {
      var data = Data()
      _ = try archive.extract(entry, consumer: { data.append($0) })
      return data
    } catch {
      return nil
    }
  }
}

// MARK: - DRMResource (Efficient Data Handling)
struct DRMResource: Resource {
  private let data: Data
  private let path: String
  private let drmContainer: AdobeDRMContainer

  init(data: Data, path: String, drmContainer: AdobeDRMContainer) {
    self.data = data
    self.path = path
    self.drmContainer = drmContainer
  }

  func read(range: Range<UInt64>?) async throws -> Data {
    let fullData = drmContainer.decode(data, at: path)

    if let range = range {
      let start = Int(clamping: range.lowerBound)
      let end = Int(clamping: range.upperBound)
      let intRange = start..<end

      guard intRange.lowerBound >= 0, intRange.upperBound <= fullData.count else {
        throw ReadError.access(.fileSystem(.fileNotFound(nil)))
      }

      return fullData.subdata(in: intRange)
    } else {
      return fullData
    }
  }

  var sourceURL: AbsoluteURL? {
    nil
  }

  func properties() async -> ReadResult<ResourceProperties> {
    var props = ResourceProperties()
    props.length = UInt64(data.count)
    return .success(props)
  }

  func estimatedLength() async -> ReadResult<UInt64?> {
    return .success(UInt64(data.count))
  }

  func stream(range: Range<UInt64>?, consume: @escaping (Data) -> Void) async -> ReadResult<Void> {
    do {
      let chunk = try await read(range: range)
      consume(chunk)
      return .success(())
    } catch {
      return .failure(.access(.other(error)))
    }
  }

  func close() {}
}

// MARK: - ResourceProperties Extension
extension ResourceProperties {
  public var length: UInt64? {
    get { self["length"] }
    set { self["length"] = newValue }
  }
}
#endif
