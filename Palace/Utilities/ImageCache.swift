import UIKit

class ImageCache {
  static let shared = ImageCache()

  private let cacheDirectory: URL
  private let fileManager = FileManager.default
  private let expirationInterval: TimeInterval = 7 * 24 * 60 * 60

  private init() {
    let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
    cacheDirectory = cachesDirectory.appendingPathComponent("ImageCache")
    if !fileManager.fileExists(atPath: cacheDirectory.path) {
      do {
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: nil)
      } catch {
        print("Failed to create cache directory: \(error)")
      }
    }
    cleanupCache()
  }

  /// Generate a unique file URL for a given account key.
  private func cachePath(forAccount accountKey: String) -> URL {
    let sanitizedKey = accountKey.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "", options: .regularExpression)
    return cacheDirectory.appendingPathComponent(sanitizedKey)
  }

  /// Save the image using the account string as key.
  func save(image: UIImage, forAccount accountKey: String) {
    let fileURL = cachePath(forAccount: accountKey)
    guard let data = image.pngData() else { return }
    do {
      try data.write(to: fileURL)
      try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
    } catch {
      print("Failed to save image: \(error)")
    }
  }

  /// Load the image from disk using the account string.
  func loadImage(forAccount accountKey: String) -> UIImage? {
    let fileURL = cachePath(forAccount: accountKey)
    guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
    guard let data = try? Data(contentsOf: fileURL),
          let image = UIImage(data: data) else {
      return nil
    }
    return image
  }

  /// Cleanup any cached images older than 7 days.
  func cleanupCache() {
    DispatchQueue.global(qos: .background).async {
      let expirationDate = Date().addingTimeInterval(-self.expirationInterval)
      do {
        let fileURLs = try self.fileManager.contentsOfDirectory(at: self.cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: [])
        for fileURL in fileURLs {
          let attributes = try self.fileManager.attributesOfItem(atPath: fileURL.path)
          if let modificationDate = attributes[.modificationDate] as? Date,
             modificationDate < expirationDate {
            try self.fileManager.removeItem(at: fileURL)
          }
        }
      } catch {
        print("Failed to cleanup cache: \(error)")
      }
    }
  }
}
