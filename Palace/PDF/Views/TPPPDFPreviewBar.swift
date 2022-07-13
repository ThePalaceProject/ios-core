//
//  TPPPDFPreviewBar.swift
//  Palace
//
//  Created by Vladimir Fedorov on 01.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI

/// Bottom bar with page thumbnails
/// Performs similar to PDFKit's `PDFThumbnails` view.
struct TPPPDFPreviewBar: View {
  
  private let barPreviewsHeight = 24.0
  private let barPreviewsSpacing = 3.0
  private let selectedPreviewHeight = 30.0

  private var previewSize: CGSize {
    let h = self.barPreviewsHeight
    let w = h * 3 / 4
    return CGSize(width: w, height: h)
  }
  
  private var selectedPreviewSize: CGSize {
    let h = self.selectedPreviewHeight
    let w = h * 3 / 4
    return CGSize(width: w, height: h)
  }
  
  let document: TPPEncryptedPDFDocument
  @Binding var currentPage: Int
  @State var currentPageValue: Double = 0
  @State var currentPageNeedsUpdate: Bool = false

  @State private var tick = Timer.publish(every: 0.5, on: .main, in: .common)
  
  @State private var previewsAreaSize: CGSize = .zero
  @State private var previewsBarSize: CGSize = .zero
  @State private var touchLocation: CGPoint = .zero
  
  var body: some View {
    VStack(alignment: .center) {
      Divider()
      ZStack {
        HStack(spacing: barPreviewsSpacing) {
          ForEach(previewIndices(for: previewsAreaSize), id: \.self) { index in
            TPPPDFPreviewThumbnail(document: document, index: index, size: previewSize)
          }
        }
        .contentShape(Rectangle())
        .frame(height: barPreviewsHeight)
        .readSize { size in
          previewsBarSize = size
        }
        .onTouchDownUp { pressed, value in
          touchLocation = pressed ? value.location : .zero
          if pressed {
            currentPage = page(for: touchLocation, in: previewsBarSize)
          }
        }

        TPPPDFPreviewThumbnail(document: document, index: currentPage, size: selectedPreviewSize)
          .offset(currentPageThumbnailOffset(in: previewsBarSize))
      }
    }
    .frame(maxWidth: .infinity)
    .background(
      Color(UIColor.systemBackground)
        .edgesIgnoringSafeArea(.bottom)
    )
    .readSize { size in
      previewsAreaSize = size
    }
    .onReceive(tick) { _ in
      // Synchronizes currentPage Int value and curentPageValue Double value
      // to limit the frequency of current page changes
      if currentPageNeedsUpdate {
        currentPageNeedsUpdate = false
        currentPage = Int(currentPageValue)
      } else {
        if currentPage != Int(currentPageValue) {
          currentPageValue = Double(currentPage)
        }
      }
    }
    .onAppear {
      // When the view appears, it requests a lot of page thumnails
      // A 1-second delay helps them to get first in the queue
      // and makes the view look more responsive
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        document.makeThumbnails()
      }
    }
  }
  
  /// Array of visible page indices
  /// - Parameter size: Bar size
  /// - Returns: Array of indices
  private func previewIndices(for size: CGSize) -> [Int] {
    let numberOfPreviews = Int(size.width / (previewSize.width + barPreviewsSpacing))
    let stride = max(1, Double(document.pageCount) / Double(numberOfPreviews))
    var result: [Int] = []
    for i in 0..<numberOfPreviews {
      result.append(Int(stride * Double(i)))
    }
    return result
  }
  
  /// Page index for location point on the bar
  /// - Parameters:
  ///   - location: Location point on the bar
  ///   - rect: Bar size
  /// - Returns: Page index for location point on the bar
  private func page(for location: CGPoint, in rect: CGSize) -> Int {
    let numberOfPages = Double(document.pageCount)
    let loc = max(0, min(rect.width, location.x))
    return max(0, min(document.pageCount - 1, Int(numberOfPages * (loc / rect.width))))
  }
  
  /// Offset for current page thumbnail
  /// - Parameter rect: Bar size
  /// - Returns: offset `CGSize` value for `.offset` view modifier
  private func currentPageThumbnailOffset(in rect: CGSize) -> CGSize {
    let page = Double(currentPage)
    let numberOfPages = Double(document.pageCount)
    let w = rect.width * (page / numberOfPages) - rect.width / 2
    let h = rect.height / 2 - barPreviewsHeight / 2
    return CGSize(width: w, height: h)
  }
  
}
