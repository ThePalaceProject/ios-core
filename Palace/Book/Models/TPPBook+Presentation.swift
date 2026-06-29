//
//  TPPBook+Presentation.swift
//  Palace
//
//  Extracted from TPPBook.swift
//  Computed UI properties: cover image fetching, dominant color,
//  display strings, and image cache management.
//

import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import PalaceLogging

// MARK: - Cover Image Fetching & Cache

extension TPPBook {
    /// Routes cover/thumbnail loads through the `ImageLoading` umbrella so this
    /// file no longer reaches for `TPPBookCoverRegistry.shared` /
    /// `TPPBookCoverRegistryBridge.shared` directly. Reads
    /// `AppContainer.production().imageLoader`, which is the same graph every
    /// other consumer (BookListView, TPPAppDelegate, CarPlay) reads.
    ///
    /// Safe to read here even though `AppContainer.production()` builds its
    /// graph on a dispatch_once: TPPBook instances are constructed *after* the
    /// AppContainer is fully built, so this access is post-bootstrap and
    /// never re-enters the once. (Direct reads from inside `_cached`'s init
    /// would SIGTRAP — see the cycle warning in TPPBookRegistry.swift.)
    var imageLoader: ImageLoading {
        AppContainer.production().imageLoader
    }

    func fetchCoverImage() {
        fetchCoverImage(forDisplayHeight: nil)
    }

    /// Fetches the cover at a resolution appropriate for the given display height (in points).
    /// When `displayHeight` is provided, the decoded image is sized to match the view rather
    /// than the conservative device memory-tier cap, so the image is always sharp at its
    /// actual display size without wasting memory decoding more than needed.
    func fetchCoverImage(forDisplayHeight displayHeight: CGFloat?) {
        let sizeKey: String? = displayHeight.map { "\(identifier)_\(Int($0))pt" }
        let lookupKeys: [String] = if let sizeKey { [sizeKey, identifier] } else { [identifier] }

        // Synchronous memory-cache check (instant, no disk I/O on main thread)
        if let img = lookupKeys.lazy.compactMap({ [weak self] in
          self?.imageCache.get(for: $0) }).first {
            DispatchQueue.main.async {
                self.coverImage = img
                self.updateDominantColor(using: img)
            }
            return
        }

        guard !isCoverLoading else { return }

        DispatchQueue.main.async { self.isCoverLoading = true }

        if let displayHeight {
            Task { [weak self] in
                guard let self else { return }

                // Async cache check: promotes disk→memory before hitting network.
                // This is the systemic fix for images "disappearing" on entry point
                // switches — new TPPBook instances miss the sync check above (main
                // thread returns nil for disk-only entries) but this async path finds
                // them without a network round-trip.
                for key in lookupKeys {
                    if let cached = await self.imageCache.getAsync(for: key) {
                        await MainActor.run {
                            self.coverImage = cached
                            self.updateDominantColor(using: cached)
                            self.isCoverLoading = false
                        }
                        return
                    }
                }

                // Cache miss — fetch from network
                let img = await self.imageLoader.coverImage(for: self, displayPoints: displayHeight)
                let final = img ?? self.thumbnailImage
                await MainActor.run {
                    self.coverImage = final
                    if let img = final {
                        let cacheKey = sizeKey ?? self.identifier
                        self.imageCache.set(img, for: cacheKey)
                        self.updateDominantColor(using: img)
                    }
                    self.isCoverLoading = false
                }
            }
        } else {
            let startFetch = { [weak self] in
                guard let self else { return }

                self.imageLoader.coverImage(for: self) { [weak self] image in
                    guard let self = self else { return }
                    let final = image ?? self.thumbnailImage

                    DispatchQueue.main.async {
                        self.coverImage = final
                        if let img = final {
                            // Single cache key — no duplicate storage
                            self.imageCache.set(img, for: self.identifier)
                            self.updateDominantColor(using: img)
                        }
                        self.isCoverLoading = false
                    }
                }
            }

            if Thread.isMainThread {
                startFetch()
            } else {
                DispatchQueue.main.async(execute: startFetch)
            }
        }
    }

    func fetchThumbnailImage() {
        let simpleKey = identifier
        let thumbnailKey = "\(identifier)_thumbnail"

        if let img = imageCache.get(for: simpleKey) ?? imageCache.get(for: thumbnailKey) {
            DispatchQueue.main.async {
                self.thumbnailImage = img
            }
            return
        }

        let startFetch = { [weak self] in
            guard let self, !self.isThumbnailLoading else { return }
            self.isThumbnailLoading = true

            self.imageLoader.thumbnailImage(for: self) { [weak self] image in
                guard let self = self else { return }

                DispatchQueue.main.async {
                    self.thumbnailImage = image
                    if let img = image {
                        self.imageCache.set(img, for: self.identifier)
                        self.imageCache.set(img, for: thumbnailKey)
                        if self.coverImage == nil {
                            self.updateDominantColor(using: img)
                        }
                    }
                    self.isThumbnailLoading = false
                }
            }
        }

        if Thread.isMainThread {
            startFetch()
        } else {
            DispatchQueue.main.async(execute: startFetch)
        }
    }

    func clearCachedImages() {
        imageCache.remove(for: identifier)
        imageCache.remove(for: "\(identifier)_cover")
        imageCache.remove(for: "\(identifier)_thumbnail")
        DispatchQueue.main.async {
            self.coverImage = nil
            self.thumbnailImage = nil
            self.dominantUIColor = .gray
        }
    }
}

// MARK: - Display Helpers

extension TPPBook {
    var wrappedCoverImage: UIImage? {
        coverImage
    }

    @objc public class func ordinalString(for n: Int) -> String {
        return n.ordinal()
    }
}

// MARK: - Dominant Color (async, off main thread)

extension TPPBook {
    private static let colorProcessingQueue = DispatchQueue(label: "org.thepalaceproject.dominantcolor", qos: .utility)
    private static let sharedCIContext: CIContext = {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return CIContext()
        }
        return CIContext(options: [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
            .useSoftwareRenderer: false
        ])
    }()

    func updateDominantColor(using image: UIImage) {
        let inputImage = image
        Self.colorProcessingQueue.async { [weak self] in
            guard let self = self else { return }

            autoreleasepool {
                let deviceMemoryMB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024)
                guard deviceMemoryMB >= 1024 else {
                    Log.debug(#file, "Skipping dominant color extraction on low-memory device (\(deviceMemoryMB)MB)")
                    DispatchQueue.main.async { self.dominantUIColor = .gray }
                    return
                }

                guard inputImage.size.width > 0, inputImage.size.height > 0 else {
                    Log.warn(#file, "Invalid image size for dominant color extraction: \(inputImage.size)")
                    DispatchQueue.main.async { self.dominantUIColor = .gray }
                    return
                }

                guard let cgImage = inputImage.cgImage else {
                    Log.warn(#file, "No CGImage available for dominant color extraction")
                    DispatchQueue.main.async { self.dominantUIColor = .gray }
                    return
                }

                guard cgImage.width > 0, cgImage.height > 0, cgImage.bitsPerPixel > 0 else {
                    Log.warn(#file, "Invalid CGImage properties: width=\(cgImage.width), height=\(cgImage.height), bpp=\(cgImage.bitsPerPixel)")
                    DispatchQueue.main.async { self.dominantUIColor = .gray }
                    return
                }

                let maxDimension: CGFloat = 500
                let scaledImage: UIImage

                let imageSize = inputImage.size
                let maxSide = max(imageSize.width, imageSize.height)

                if maxSide > maxDimension {
                    let scale = maxDimension / maxSide
                    let newSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)

                    guard newSize.width > 0, newSize.height > 0, Int(newSize.width) > 0, Int(newSize.height) > 0 else {
                        Log.warn(#file, "Invalid scaled size for dominant color: \(newSize)")
                        DispatchQueue.main.async { self.dominantUIColor = .gray }
                        return
                    }

                    let colorSpace = CGColorSpaceCreateDeviceRGB()
                    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

                    guard let context = CGContext(
                        data: nil,
                        width: Int(newSize.width),
                        height: Int(newSize.height),
                        bitsPerComponent: 8,
                        bytesPerRow: 0,
                        space: colorSpace,
                        bitmapInfo: bitmapInfo.rawValue
                    ) else {
                        Log.warn(#file, "Failed to create CGContext for dominant color resize")
                        DispatchQueue.main.async { self.dominantUIColor = .gray }
                        return
                    }

                    context.interpolationQuality = .medium
                    context.draw(cgImage, in: CGRect(origin: .zero, size: newSize))

                    guard let resizedCGImage = context.makeImage() else {
                        Log.warn(#file, "Failed to create resized CGImage for dominant color")
                        DispatchQueue.main.async { self.dominantUIColor = .gray }
                        return
                    }

                    scaledImage = UIImage(cgImage: resizedCGImage, scale: 1.0, orientation: inputImage.imageOrientation)
                } else {
                    scaledImage = inputImage
                }

                guard let ciImage = CIImage(image: scaledImage) else {
                    Log.debug(#file, "Failed to create CIImage from UIImage for book: \(self.identifier)")
                    DispatchQueue.main.async { self.dominantUIColor = .gray }
                    return
                }

                let extent = ciImage.extent
                guard !extent.isEmpty, extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else {
                    Log.debug(#file, "CIImage has invalid extent for book: \(self.identifier) - \(extent)")
                    DispatchQueue.main.async { self.dominantUIColor = .gray }
                    return
                }

                let filter = CIFilter.areaAverage()
                filter.inputImage = ciImage
                filter.extent = extent

                guard let outputImage = filter.outputImage else {
                    Log.debug(#file, "Failed to generate output image from filter for book: \(self.identifier)")
                    DispatchQueue.main.async { self.dominantUIColor = .gray }
                    return
                }

                guard !outputImage.extent.isEmpty else {
                    Log.debug(#file, "Filter output image has empty extent for book: \(self.identifier)")
                    DispatchQueue.main.async { self.dominantUIColor = .gray }
                    return
                }

                guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
                    Log.debug(#file, "Failed to create sRGB color space for book: \(self.identifier)")
                    DispatchQueue.main.async { self.dominantUIColor = .gray }
                    return
                }

                let renderBounds = CGRect(x: 0, y: 0, width: 1, height: 1)

                // CIContext.render(_:toBitmap:) aborts INTERNALLY (C++ abort →
                // SIGABRT, Crashlytics 0f06402c) on degenerate/corrupt cover
                // images that survive the guards above, and — being non-throwing
                // — the do/catch that used to wrap it was dead code (a native
                // abort cannot be caught by Swift, so there was no recovery path
                // and the process was killed). Render the 1x1 areaAverage output
                // via createCGImage, which returns nil on failure instead of
                // aborting, then read the single averaged pixel back through a
                // CGContext. Any failure now falls back to .gray.
                guard let averagedCGImage = Self.sharedCIContext.createCGImage(
                    outputImage,
                    from: renderBounds,
                    format: .RGBA8,
                    colorSpace: colorSpace
                ) else {
                    Log.debug(#file, "areaAverage createCGImage returned nil for book: \(self.identifier)")
                    DispatchQueue.main.async { self.dominantUIColor = .gray }
                    return
                }

                var bitmap = [UInt8](repeating: 0, count: 4)
                guard let readbackContext = CGContext(
                    data: &bitmap,
                    width: 1,
                    height: 1,
                    bitsPerComponent: 8,
                    bytesPerRow: 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else {
                    Log.debug(#file, "Failed to create 1x1 readback context for book: \(self.identifier)")
                    DispatchQueue.main.async { self.dominantUIColor = .gray }
                    return
                }
                readbackContext.draw(averagedCGImage, in: renderBounds)

                let color = UIColor(
                    red: CGFloat(bitmap[0]) / 255.0,
                    green: CGFloat(bitmap[1]) / 255.0,
                    blue: CGFloat(bitmap[2]) / 255.0,
                    alpha: CGFloat(bitmap[3]) / 255.0
                )

                DispatchQueue.main.async {
                    self.dominantUIColor = color
                }
            }
        }
    }
}
