//
//  AppCacheSizes.swift
//  Palace
//
//  Registers every cache the app owns with the memory event line (PP-5509),
//  so device runs show where memory goes. Fields can overlap: `bookCovers`
//  holds the same UIImage objects that `decodedImages` may also hold.
//

import Foundation
import PalaceBookModel

enum AppCacheSizes {
    static func register(on recorder: MemoryEventRecorder, networkResponses: @escaping @Sendable () -> Int) {
        recorder.registerCache(named: "networkResponses", size: networkResponses)
        recorder.registerCache(named: "decodedImages") { ImageCache.shared.decodedImageBytes }
        recorder.registerCache(named: "imageData") { ImageCache.shared.compressedDataMemoryBytes }
        recorder.registerCache(named: "coverSourceData") { TPPBookCoverRegistry.shared.sourceDataBytes }
        recorder.registerCache(named: "bookCovers") { BookCoverStore.shared.imageByteCount }
        recorder.registerCache(named: "opdsFeedData") { OPDS2FeedCache.shared.dataMemoryBytes }
        recorder.registerCache(named: "pdfPreviews") { TPPPDFPreviewGridController.livePreviewBytes.bytes }
        recorder.registerCache(named: "pdfThumbnails") { PDFKitThumbnailProvider.liveThumbnailBytes.bytes }
        #if LCP
        recorder.registerCache(named: "lcpDecrypt") { LCPDecryptCache.shared.byteCount }
        #endif
    }
}
