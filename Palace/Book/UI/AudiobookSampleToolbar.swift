//
//  AudiobookSampleToolbar.swift
//  Palace
//
//  Created by Maurice Carrier on 8/16/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI
import Combine

struct AudiobookSampleToolbar: View {
  typealias Images = ImageProviders.AudiobookSampleToolbar
  @ObservedObject var player: AudiobookSamplePlayer

  private var book: TPPBook
  private let imageLoader = AsyncImage(image: UIImage(systemName: "book.closed.fill")!)
  private let toolbarHeight: CGFloat = 70
  private let toolbarPadding: CGFloat = 5
  private let imageViewHeight: CGFloat = 70
  private let playbackButtonLength: CGFloat = 35
  private let buttonViewSpacing: CGFloat = 10

  init?(book: TPPBook) {
    self.book = book
//    self.isPlaying = self.$player.isPlaying.wrappedValue
//    guard let sample = book.samples.first as? AudiobookSample else { return nil }
    let sample = AudiobookSample(url: URL(string:"https://excerpts.cdn.overdrive.com/FormatType-425/1191-1/240440-TheLostSymbol.mp3")!)
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

  @ViewBuilder var imageView: some View {
    Image(uiImage: TPPBookRegistry.shared().cachedThumbnailImage(for: book) ?? imageLoader.image)
      .resizable()
      .aspectRatio(contentMode: .fit)
      .frame(width: imageViewHeight)
  }

  var infoView: some View {
    VStack(alignment: .leading) {
      Text(book.title)
        .bold()
      Text(player.remainingTime.displayFormat())
    }
  }

  var buttonView: some View {
    HStack(spacing: buttonViewSpacing) {
      playbackButton
      playButton
    }
  }
  
  var playbackButton: some View {
    Button {
      player.goBack()
    } label: {
      Images.stepBack
        .resizable()
        .square(length: playbackButtonLength)
        .padding(.trailing)
    }
  }

  var playButton: some View {
    // TODO: Present error if sample play fails
    Button {
      switch player.state {
      case .paused:
        try? player.playAudiobook()
      case .playing:
        player.pauseAudiobook()
      default:
        return
      }
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
    }
  }

  @ViewBuilder private var loadingView: some View {
    AnyView {
      ActivityIndicator(isAnimating: $player.isLoading, style: .medium)
        .foregroundColor(.black)
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
