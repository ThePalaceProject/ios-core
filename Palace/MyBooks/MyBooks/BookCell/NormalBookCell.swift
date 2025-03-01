//
//  NormalBookCell.swift
//  Palace
//
//  Created by Maurice Carrier on 2/8/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//


import SwiftUI
import Combine
import PalaceUIKit

struct NormalBookCell: View {
  @ObservedObject var model: BookCellModel
  private let cellHeight: CGFloat = 125
  private let imageViewWidth: CGFloat = 100

  var body: some View {
    HStack(alignment: .center) {
      unreadImageView
      titleCoverImageView
      VStack(alignment: .leading) {
        infoView
        Spacer()
        buttons
          .padding(.bottom, 10)
      }
      .alert(item: $model.showAlert) { alert in
        Alert(
          title: Text(alert.title),
          message: Text(alert.message),
          primaryButton: .default(Text(alert.buttonTitle ?? ""), action: alert.primaryAction),
          secondaryButton: .cancel(alert.secondaryAction)
        )
      }
      Spacer()
    }
    .multilineTextAlignment(.leading)
    .padding(5)
    .frame(height: cellHeight)
    .onDisappear { model.isLoading = false }
  }
  
  @ViewBuilder private var titleCoverImageView: some View {
    ZStack {
      Image(uiImage: model.image)
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
        .lineLimit(2)
        .palaceFont(size: 17)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(model.book.defaultBookContentType == .audiobook ? "\(model.book.title). Audiobook." : model.book.title)
      Text(model.authors)
        .palaceFont(size: 12)
    }
  }
  
  @ViewBuilder private var buttons: some View {
    HStack {
      ForEach(model.buttonTypes, id: \.self) { type in
        ButtonView(
          title: type.localizedTitle.capitalized,
          indicatorDate: model.indicatorDate(for: type),
          action: { model.callDelegate(for: type) }
        )
        .disabled(model.isLoading || type.isDisabled)
        .opacity(model.isLoading || type.isDisabled ? 0.5 : 1.0)
        .palaceFont(.body)
      }
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
}
