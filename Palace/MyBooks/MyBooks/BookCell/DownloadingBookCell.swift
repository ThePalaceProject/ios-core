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
  private let cellHeight: CGFloat = 125
  @State private var progress = 0.0
  var downloadPublisher = NotificationCenter.default.publisher(for: NSNotification.Name.TPPMyBooksDownloadCenterDidChange)
  
  
  var body: some View {
    VStack(alignment: .leading) {
      infoView
      progressView
      buttons
    }
    .padding([.leading, .trailing])
    .frame(height: cellHeight)
    .background(Color(TPPConfiguration.mainColor()))
  }

  @ViewBuilder private var infoView: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(model.title)
        .font(.headline)
      Text(model.authors)
        .font(.subheadline)
    }
    .foregroundColor(Color(TPPConfiguration.backgroundColor()))
  }
  
  @ViewBuilder private var progressView: some View {
    HStack {
      Text(Strings.BookCell.downloading)
      ProgressView(value: progress, total: 1)
        .progressViewStyle(LinearProgressViewStyle(tint: Color(TPPConfiguration.backgroundColor())))
      Text("\(Int(progress * 100))%")
    }
    .font(.subheadline)
    .foregroundColor(Color(TPPConfiguration.backgroundColor()))
    .onReceive(downloadPublisher) { _ in
      print("MYDebugger Title: \(model.book.title) downloading progress: \(TPPMyBooksDownloadCenter.shared().downloadProgress(forBookIdentifier: model.book.identifier))")
      self.progress = TPPMyBooksDownloadCenter.shared().downloadProgress(forBookIdentifier: model.book.identifier)
    }
  }

  @ViewBuilder private var buttons: some View {
    HStack {
      Spacer()
      ForEach(model.buttonTypes, id: \.self) { type in
        ButtonView(
          title: type.localizedTitle.capitalized,
          backgroundFill: Color(TPPConfiguration.backgroundColor())) {
          model.callDelegate(for: type)
        }
      }
      Spacer()
    }
  }
}
