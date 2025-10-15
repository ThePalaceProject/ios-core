//
//  AsyncImage.swift
//  Palace
//
//  Created by Maurice Carrier on 8/19/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//  https://www.swiftbysundell.com/tips/constant-combine-publishers/

import SwiftUI
import Combine
import Foundation

class ImageLoader {
  private let urlSession: URLSession
  
  init(urlSession: URLSession = .shared) {
    self.urlSession = urlSession
  }
  
  func publisher(for url: URL) -> AnyPublisher<UIImage, Error> {
    urlSession.dataTaskPublisher(for: url)
      .map(\.data)
      .tryMap { data in
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
          throw URLError(.badServerResponse, userInfo: [
            NSURLErrorFailingURLErrorKey: url,
            NSLocalizedDescriptionKey: "Invalid image data"
          ])
        }
        return image
      }
      .receive(on: DispatchQueue.main)
      .eraseToAnyPublisher()
  }
}

@MainActor
class AsyncImage: ObservableObject {
  @Published var image: UIImage
  private var cancellable: AnyCancellable?
  private let imageLoader = ImageLoader()
  
  init(image: UIImage) {
    self.image = image
  }
  
  func loadImage(url: URL) {
    self.cancellable = imageLoader.publisher(for: url)
      .sink(receiveCompletion: { result in
        switch result {
        case .failure(let error):
          TPPErrorLogger.logError(error, summary: "Failed to load image")
        default:
          return
        }
      }, receiveValue: { [weak self] image in
        self?.image = image
      })
  }
}
