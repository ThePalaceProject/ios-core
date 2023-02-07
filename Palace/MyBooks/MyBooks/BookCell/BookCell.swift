//
//  BookCell.swift
//  Palace
//
//  Created by Maurice Carrier on 1/5/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import SwiftUI
import Combine

struct BookCell: View {
  private var model: BookCellModel
  private var imageLoader = AsyncImage(image: ImageProviders.MyBooksView.bookPlaceholder ?? UIImage())
  private let imageViewHeight: CGFloat = 70
  
  init(model: BookCellModel) {
    self.model = model
    if let url = model.imageURL {
      imageLoader.loadImage(url: url)
    }
  }
  
  var body: some View {
    HStack(alignment: .top) {
      imageView
      VStack(alignment: .leading, spacing: 20) {
        infoView
        buttons
      }
    }
  }
  
  //TODO: Revisit ASYNC image failing to load image
  @ViewBuilder private var imageView: some View {
    ZStack {
      Image(uiImage: TPPBookRegistry.shared.cachedThumbnailImage(for: model.book) ?? imageLoader.image)
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
      Text(model.title)
      Text(model.authors)
        .font(.footnote)
    }
    .padding(.bottom, 10)
  }
  
  @ViewBuilder private var buttons: some View {
    HStack {
      ForEach(model.buttonTypes, id: \.self) {
        buttonView(type: $0)
      }
    }
  }
  
  private func buttonView(type: BookButtonType) -> some View {
    Button (action: { model.callDelegate(for: type) }) {
      Text(type.localizedTitle.capitalized)
        .padding()
    }
    .buttonStyle(.plain)
    .overlay(
      RoundedRectangle(cornerRadius: 2)
        .stroke(Color(TPPConfiguration.mainColor()), lineWidth: 1)
        .frame(height: 35)
    )
  }
}
