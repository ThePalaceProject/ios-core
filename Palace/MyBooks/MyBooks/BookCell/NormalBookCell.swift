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
  @Environment(\.colorScheme) var colorScheme
  @State var showHalfSheet: Bool = false

  @ObservedObject var model: BookCellModel
  private let cellHeight: CGFloat = 125
  private let imageViewWidth: CGFloat = 100

  var body: some View {
    HStack(alignment: .center, spacing: 15) {
      HStack(spacing: 5) {
        unreadImageView
        titleCoverImageView
      }
      .frame(alignment: .leading)

      VStack(alignment: .leading, spacing: 10) {
        infoView
        VStack(alignment: .leading, spacing: 0) {
          buttons
          borrowedInfoView
        }
        .padding(.bottom, 5)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .sheet(isPresented: $showHalfSheet) {
        HalfSheetView(
          viewModel: model,
          backgroundColor: Color(model.book.coverImage?.mainColor() ?? .gray),
          coverImage: $model.book.coverImage
        )
      }
      .alert(item: $model.showAlert) { alert in
        Alert(
          title: Text(alert.title),
          message: Text(alert.message),
          primaryButton: .default(Text(alert.buttonTitle ?? ""), action: alert.primaryAction),
          secondaryButton: .cancel(alert.secondaryAction)
        )
      }
    }
    .multilineTextAlignment(.leading)
    .padding(5)
    .frame(minHeight: cellHeight)
    .onDisappear { model.isLoading = false }
  }

  @ViewBuilder private var titleCoverImageView: some View {
    ZStack(alignment: .bottomTrailing) {
      Image(uiImage: model.image)
        .resizable()
        .aspectRatio(contentMode: .fit)
      audiobookIndicator
        .padding([.trailing, .bottom], 5)
    }
    .frame(width: imageViewWidth)
  }

  @ViewBuilder private var audiobookIndicator: some View {
    if model.book.defaultBookContentType == .audiobook {
      ImageProviders.MyBooksView.audiobookBadge
        .resizable()
        .frame(width: 24, height: 24)
        .background(Circle().fill(Color.colorAudiobookBackground))
        .clipped()
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
      BookButtonsView(provider: model, size: buttonSize) { type in
        switch type {
        case .return:
            model.state = .normal(.returning)
            self.showHalfSheet = true
        case .manageHold:
          model.state = .normal(.managingHold)
          self.showHalfSheet = true
        case .close:
          self.showHalfSheet = false
        default:
          model.callDelegate(for: type)
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
  
  @ViewBuilder var borrowedInfoView: some View {
    if model.isManagingHold {
      holdingInfoView
    } else {
      loanTermsInfoView
    }
  }
  
  @ViewBuilder var holdingInfoView: some View {
    let details = model.book.getReservationDetails()
    Text(
      String(
        format: Strings.BookDetailView.holdStatus,
        details.holdPosition.ordinal(),
        details.copiesAvailable,
        details.copiesAvailable == 1 ? Strings.BookDetailView.copy : Strings.BookDetailView.copies
      )
    )
    .font(.footnote)
  }

  @ViewBuilder var loanTermsInfoView: some View {
    if let expirationDate = model.book.getExpirationDate() {
      HStack(alignment: .bottom, spacing: 10) {
        Text("Due \(expirationDate.monthDayYearString)")
          .font(.subheadline)
          .foregroundColor(.secondary)
        Spacer()
        Text("\(expirationDate.timeUntil().value) \(expirationDate.timeUntil().unit)")
          .foregroundColor(colorScheme == .dark ? .palaceSuccessLight : .palaceSuccessDark)
      }
      .palaceFont(size: 12)
      .minimumScaleFactor(0.8)
      .padding(.trailing)
    }
  }
}
