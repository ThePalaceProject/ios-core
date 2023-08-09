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
  private let cellHeight = 125.0
  @State private var progress = 0.0
  var downloadPublisher = NotificationCenter.default.publisher(for: NSNotification.Name.TPPMyBooksDownloadCenterDidChange)
  
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
    .background(Color(TPPConfiguration.mainColor()))
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
    .font(Font(uiFont: UIFont.palaceFont(ofSize: 12)))
    .foregroundColor(Color(TPPConfiguration.backgroundColor()))
    .onReceive(downloadPublisher) { _ in
      self.progress = MyBooksDownloadCenter.shared.downloadProgress(for: model.book.identifier)
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
