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
    guard let data = try? retrieveData(for: url.anyURL.string) else {
      return nil
    }

    return DataResource(data: self.decode(data, at: url.anyURL.string), sourceURL: url.absoluteURL)
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

    guard let entry = archive[path] else {
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
#endif
