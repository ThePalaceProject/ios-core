//
//  BookCell.swift
//  Palace
//
//  Created by Maurice Work on 1/5/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import SwiftUI

enum BookCellState {
  case normal
  case downloading
  case downloadFailed
}

struct BookCell: View {
  private var imageLoader = AsyncImage(image: UIImage())
  private var book: TPPBook
  private let imageViewHeight: CGFloat = 70
  
  init(book: TPPBook) {
    self.book = book
    if let imageURL = book.imageThumbnailURL ?? book.imageURL  {
      imageLoader.loadImage(url: imageURL)
    }
  }
  
  var body: some View {
    HStack {
      imageView
      VStack {
        infoView
//        buttons
      }
      Spacer()
    }
  }
  
  @ViewBuilder private var imageView: some View {
    ZStack {
      Image(uiImage: TPPBookRegistry.shared.cachedThumbnailImage(for: book) ?? imageLoader.image)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: imageViewHeight)
      audiobookIndicator
    }
  }

  @ViewBuilder private var audiobookIndicator: some View {
    EmptyView()
  }

  @ViewBuilder private var infoView: some View {
    VStack(alignment: .leading) {
      Text(book.title)
      Text(book.authors ?? "")
        .font(.footnote)
    }
    .padding(.leading, 5)
  }
//
//  @ViewBuilder private var buttons: some View {
//    HStack {
//      ForEach(buttons()) {
//        $0
//      }
//    }
//  }
  
//  private func buttons() -> [TPPBookButton] {
//    []
//  }
}

//struct TPPBookButton {
//
//}
