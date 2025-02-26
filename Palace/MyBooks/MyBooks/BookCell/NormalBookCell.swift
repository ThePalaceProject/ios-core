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
    HStack(alignment: .center, spacing: 20) {
      HStack(spacing: 5) {
        unreadImageView
        titleCoverImageView
      }

      VStack(alignment: .leading, spacing: 10) {
        infoView
        buttons
          .padding(.bottom, 5)
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
    .frame(minHeight: 125)
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

  private var buttonSize: ButtonSize {
    UIDevice.current.isIpad && UIDevice.current.orientation != .portrait ? .small : .medium
  }

  @ViewBuilder private var buttons: some View {
    VStack(alignment: .leading, spacing: 0) {
      BookButtonsView(provider: model, size: buttonSize) { type in
        model.callDelegate(for: type)
      }
      borrowedInfoView
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

  @ViewBuilder var borrowedInfoView: some View {
    if let availableUntil = model.book.getExpirationDate()?.monthDayYearString {
      Text("Borrowed until \(availableUntil)")
        .fixedSize(horizontal: false, vertical: true)
        .minimumScaleFactor(0.5)
        .font(.subheadline)
        .foregroundColor(.secondary)
    }
  }
}
