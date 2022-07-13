//
//  TPPEncryptedPDFViewer.swift
//  Palace
//
//  Created by Vladimir Fedorov on 01.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI

/// Encrypted PDF viewer class.
/// Plays the same role as PDFKit's `PDFView` — displays a PDF page, performs swipe navigation between pages.
/// Wraps `TPPEncryptedPDFViewController` — `UIPageViewController`
struct TPPEncryptedPDFViewer: UIViewControllerRepresentable {
  
  let encryptedPDF: TPPEncryptedPDFDocument
  
  @Binding var currentPage: Int
  
  func makeUIViewController(context: Context) -> some UIViewController {
    let vc = TPPEncryptedPDFViewController(encryptedPDF: encryptedPDF)
    vc.currentPage = currentPage
    vc.delegate = context.coordinator
    return vc
  }
  
  func updateUIViewController(_ uiViewController: UIViewControllerType, context: Context) {
    guard let vc = uiViewController as? TPPEncryptedPDFViewController else {
      return
    }
    if vc.currentPage != currentPage {
      vc.navigate(to: currentPage)
    }
  }
  
  func makeCoordinator() -> Coordinator {
    return Coordinator(currentPage: $currentPage)
  }
  
  class Coordinator: NSObject, UIPageViewControllerDelegate {
    @Binding var currentPage: Int
    
    init(currentPage: Binding<Int>) {
      self._currentPage = currentPage
    }
    
    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
      guard let pageVC = pageViewController as? TPPEncryptedPDFViewController, let vc = pageViewController.viewControllers?.last as? TPPEncryptedPDFPageViewController else {
        return
      }
      if currentPage != vc.pageNumber {
        pageVC.currentPage = vc.pageNumber
        currentPage = vc.pageNumber
      }
    }
  }
}


