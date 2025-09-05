//
//  AudiobookSampleToolbar.swift
//  Palace
//
//  Created by Maurice Carrier on 8/16/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI
import PalaceUIKit

struct AudiobookSampleToolbar: View {
  typealias Images = ImageProviders.AudiobookSampleToolbar
  @ObservedObject var player: AudiobookSamplePlayer

  private var book: TPPBook
  private let imageLoader = AsyncImage(image: UIImage(systemName: "book.closed.fill") ?? UIImage())
  private let toolbarHeight: CGFloat = 70
  private let toolbarPadding: CGFloat = 5
  private let imageViewHeight: CGFloat = 70
  private let playbackButtonLength: CGFloat = 35
  private let buttonViewSpacing: CGFloat = 10

  init?(book: TPPBook) {
    self.book = book
    guard let sample = book.sample as? AudiobookSample else { return nil }
    player = AudiobookSamplePlayer(sample: sample)
    if let imageURL = book.imageThumbnailURL ?? book.imageURL {
      imageLoader.loadImage(url: imageURL)
    }
  }

  var body: some View {
    HStack {
      imageView
      infoView
      Spacer()
      buttonView
    }
    .frame(height: toolbarHeight)
    .padding(toolbarPadding)
    .background(Color.init(.lightGray))
    .onDisappear {
      player.pauseAudiobook()
    }
  }

  @ViewBuilder private var imageView: some View {
    Image(uiImage: TPPBookRegistry.shared.cachedThumbnailImage(for: book) ?? imageLoader.image)
      .resizable()
      .aspectRatio(contentMode: .fit)
      .frame(width: imageViewHeight)
  }

  private var infoView: some View {
    VStack(alignment: .leading) {
      Text(book.title)
        .palaceFont(.body, weight: .bold)
      Text(player.remainingTime.displayFormat())
        .palaceFont(.body)
    }
  }

  private var buttonView: some View {
    HStack(spacing: buttonViewSpacing) {
      playbackButton
      playButton
    }
  }

  private var playButton: some View {
    Button {
      togglePlay()
    } label: {
      playButtonImage
    }
  }

  @ViewBuilder private var playButtonImage: some View {
    switch player.state {
    case .paused:
      Images.play
        .resizable()
        .square(length: playbackButtonLength)
        .padding(.trailing)
    case .playing:
      Images.pause
        .resizable()
        .square(length: playbackButtonLength)
        .padding(.trailing)
    default:
      loadingView
        .square(length: playbackButtonLength)
        .padding(.trailing)
    }
  }

  private func togglePlay() {
    switch player.state {
    case .paused:
      try? player.playAudiobook()
    case .playing:
      player.pauseAudiobook()
    default:
      return
    }
  }

  private var playbackButton: some View {
    Button {
      player.goBack()
    } label: {
      Images.stepBack
        .resizable()
        .square(length: playbackButtonLength)
        .padding(.trailing)
    }
  }

  @ViewBuilder private var loadingView: some View {
    withAnimation {
      ProgressView()
        .progressViewStyle(CircularProgressViewStyle())
        .scaleEffect(1.25)
        .transition(.opacity)
    }
  }
}

@objc class AudiobookSampleToolbarWrapper: NSObject {

  @objc static func create(book: TPPBook) -> UIViewController {
    let toolbar = AudiobookSampleToolbar(book: book)
    let hostingController = UIHostingController(rootView: toolbar)
    return hostingController
  }
}

private extension TimeInterval {
  func displayFormat() -> String {
    let ti = NSInteger(self)
    let seconds = ti % 60
    let minutes = (ti / 60) % 60
  
    return "\(minutes)m \(seconds)s left"
  }
}
