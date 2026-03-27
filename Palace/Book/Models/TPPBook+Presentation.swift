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

// MARK: - Cover Image Fetching & Cache

extension TPPBook {
    private static let coverRegistry = TPPBookCoverRegistry.shared

    func fetchCoverImage() {
        let simpleKey = identifier
        let coverKey = "\(identifier)_cover"

        if let img = imageCache.get(for: simpleKey) ?? imageCache.get(for: coverKey) {
            DispatchQueue.main.async {
                self.coverImage = img
                self.updateDominantColor(using: img)
            }
            return
        }

        guard !isCoverLoading else { return }

        DispatchQueue.main.async {
            self.isCoverLoading = true
        }

        TPPBookCoverRegistryBridge.shared.coverImageForBook(self) { [weak self] image in
            guard let self = self else { return }
            let final = image ?? self.thumbnailImage

            DispatchQueue.main.async {
                self.coverImage = final
                if let img = final {
                    self.imageCache.set(img, for: self.identifier)
                    self.imageCache.set(img, for: coverKey)
                    self.updateDominantColor(using: img)
                }
                self.isCoverLoading = false
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

        guard !isThumbnailLoading else { return }

        DispatchQueue.main.async {
            self.isThumbnailLoading = true
        }

        TPPBookCoverRegistryBridge.shared.thumbnailImageForBook(self) { [weak self] image in
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

                var bitmap = [UInt8](repeating: 0, count: 4)

                let renderBounds = CGRect(x: 0, y: 0, width: 1, height: 1)
                guard renderBounds.width > 0, renderBounds.height > 0 else {
                    Log.warn(#file, "Invalid render bounds")
                    DispatchQueue.main.async { self.dominantUIColor = .gray }
                    return
                }

                do {
                    Self.sharedCIContext.render(
                        outputImage,
                        toBitmap: &bitmap,
                        rowBytes: 4,
                        bounds: renderBounds,
                        format: .RGBA8,
                        colorSpace: colorSpace
                    )

                    let color = UIColor(
                        red: CGFloat(bitmap[0]) / 255.0,
                        green: CGFloat(bitmap[1]) / 255.0,
                        blue: CGFloat(bitmap[2]) / 255.0,
                        alpha: CGFloat(bitmap[3]) / 255.0
                    )

                    DispatchQueue.main.async {
                        self.dominantUIColor = color
                    }
                } catch {
                    Log.warn(#file, "Failed to extract dominant color for \(self.identifier): \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self.dominantUIColor = .gray
                    }
                }
            }
        }
    }
}
