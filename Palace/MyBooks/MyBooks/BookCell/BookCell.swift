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
  @ObservedObject private var model: BookCellModel
  @State private var image = ImageProviders.MyBooksView.bookPlaceholder ?? UIImage()

  private let cellHeight: CGFloat = 125
  private let imageViewWidth: CGFloat = 100
  
  init(model: BookCellModel) {
    self.model = model
    loadImage()
  }

  var body: some View {
    ZStack {
      loadingView
      HStack(alignment: .center) {
        unreadImageView
        imageView
        VStack(alignment: .leading) {
          infoView
          Spacer()
          buttons
        }
        .alert(item: $model.showAlert) { alert in
          Alert(
            title: Text(alert.title),
            message: Text(alert.message),
            primaryButton: .default(Text(alert.buttonTitle), action: alert.primaryAction),
            secondaryButton: .cancel(alert.secondaryAction)
          )
        }
      }
      .opacity(model.isLoading ? 0.75 : 1.0)
      .disabled(model.isLoading)
      .frame(height: cellHeight)
      .onDisappear { model.isLoading = false }
      .onAppear(perform: loadImage)
    }
  }
  
  @ViewBuilder private var imageView: some View {
    ZStack {
      Image(uiImage: TPPBookRegistry.shared.cachedThumbnailImage(for: model.book) ?? image)
        .resizable()
        .aspectRatio(contentMode: .fit)
      audiobookIndicator
    }
    .frame(width: imageViewWidth)
    .padding(.trailing, 2)
  }

  @ViewBuilder private var audiobookIndicator: some View {
    if model.book.defaultBookContentType == .audiobook {
      ImageProviders.MyBooksView.audiobookBadge
        .resizable()
        .frame(width: 24, height: 24)
        .background(Color(TPPConfiguration.palaceRed()))
        .bottomrRightJustified()
    }
  }
  
  @ViewBuilder private var infoView: some View {
    VStack(alignment: .leading) {
      Text(model.title)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(model.book.defaultBookContentType == .audiobook ? "\(model.book.title). Audiobook." : "")
      Text(model.authors)
        .font(.footnote)
    }
  }
  
  @ViewBuilder private var buttons: some View {
    HStack {
      ForEach(model.buttonTypes, id: \.self) {
        buttonView(type: $0)
      }
    }
  }
  
  @ViewBuilder private var loadingView: some View {
    if model.isLoading {
      ProgressView()
    }
  }
  
  @ViewBuilder private var unreadImageView: some View {
      VStack {
        ImageProviders.MyBooksView.unreadBadge
          .resizable()
          .frame(width: 10, height: 10)
          .foregroundColor(Color(TPPConfiguration.accentColor()))
        Spacer()
      }
      .opacity(model.showUnreadIndicator ? 1.0 : 0.0)
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
  
  private func loadImage() {
    guard TPPBookRegistry.shared.cachedThumbnailImage(for: model.book) == nil else { return }
    TPPBookRegistry.shared.thumbnailImage(for: model.book) { image in
      guard let image = image else { return }
      self.image = image
    }
  }
}
