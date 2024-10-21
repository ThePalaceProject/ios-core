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

    var mutableAsset = asset

    guard case var .container(container) = mutableAsset else {
      return .failure(.assetNotSupported(DebugError("Only local file assets are supported with Adobe DRM")))
    }

    return await parseEncryptionData(in: container.container)
      .mapError { ContentProtectionOpenError.reading(.decoding($0)) }
      .asyncFlatMap { encryptionData in
        guard let _ = container.container.sourceURL else {
          return .failure(.assetNotSupported(DebugError("Invalid source URL")))
        }

        let decryptor = AdobeDRMDecryptor(encryptionData: encryptionData)
        let decryptedContainer = decryptor.decryptContainer(container: container.container)
        let newContainerAsset = ContainerAsset(container: decryptedContainer, format: container.format)
        let cpAsset = ContentProtectionAsset(asset: .container(newContainerAsset)) { manifest, container, services in
          let manCopy = manifest
          let containerCopy = container
          services.setContentProtectionServiceFactory { factory in
            AdobeContentProtectionService(
              context: PublicationServiceContext(publication: factory.publication, manifest: manCopy, container: containerCopy)
            )
          }
        }

        return .success(cpAsset)
      }
  }
}


private extension AdobeDRMContentProtection {

  func parseEncryptionData(in container: Container) async -> Result<Data, Error> {
    guard let encryptionPath = AnyURL(string: "META-INF/encryption.xml") else {
      return .failure(DebugError("Invalid encryption.xml path"))
    }

    guard let resource = container[encryptionPath] else {
      return .failure(DebugError("Failed to retrieve encryption.xml"))
    }

    guard let encryptionData = try? await resource.read().get() else {
      return .failure(DebugError("Failed to read encryption.xml"))
    }

    return .success(encryptionData)
  }
}

final class AdobeDRMDecryptor {

  private let encryptionData: Data

  init(encryptionData: Data) {
    self.encryptionData = encryptionData
  }

  func decryptContainer(container: Container) -> Container {
    // Implement the decryption logic here. This is a placeholder.
    // Apply the necessary decryption logic to the container and return it.
    return container
  }
}

#endif
