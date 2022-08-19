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
  @ObservedObject var player: AudiobookSamplePlayer
  var book: TPPBook

  init?(book: TPPBook) {
    self.book = book
//    self.isPlaying = self.$player.isPlaying.wrappedValue
//    guard let sample = book.samples.first as? AudiobookSample else { return nil }
    let sample = AudiobookSample(url: URL(string:"https://excerpts.cdn.overdrive.com/FormatType-425/1191-1/240440-TheLostSymbol.mp3")!)
    player = AudiobookSamplePlayer(sample: sample)
  }

  var body: some View {
    HStack {
      imageView
      infoView
      Spacer()
      buttonView
    }
    .frame(height: 70)
    .padding(5)
    .background(Color.init(.lightGray))
    .onDisappear {
      player.pauseAudiobook()
    }
  }

  @ViewBuilder var imageView: some View {
    if let image = TPPBookRegistry.shared().cachedThumbnailImage(for: book) {
      Image(uiImage: image)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 50)
    }
  }
  
  var infoView: some View {
    VStack(alignment: .leading) {
      Text(book.title)
        .bold()
      Text(player.remainingTime.displayFormat())
    }
  }

  var buttonView: some View {
    HStack(spacing: 10) {
      playbackButton
      playButton
    }
  }
  
  var playbackButton: some View {
    Button {
      player.goBack()
    } label: {
      Image(systemName: "gobackward.30")
        .resizable()
        .square(length: 40)
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
      switch player.state {
      case .paused:
        ImageProviders.AudiobookSampleToolbar.play
          .resizable()
          .square(length: 40)
          .padding(.trailing)
      case .playing:
        ImageProviders.AudiobookSampleToolbar.pause
          .resizable()
          .square(length: 40)
          .padding(.trailing)
      default:
        loadingView
      }
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

extension TimeInterval {
  func displayFormat() -> String {
    let ti = NSInteger(self)
    let seconds = ti % 60
    let minutes = (ti / 60) % 60
  
    return "\(minutes)m \(seconds)s left"
  }
}
