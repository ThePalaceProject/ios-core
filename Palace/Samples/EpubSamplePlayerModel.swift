//
//  EpubSamplePlayerModel.swift
//  Palace
//
//  Created by Maurice Carrier on 8/23/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation
import Combine

enum EpubSamplePlayerState {
  case initalized
  case loading
  case loaded(URL)
  case error(TPPUserFriendlyError)
}

extension EpubSamplePlayerState: Equatable {
  static func == (lhs: EpubSamplePlayerState, rhs: EpubSamplePlayerState) -> Bool {
    switch (lhs, rhs) {
    case (.initalized, .initalized):
      return true
    case (.loading, .loading):
      return true
    case (let .loaded(lhsURL), let .loaded(rhsURL)):
      return lhsURL == rhsURL
    case (let .error(lhsTPPError), let .error(rhsTPPError)):
      return lhsTPPError.userFriendlyTitle == rhsTPPError.userFriendlyTitle
    default:
      return false
    }
  }
}

class EpubSamplePlayerModel: ObservableObject {
  enum State {
    case initalized
    case loading
    case loaded(Data?, URL?)
    case error(TPPUserFriendlyError)
  }

  @Published var isLoading: Bool = false
  @Published var state: EpubSamplePlayerState = .initalized {
    didSet {
      self.isLoading = self.state == .loading
    }
  }

  var book: TPPBook

  var sample: EpubSample {
    didSet {
      downloadData()
    }
  }

  init?(book: TPPBook) {
    self.book = book
    guard let epubSample = book.sample as? EpubSample
    else {
      return nil
    }

    self.sample = epubSample
    setup()
  }

  private func setup() {
    state = .loading

    if sample.type.needsDownload {
      downloadData()
      state = .loaded(sample.url)
    } else {
      state = .loaded(sample.url)
    }
  }

  private func downloadData() {
    TPPNetworkExecutor.shared.GET(sample.url) { result in
      switch result {
      case .failure(let error, _):
        self.state = .error(error)
      case .success:
        DispatchQueue.main.async {
          self.state = .loaded(self.sample.url)
        }
      }
    }
  }
}
