//
//  Publisher+Extensions.swift
//  Palace
//
//  Created by Maurice Carrier on 10/18/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import Foundation
import Combine

extension Publisher {
  public func sink(receiveResult: @escaping ((Swift.Result<Self.Output, Self.Failure>) -> Void)) -> AnyCancellable {
    sink(receiveCompletion: { completion in
      switch completion {
      case let .failure(error):
        receiveResult(.failure(error))
      case .finished: break
      }
    }) { receiveResult(.success($0)) }
  }
}

extension Publisher where Failure == Never {
  public func assign<Root: AnyObject>(
    to keyPath: ReferenceWritableKeyPath<Root, Output>,
    onWeak object: Root
  ) -> AnyCancellable {
    sink { [weak object] value in
      object?[keyPath: keyPath] = value
    }
  }
}
