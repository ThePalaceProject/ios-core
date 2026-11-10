//
//  AppCacheSizes.swift
//  Palace
//
//  Registers every cache the app owns with the memory event line (PP-5509),
//  so device runs show where memory goes. Fields can overlap: `bookCovers`
//  holds the same UIImage objects that `decodedImages` may also hold. The
//  production sources read counters, not the caches, so a memory event never
//  creates a cache.
//

import Foundation
import PalaceBookModel

/// Byte counters of the process-wide caches. Each cache's shared instance
/// reports into one of these, so the memory event line reads sizes without
/// creating a cache.
enum AppCacheCounters {
    static let decodedImages = CacheByteCounter()
    static let imageData = CacheByteCounter()
    static let coverSourceData = CacheByteCounter()
    static let opdsFeedData = CacheByteCounter()
    static let lcpDecrypt = CacheByteCounter()
}

enum AppCacheSizes {
    struct Sources {
        var networkResponses: @Sendable () -> Int
        var decodedImages: @Sendable () -> Int
        var imageData: @Sendable () -> Int
        var coverSourceData: @Sendable () -> Int
        var bookCovers: @Sendable () -> Int
        var opdsFeedData: @Sendable () -> Int
        var pdfPreviews: @Sendable () -> Int
        var pdfThumbnails: @Sendable () -> Int
        var lcpDecrypt: (@Sendable () -> Int)?

        static func production(networkResponses: @escaping @Sendable () -> Int) -> Sources {
            var sources = Sources(
                networkResponses: networkResponses,
                decodedImages: { AppCacheCounters.decodedImages.bytes },
                imageData: { AppCacheCounters.imageData.bytes },
                coverSourceData: { AppCacheCounters.coverSourceData.bytes },
                // The store holds no disk or network state, so creating it here is cheap.
                bookCovers: { BookCoverStore.defaultStoreImageByteCount },
                opdsFeedData: { AppCacheCounters.opdsFeedData.bytes },
                pdfPreviews: { TPPPDFPreviewGridController.livePreviewBytes.bytes },
                pdfThumbnails: { PDFKitThumbnailProvider.liveThumbnailBytes.bytes }
            )
            #if LCP
            sources.lcpDecrypt = { AppCacheCounters.lcpDecrypt.bytes }
            #endif
            return sources
        }
    }

    static func register(on recorder: MemoryEventRecorder, sources: Sources) {
        recorder.registerCache(named: "networkResponses", size: sources.networkResponses)
        recorder.registerCache(named: "decodedImages", size: sources.decodedImages)
        recorder.registerCache(named: "imageData", size: sources.imageData)
        recorder.registerCache(named: "coverSourceData", size: sources.coverSourceData)
        recorder.registerCache(named: "bookCovers", size: sources.bookCovers)
        recorder.registerCache(named: "opdsFeedData", size: sources.opdsFeedData)
        recorder.registerCache(named: "pdfPreviews", size: sources.pdfPreviews)
        recorder.registerCache(named: "pdfThumbnails", size: sources.pdfThumbnails)
        if let lcpDecrypt = sources.lcpDecrypt {
            recorder.registerCache(named: "lcpDecrypt", size: lcpDecrypt)
        }
    }
}
