//
//  DownloadingBookCell.swift
//  Palace
//
//  Created by Maurice Carrier on 2/8/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import SwiftUI
import PalaceUIKit

struct DownloadingBookCell: View {
  @ObservedObject var model: BookCellModel
  private let cellHeight = 125.0
  @State private var progress = 0.0
  var downloadPublisher = NotificationCenter.default.publisher(for: NSNotification.Name.TPPMyBooksDownloadCenterDidChange)
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    ZStack {
      VStack(alignment: .leading) {
        infoView
        statusView
        buttons
      }
      .multilineTextAlignment(.leading)
      .padding()
      .frame(height: cellHeight)
      overlay
    }
    .padding()
    .background(Color(TPPConfiguration.mainColor()))
  }

  @ViewBuilder private var infoView: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(model.title)
        .palaceFont(size: 17)
      Text(model.authors)
        .palaceFont(size: 12)
    }
    .foregroundColor(Color(TPPConfiguration.backgroundColor()))
  }
  
  @ViewBuilder private var statusView: some View {
    switch model.state.buttonState {
    case .downloadFailed:
      Text(Strings.BookCell.downloadFailedMessage)
        .horizontallyCentered()
        .padding(.top, 5)
        .palaceFont(size: 12)
        .foregroundColor(Color(TPPConfiguration.mainColor()))
    default:
      progressView
    }
  }

  @ViewBuilder private var progressView: some View {
    HStack {
      Text(Strings.BookCell.downloading)
      ProgressView(value: progress, total: 1)
        .progressViewStyle(LinearProgressViewStyle(tint: Color(TPPConfiguration.backgroundColor())))
      Text("\(Int(progress * 100))%")
    }
    .palaceFont(size: 12)
    .foregroundColor(Color(TPPConfiguration.backgroundColor()))
    .onReceive(downloadPublisher) { _ in
      self.progress = MyBooksDownloadCenter.shared.downloadProgress(for: model.book.identifier)
    }
  }

  @ViewBuilder private var buttons: some View {
    BookButtonsView(provider: model, backgroundColor: colorScheme == .dark ? .white : .black, size: .medium) { type in
      model.callDelegate(for: type)
    }
    .horizontallyCentered()
  }

  @ViewBuilder private var overlay: some View {
    switch model.state.buttonState {
    case .downloadFailed:
      Color.black.opacity(0.25)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    default:
      EmptyView()
    }
  }
}
