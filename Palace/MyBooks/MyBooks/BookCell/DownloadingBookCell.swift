//
//  DownloadingBookCell.swift
//  Palace
//
//  Created by Maurice Carrier on 2/8/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import SwiftUI

struct DownloadingBookCell: View {
  @ObservedObject var model: BookCellModel
  private let cellHeight: CGFloat = 135
  @State private var progress = 0.0
  var downloadPublisher = NotificationCenter.default.publisher(for: NSNotification.Name.TPPMyBooksDownloadCenterDidChange)
  
  var body: some View {
    ZStack {
      VStack(alignment: .leading) {
        infoView
        statusView
        buttons
      }
      .padding()
      .frame(height: cellHeight)
      .background(Color(TPPConfiguration.mainColor()))
      overlay
    }
  }

  @ViewBuilder private var infoView: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(model.title)
        .font(Font(uiFont: UIFont.palaceFont(ofSize: 17)))
      Text(model.authors)
        .font(Font(uiFont: UIFont.palaceFont(ofSize: 12)))
    }
    .foregroundColor(Color(TPPConfiguration.backgroundColor()))
  }
  
  @ViewBuilder private var statusView: some View {
    switch model.state.buttonState {
    case .downloadFailed:
      Text(Strings.BookCell.downloadFailedMessage)
        .horizontallyCentered()
        .padding(.top, 5)
        .font(Font(uiFont: UIFont.palaceFont(ofSize: 12)))
        .foregroundColor(Color(TPPConfiguration.backgroundColor()))
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
    .font(Font(uiFont: UIFont.palaceFont(ofSize: 12)))
    .foregroundColor(Color(TPPConfiguration.backgroundColor()))
    .onReceive(downloadPublisher) { _ in
      self.progress = TPPMyBooksDownloadCenter.shared().downloadProgress(forBookIdentifier: model.book.identifier)
    }
  }

  @ViewBuilder private var buttons: some View {
    HStack {
      Spacer()
      ForEach(model.buttonTypes, id: \.self) { type in
        ButtonView(
          title: type.localizedTitle.capitalized,
          indicatorDate: model.indicatorDate(for: type),
          backgroundFill: Color(TPPConfiguration.backgroundColor())) {
          model.callDelegate(for: type)
        }
      }
      Spacer()
    }
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
