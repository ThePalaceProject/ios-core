import Foundation
import ReadiumShared

// MARK: - DRMResource (Efficient Data Handling)

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
