//
//  WithEvents.swift
//  Palace
//
//  Created by Maurice Carrier on 10/25/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import Foundation
import Combine

protocol WithEvents: AnyObject {
  associatedtype Event
  
  typealias EventSubject = PassthroughSubject<Event, Never>
  typealias EventCompletionClosure = (Event) -> Void
  
  var eventInput: EventSubject { get }
  var eventObserver: AnyCancellable? { get set }
}

extension WithEvents {
  func sendEvents(to input: EventSubject?) -> Self {
    guard let input = input else { return self }
    
    eventObserver?.cancel()
    eventObserver = eventInput
      .sink { input.send($0) }
    
    return self
  }

  func sinkEvents(to completion: @escaping EventCompletionClosure) -> Self {
    eventObserver?.cancel()
    eventObserver = eventInput
      .sink { completion($0) }
    
    return self
  }

  func sendEvent(_ event: Event) {
    eventInput.send(event)
  }
}
