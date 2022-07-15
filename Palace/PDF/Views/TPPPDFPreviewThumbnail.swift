//
//  TPPPDFPreviewThumbnail.swift
//  Palace
//
//  Created by Vladimir Fedorov on 12.07.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI

/// Single page thumbnail view
struct TPPPDFPreviewThumbnail: View {
  
  @ObservedObject var thumbnailGenerator: ThumbnailFetcher
  let document: TPPEncryptedPDFDocument
  let index: Int
  let size: CGSize
  
  init(document: TPPEncryptedPDFDocument, index: Int, size: CGSize) {
    self.document = document
    self.index = index
    self.size = size
    self._thumbnailGenerator = ObservedObject(wrappedValue: ThumbnailFetcher(document: document, index: index))
  }
  
  var body: some View {
    Image(uiImage: thumbnailGenerator.image)
      .resizable()
      .aspectRatio(contentMode: .fit)
      .frame(width: size.width, height: size.height)
      .background(Color(UIColor.secondarySystemBackground))
      .border(.gray)
  }
  
  /// Ths view needs an observable object to correctly update selected page thumbnail
  /// Without it the thimbnail will always contain the first assigned image
  /// It seems SwiftUI optimizes that
  class ThumbnailFetcher: ObservableObject {
    let document: TPPEncryptedPDFDocument
    let index: Int
    @Published var image: UIImage
    init(document: TPPEncryptedPDFDocument, index: Int) {
      self.document = document
      self.index = index
      if let cachedThumbnail = document.cachedThumbnail(for: index) {
        self.image = cachedThumbnail
      } else {
        self.image = UIImage()
        fetchThumbnail()
      }
    }
    
    private func fetchThumbnail() {
      DispatchQueue.pdfThumbnailRenderingQueue.async {
        let thumbnail = self.document.thumbnail(for: self.index)
        DispatchQueue.main.async {
          if let thumbnail = thumbnail {
            self.image = thumbnail
          }
        }
      }
    }
  }

}
