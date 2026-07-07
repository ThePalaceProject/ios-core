//
//  TPPPDFDocumentView.swift
//  Palace
//
//  Created by Vladimir Fedorov on 20.05.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI
// `@preconcurrency`: PDFKit is not Sendable-audited upstream; its `PDFView`,
// `PDFDocument`, and the `PDFViewDelegate` requirement cross into this file's
// main-actor SwiftUI/coordinator paths. Matches the sibling `TPPPDFView.swift`.
@preconcurrency import PDFKit
import Combine

/// Wraps PDFKit PDFView control
struct TPPPDFDocumentView: UIViewRepresentable {

    var document: PDFDocument
    var pdfView: PDFView
    @Binding var showingDocumentInfo: Bool
    @Binding var isTracking: Bool

    @EnvironmentObject var metadata: TPPPDFDocumentMetadata

    private let pdfViewGestureRecognizer = PDFViewGestureRecognizer()

    func makeUIView(context: Context) -> some UIView {
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .horizontal
        pdfView.displayBox = .mediaBox
        pdfView.usePageViewController(true, withViewOptions: [UIPageViewController.OptionsKey.interPageSpacing: 20])
        pdfView.document = document
        if let page = document.page(at: metadata.currentPage) {
            pdfView.go(to: page)
        }
        pdfView.delegate = context.coordinator

        pdfViewGestureRecognizer.onTouchEnded({ touches in
            if let touchPoint = touches.first?.location(in: self.pdfView) {
                let elementTapped = self.pdfView.areaOfInterest(for: touchPoint)
                // If the tapped element is not interactive, change bar visibility
                if elementTapped.intersection([.linkArea, .controlArea, .popupArea, .textFieldArea]).isEmpty {
                    showingDocumentInfo.toggle()
                }
            }
        })

        pdfViewGestureRecognizer.onTrackingChanged { value in
            isTracking = value
        }

        pdfView.addGestureRecognizer(pdfViewGestureRecognizer)

        return pdfView
    }

    func updateUIView(_ uiView: UIViewType, context: Context) {
        guard let pdfView = uiView as? PDFView,
              let page = pdfView.currentPage,
              let pageIndex = pdfView.document?.index(for: page)
        else {
            return
        }
        if pageIndex != metadata.currentPage, let page = pdfView.document?.page(at: metadata.currentPage) {
            pdfView.go(to: page)
        }
    }

    func makeCoordinator() -> Coordinator {
        return Coordinator(currentPage: $metadata.currentPage)
    }

    // `@MainActor` + `@preconcurrency PDFViewDelegate`: the coordinator holds a
    // `@Binding` and drives main-actor SwiftUI state. Previously the nonisolated
    // `pdfViewPerformGo` requirement forced a `MainActor.assumeIsolated` block that
    // captured `self` (the non-`Sendable` `Coordinator`) into a `@Sendable`
    // closure — the "sending 'self' risks data races" diagnostic. Isolating the
    // whole coordinator to the main actor and satisfying the nonisolated PDFKit
    // requirement via `@preconcurrency` removes the send: PDFKit delivers
    // `PDFViewDelegate` callbacks on the main thread, so the main-actor method is a
    // faithful, race-free implementation.
    @MainActor
    class Coordinator: NSObject, @preconcurrency PDFViewDelegate {
        @Binding var currentPage: Int

        init(currentPage: Binding<Int>) {
            self._currentPage = currentPage
        }

        func pdfViewPerformGo(toPage sender: PDFView) {
            if let page = sender.currentPage, let pageIndex = sender.document?.index(for: page) {
                currentPage = pageIndex
            }
        }
    }

    class PDFViewGestureRecognizer: UIGestureRecognizer {
        var isTracking = false {
            didSet {
                self.trackingChanged?(isTracking)
            }
        }

        private var touchCompletion: ((_ touches: Set<UITouch>) -> Void)?
        private var trackingChanged: ((_ value: Bool) -> Void)?

        func onTouchEnded(_ touchCompleted: @escaping (_ touches: Set<UITouch>) -> Void) {
            self.touchCompletion = touchCompleted
        }

        func onTrackingChanged(_ action: @escaping (_ value: Bool) -> Void) {
            self.trackingChanged = action
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesBegan(touches, with: event)
            isTracking = true
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesEnded(touches, with: event)
            isTracking = false
            touchCompletion?(touches)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesCancelled(touches, with: event)
            isTracking = false
        }
    }

}
