//
//  ReadiumPDFViewController.swift
//  Palace
//
//  Replaces the custom LCP PDF pipeline (zip → extract-to-temp → PDFKit) with
//  Readium 3's PDFNavigatorViewController, which streams decrypted pages on
//  demand via the shared GCDHTTPServer. Eliminates the temp-extract step, its
//  silent-failure class, and the 3× disk footprint.
//

import UIKit
import SwiftUI
import ReadiumShared
import ReadiumNavigator
import ReadiumAdapterGCDWebServer

/// Bridges Readium's `PDFNavigatorViewController` into Palace's reading-position
/// sync (via `onLocationChange`) without Palace-layer code depending on
/// Readium types.
final class ReadiumPDFViewController: UIViewController {

    private let publication: Publication
    private let book: TPPBook
    private let httpServer: GCDHTTPServer

    /// Legacy page index from the pre-migration pipeline (0-indexed). We can't
    /// build an accurate Locator at init time because `positionsByReadingOrder`
    /// is async — we restore the page in `viewDidLoad` after the navigator is
    /// mounted. This is the shim for users who bookmarked pages under the old
    /// PDFKit-based reader; the existing `TPPBookRegistry` page numbers keep
    /// working unchanged.
    private let initialPageIndex: Int?

    private var navigator: PDFNavigatorViewController?

    /// Fires on every Readium `locationDidChange` so the caller can translate
    /// the `Locator` into whatever persistence model Palace uses (currently
    /// `TPPPDFDocumentMetadata.currentPage` → `TPPBookRegistry.setLocation`).
    var onLocationChange: ((Locator) -> Void)?

    init(publication: Publication, book: TPPBook, httpServer: GCDHTTPServer, initialPageIndex: Int?) {
        self.publication = publication
        self.book = book
        self.httpServer = httpServer
        self.initialPageIndex = initialPageIndex
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        installNavigator()
    }

    private func installNavigator() {
        do {
            let nav = try PDFNavigatorViewController(
                publication: publication,
                initialLocation: nil,
                delegate: self,
                httpServer: httpServer
            )
            addChild(nav)
            view.addSubview(nav.view)
            nav.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                nav.view.topAnchor.constraint(equalTo: view.topAnchor),
                nav.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                nav.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                nav.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            nav.didMove(toParent: self)
            navigator = nav
            Log.info(#file, "📄 [Readium PDF] navigator installed for book: \(book.identifier)")
            restoreInitialPageIfNeeded(nav)
        } catch {
            Log.error(#file, "📄 [Readium PDF] ❌ navigator init failed: \(error.localizedDescription)")
            presentFailure()
        }
    }

    /// Migration shim for legacy pre-Readium stored positions.
    ///
    /// Prior to this migration, `TPPPDFDocumentMetadata` stored reading
    /// position as a 0-indexed PDFKit page number in `TPPBookRegistry`.
    /// Readium's navigator expects a `Locator` — opaque to the app layer and
    /// async to produce from the publication's positions list. Rather than
    /// rewrite every existing stored position into a Locator-shaped
    /// `TPPBookLocation`, we honor the existing page index by looking up the
    /// matching `Locator` via `positionsByReadingOrder` and jumping to it
    /// after the navigator is mounted. Users with an existing bookmark see
    /// the book open where they left off; no data migration, no first-open
    /// reset.
    private func restoreInitialPageIfNeeded(_ nav: PDFNavigatorViewController) {
        guard let pageIndex = initialPageIndex, pageIndex > 0 else { return }
        Task { @MainActor in
            let result = await publication.positionsByReadingOrder()
            guard case .success(let positionsByOrder) = result else {
                Log.warn(#file, "📄 [Readium PDF] positionsByReadingOrder returned failure — skipping initial-page restore")
                return
            }
            let flat = positionsByOrder.flatMap { $0 }
            // Locator position is 1-indexed; legacy storage is 0-indexed.
            let targetPosition = pageIndex + 1
            guard let locator = flat.first(where: { ($0.locations.position ?? -1) == targetPosition }) else {
                Log.warn(#file, "📄 [Readium PDF] no Locator for page index \(pageIndex) (publication has \(flat.count) positions)")
                return
            }
            Log.info(#file, "📄 [Readium PDF] restoring legacy position → page \(pageIndex)")
            _ = await nav.go(to: locator)
        }
    }

    private func presentFailure() {
        let label = UILabel()
        label.text = NSLocalizedString("Unable to load PDF file", comment: "")
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }
}

extension ReadiumPDFViewController: PDFNavigatorDelegate {
    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        onLocationChange?(locator)
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        Log.error(#file, "📄 [Readium PDF] navigator error: \(error.localizedDescription)")
    }

    func navigator(_ navigator: Navigator, didFailToLoadResourceAt href: RelativeURL, withError error: ReadError) {
        Log.error(#file, "📄 [Readium PDF] failed to load resource at \(href): \(error.localizedDescription)")
    }
}

// MARK: - SwiftUI bridge

struct ReadiumPDFContainer: UIViewControllerRepresentable {
    let publication: Publication
    let book: TPPBook
    let httpServer: GCDHTTPServer
    let initialPageIndex: Int?
    let onLocationChange: (Locator) -> Void

    func makeUIViewController(context: Context) -> ReadiumPDFViewController {
        let vc = ReadiumPDFViewController(
            publication: publication,
            book: book,
            httpServer: httpServer,
            initialPageIndex: initialPageIndex
        )
        vc.onLocationChange = onLocationChange
        return vc
    }

    func updateUIViewController(_ uiViewController: ReadiumPDFViewController, context: Context) {}
}
