//
//  PDFThumbnailStrip.swift
//  Palace
//
//  PP-1916: lazy bottom thumbnail strip for the PDF reader.
//
//  Replaces PDFKit's `PDFThumbnailView` (which eagerly rasterizes every page).
//  A horizontal `LazyHStack` instantiates only the cells currently on screen,
//  and each cell renders its thumbnail on demand via `PDFKitThumbnailProvider`,
//  so opening a large PDF no longer renders the whole document up front.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI
import PDFKit

/// Scrollable, lazily-rendered strip of page thumbnails shown at the bottom of
/// the PDF reader. Tapping a thumbnail seeks to that page; the strip keeps the
/// current page centered.
struct PDFThumbnailStrip: View {

    @StateObject private var provider: PDFKitThumbnailProvider
    @Binding var currentPage: Int

    private let thumbnailHeight: CGFloat = 48
    private let spacing: CGFloat = 6

    init(document: PDFDocument, currentPage: Binding<Int>) {
        self._provider = StateObject(wrappedValue: PDFKitThumbnailProvider(document: document))
        self._currentPage = currentPage
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: spacing) {
                        ForEach(0..<provider.pageCount, id: \.self) { page in
                            PDFThumbnailStripCell(
                                provider: provider,
                                page: page,
                                height: thumbnailHeight,
                                isCurrent: page == currentPage
                            )
                            .id(page)
                            .contentShape(Rectangle())
                            .onTapGesture { currentPage = page }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .onAppear { proxy.scrollTo(currentPage, anchor: .center) }
                .onChange(of: currentPage) { page in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(page, anchor: .center)
                    }
                }
            }
            .frame(height: thumbnailHeight + 16)
        }
        // Solid system background (not a material): the strip overlays the PDFView,
        // and a SwiftUI material renders unreliably over that UIViewRepresentable
        // backdrop, leaving the bar invisible over a white page.
        .background(Color(UIColor.systemBackground))
        // Selection tick when the visible page changes (tap or snap).
        .palaceHaptic(.selection, trigger: currentPage)
    }
}

/// A single thumbnail cell. Renders on demand and highlights the current page.
private struct PDFThumbnailStripCell: View {

    @StateObject private var fetcher: Fetcher
    private let page: Int
    private let height: CGFloat
    private let isCurrent: Bool

    init(provider: PDFKitThumbnailProvider, page: Int, height: CGFloat, isCurrent: Bool) {
        self._fetcher = StateObject(wrappedValue: Fetcher(provider: provider, page: page))
        self.page = page
        self.height = height
        self.isCurrent = isCurrent
    }

    var body: some View {
        ZStack {
            if let image = fetcher.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(UIColor.tertiarySystemFill))
            }
        }
        .frame(width: height * 3 / 4, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(isCurrent ? Color.accentColor : Color.gray.opacity(0.4),
                        lineWidth: isCurrent ? 2 : 0.5)
        )
        .scaleEffect(isCurrent ? 1.12 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isCurrent)
        .accessibilityLabel(String(format: NSLocalizedString("Page %d preview", comment: "PDF page thumbnail"), page + 1))
        .accessibilityAddTraits(isCurrent ? [.isSelected, .isButton] : .isButton)
        .onAppear { fetcher.fetch() }
    }

    /// Per-cell thumbnail loader. Mirrors the existing preview-grid pattern:
    /// seed from cache synchronously, otherwise render off the main thread and
    /// publish the result back. An `ObservableObject` is required so the cell
    /// re-renders when the async image arrives.
    @MainActor
    final class Fetcher: ObservableObject {
        @Published var image: UIImage?
        private let provider: PDFKitThumbnailProvider
        private let page: Int

        init(provider: PDFKitThumbnailProvider, page: Int) {
            self.provider = provider
            self.page = page
            self.image = provider.cachedThumbnail(for: page)
        }

        func fetch() {
            guard image == nil else { return }
            let providerBox = ThumbnailProviderBox(self.provider)
            let page = self.page
            DispatchQueue.pdfThumbnailRenderingQueue.async {
                let rendered = providerBox.provider.thumbnail(for: page)
                guard let rendered else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.image = rendered
                }
            }
        }
    }
}

/// Sendable carrier that transports the non-Sendable `PDFKitThumbnailProvider`
/// across the `@Sendable` background-render closure in `Fetcher.fetch()`.
/// `PDFKitThumbnailProvider.thumbnail(for:)` is invoked ONLY on
/// `pdfThumbnailRenderingQueue`, and the rendered image is published back via
/// the main-queue hop — the provider is never touched concurrently — so
/// `@unchecked Sendable` is sound. Mirrors `ImageCompletionBox` in
/// `ImageLoaderImpl`.
private final class ThumbnailProviderBox: @unchecked Sendable {
    let provider: PDFKitThumbnailProvider
    init(_ provider: PDFKitThumbnailProvider) { self.provider = provider }
}
