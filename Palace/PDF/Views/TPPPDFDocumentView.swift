//
//  TPPPDFDocumentView.swift
//  Palace
//
//  Created by Vladimir Fedorov on 20.05.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI
import PDFKit
import Combine

struct TPPPDFDocumentView: UIViewRepresentable {
  
  var document: PDFDocument
  var pdfView: PDFView
  @Binding var showingDocumentInfo: Bool
  
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
    pdfView.addGestureRecognizer(pdfViewGestureRecognizer)

    NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: nil, queue: nil) { _ in
      if let page = pdfView.currentPage, let pageIndex = pdfView.document?.index(for: page) {
        if pdfViewGestureRecognizer.isTracking {
          showingDocumentInfo = false
        }
        metadata.currentPage = pageIndex
      }
    }
    
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
  
  class Coordinator: NSObject, PDFViewDelegate {
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
  
  class PDFViewGestureRecognizer: UITapGestureRecognizer {
    var isTracking = false
    var touchCompletion: ((_ touches: Set<UITouch>) -> Void)?
        
    func onTouchEnded(_ touchCompleted: @escaping (_ touches: Set<UITouch>) -> Void) {
      self.touchCompletion = touchCompleted
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
