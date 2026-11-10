//  DominantCoverColor.swift
//
//  Average color of a cover image, used behind the book detail header.
//  Pure and synchronous; `BookCoverStore` runs it off the main thread once
//  per cover image.

import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import PalaceLogging

enum DominantCoverColor {
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

    /// The area-average color of `image`, or `.gray` when it cannot be computed.
    static func extract(from image: UIImage) -> UIColor {
        autoreleasepool { averageColor(of: image) ?? .gray }
    }

    private static func averageColor(of image: UIImage) -> UIColor? {
        let deviceMemoryMB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024)
        guard deviceMemoryMB >= 1024 else {
            Log.debug(#file, "Skipping dominant color extraction on low-memory device (\(deviceMemoryMB)MB)")
            return nil
        }

        guard image.size.width > 0, image.size.height > 0 else {
            Log.warn(#file, "Invalid image size for dominant color extraction: \(image.size)")
            return nil
        }

        guard let cgImage = image.cgImage else {
            Log.warn(#file, "No CGImage available for dominant color extraction")
            return nil
        }

        guard cgImage.width > 0, cgImage.height > 0, cgImage.bitsPerPixel > 0 else {
            Log.warn(#file, "Invalid CGImage properties: width=\(cgImage.width), height=\(cgImage.height), bpp=\(cgImage.bitsPerPixel)")
            return nil
        }

        guard let scaledImage = downscaled(image, cgImage: cgImage, maxDimension: 500) else {
            return nil
        }

        guard let ciImage = CIImage(image: scaledImage) else {
            Log.debug(#file, "Failed to create CIImage from UIImage for dominant color")
            return nil
        }

        let extent = ciImage.extent
        guard !extent.isEmpty, extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else {
            Log.debug(#file, "CIImage has invalid extent for dominant color: \(extent)")
            return nil
        }

        let filter = CIFilter.areaAverage()
        filter.inputImage = ciImage
        filter.extent = extent

        guard let outputImage = filter.outputImage, !outputImage.extent.isEmpty else {
            Log.debug(#file, "areaAverage filter produced no output for dominant color")
            return nil
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            Log.debug(#file, "Failed to create sRGB color space for dominant color")
            return nil
        }

        let renderBounds = CGRect(x: 0, y: 0, width: 1, height: 1)

        // CIContext.render(_:toBitmap:) aborts internally (SIGABRT, Crashlytics
        // 0f06402c) on degenerate cover images that pass the guards above, and
        // a native abort cannot be caught from Swift. createCGImage returns nil
        // on failure instead, and the single averaged pixel is read back through
        // a CGContext.
        guard let averagedCGImage = sharedCIContext.createCGImage(
            outputImage,
            from: renderBounds,
            format: .RGBA8,
            colorSpace: colorSpace
        ) else {
            Log.debug(#file, "areaAverage createCGImage returned nil for dominant color")
            return nil
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
            Log.debug(#file, "Failed to create 1x1 readback context for dominant color")
            return nil
        }
        readbackContext.draw(averagedCGImage, in: renderBounds)

        return UIColor(
            red: CGFloat(bitmap[0]) / 255.0,
            green: CGFloat(bitmap[1]) / 255.0,
            blue: CGFloat(bitmap[2]) / 255.0,
            alpha: CGFloat(bitmap[3]) / 255.0
        )
    }

    /// `image` itself when it already fits in `maxDimension`, otherwise a copy scaled to fit.
    private static func downscaled(_ image: UIImage, cgImage: CGImage, maxDimension: CGFloat) -> UIImage? {
        let imageSize = image.size
        let maxSide = max(imageSize.width, imageSize.height)
        guard maxSide > maxDimension else { return image }

        let scale = maxDimension / maxSide
        let newSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        guard newSize.width > 0, newSize.height > 0, Int(newSize.width) > 0, Int(newSize.height) > 0 else {
            Log.warn(#file, "Invalid scaled size for dominant color: \(newSize)")
            return nil
        }

        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context = CGContext(
            data: nil,
            width: Int(newSize.width),
            height: Int(newSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            Log.warn(#file, "Failed to create CGContext for dominant color resize")
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(origin: .zero, size: newSize))

        guard let resizedCGImage = context.makeImage() else {
            Log.warn(#file, "Failed to create resized CGImage for dominant color")
            return nil
        }
        return UIImage(cgImage: resizedCGImage, scale: 1.0, orientation: image.imageOrientation)
    }
}
