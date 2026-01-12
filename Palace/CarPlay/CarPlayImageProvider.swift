//
//  CarPlayImageProvider.swift
//  Palace
//
//  Created for CarPlay audiobook support.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import CarPlay
import UIKit

/// Provides artwork images for CarPlay audiobook display
/// Handles async loading, caching, and placeholder generation
final class CarPlayImageProvider {
  
  // MARK: - Constants
  
  private enum Layout {
    static let artworkSize = CGSize(width: 90, height: 90)
    static let largeArtworkSize = CGSize(width: 300, height: 300)
    static let cornerRadius: CGFloat = 8
  }
  
  // MARK: - Properties
  
  private let imageCache: ImageCacheType
  private var inProgressTasks: [String: Task<UIImage?, Never>] = [:]
  private let queue = DispatchQueue(label: "org.thepalaceproject.carplay.images", qos: .userInitiated)
  
  // MARK: - Initialization
  
  init(imageCache: ImageCacheType = ImageCache.shared) {
    self.imageCache = imageCache
  }
  
  // MARK: - Public Methods
  
  /// Fetches artwork for a book asynchronously
  /// - Parameters:
  ///   - book: The book to fetch artwork for
  ///   - completion: Called with the artwork image or nil
  func artwork(for book: TPPBook, completion: @escaping (UIImage?) -> Void) {
    let cacheKey = carPlayCacheKey(for: book)
    
    // Check cache first
    if let cached = imageCache.get(for: cacheKey) {
      completion(cached)
      return
    }
    
    // Check if book already has a loaded image
    if let existingImage = book.coverImage ?? book.thumbnailImage {
      let processed = processForCarPlay(existingImage)
      imageCache.set(processed, for: cacheKey)
      completion(processed)
      return
    }
    
    // Load asynchronously
    Task {
      let image = await loadArtwork(for: book)
      let finalImage = image ?? generatePlaceholder(for: book)
      let processed = processForCarPlay(finalImage)
      
      imageCache.set(processed, for: cacheKey)
      
      await MainActor.run {
        completion(processed)
      }
    }
  }
  
  /// Creates a CPImageSet for CarPlay templates
  /// - Parameter book: The book to create an image set for
  /// - Returns: CPImageSet for light and dark mode
  func imageSet(for book: TPPBook) async -> CPImageSet? {
    let image = await loadArtwork(for: book) ?? generatePlaceholder(for: book)
    let processed = processForCarPlay(image)
    
    // CarPlay uses same image for both light and dark variants
    return CPImageSet(lightContentImage: processed, darkContentImage: processed)
  }
  
  // MARK: - Private Methods
  
  private func carPlayCacheKey(for book: TPPBook) -> String {
    "carplay_\(book.identifier)"
  }
  
  private func loadArtwork(for book: TPPBook) async -> UIImage? {
    // First check if cover is already available
    if let cover = book.coverImage ?? book.thumbnailImage {
      return cover
    }
    
    // Try to load from URL
    guard let imageURL = book.imageURL ?? book.imageThumbnailURL else {
      return nil
    }
    
    do {
      let (data, _) = try await URLSession.shared.data(from: imageURL)
      return UIImage(data: data)
    } catch {
      Log.error(#file, "CarPlay: Failed to load artwork for '\(book.title)': \(error)")
      return nil
    }
  }
  
  private func processForCarPlay(_ image: UIImage) -> UIImage {
    // Scale and add corner radius for CarPlay display
    let targetSize = Layout.artworkSize
    
    let format = UIGraphicsImageRendererFormat()
    format.scale = UIScreen.main.scale
    format.opaque = false
    
    let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
    
    return renderer.image { context in
      let rect = CGRect(origin: .zero, size: targetSize)
      
      // Create rounded rect path
      let path = UIBezierPath(roundedRect: rect, cornerRadius: Layout.cornerRadius)
      path.addClip()
      
      // Draw scaled image
      image.draw(in: rect)
    }
  }
  
  private func generatePlaceholder(for book: TPPBook) -> UIImage {
    let size = Layout.artworkSize
    
    let format = UIGraphicsImageRendererFormat()
    format.scale = UIScreen.main.scale
    
    return UIGraphicsImageRenderer(size: size, format: format).image { context in
      // Use TenPrint cover generation for consistent visual style
      if let tenPrintView = NYPLTenPrintCoverView(
        frame: CGRect(origin: .zero, size: size),
        withTitle: book.title,
        withAuthor: book.authors ?? Strings.Generic.unknownAuthor,
        withScale: 0.4
      ) {
        tenPrintView.layer.render(in: context.cgContext)
      } else {
        // Fallback: simple colored placeholder
        let rect = CGRect(origin: .zero, size: size)
        UIColor.systemGray4.setFill()
        context.fill(rect)
        
        // Draw audiobook icon
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 32, weight: .medium)
        if let icon = UIImage(systemName: "headphones", withConfiguration: iconConfig) {
          let iconSize = icon.size
          let iconOrigin = CGPoint(
            x: (size.width - iconSize.width) / 2,
            y: (size.height - iconSize.height) / 2
          )
          icon.withTintColor(.systemGray2).draw(at: iconOrigin)
        }
      }
    }
  }
}
