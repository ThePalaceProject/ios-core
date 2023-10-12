//
//  SearchViewModel.swift
//  Palace
//
//  Created by Maurice Carrier on 10/11/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import R2Shared
import R2Navigator

protocol EPUBSearchDelegate: class {
  func didSelect(location: Locator)
}

final class EPUBSearchViewModel: ObservableObject {
  enum State {
    case empty
    case starting(R2Shared.Cancellable?)
    case idle(SearchIterator)
    case loadingNext(SearchIterator, R2Shared.Cancellable?)
    case end
    case failure(LocalizedError)
  }
  
  @Published private(set) var state: State = .empty
  @Published private(set) var results: [Locator] = []
  
  private var publication: Publication
  weak var delegate: EPUBSearchDelegate?
  
  init(publication: Publication) {
    self.publication = publication
  }
  
  func search(with query: String) {
    cancelSearch()
    
    let cancellable = publication._search(query: query) { result in
      switch result {
      case .success(let iterator):
        self.state = .idle(iterator)
        self.fetchAllLocations(iterator: iterator)
        
      case .failure(let error):
        self.state = .failure(error)
      }
    }
    
    state = .starting(cancellable)
  }

  func fetchAllLocations(iterator: SearchIterator) {
    state = .loadingNext(iterator, nil)
    
    let cancellable = iterator.next { result in
      switch result {
      case .success(let collection):
        if let collection = collection {

          for locator in collection.locators {
            if !self.results.contains(where: { $0.href == locator.href }) {
              self.results.append(locator)
            }
          }
          self.fetchAllLocations(iterator: iterator)
        } else {
          self.state = .end
        }
        
      case .failure(let error):
        self.state = .failure(error)
      }
    }
    
    state = .loadingNext(iterator, cancellable)
  }

  
  func cancelSearch() {
    switch state {
    case .starting(let cancellable):
      cancellable?.cancel()
    case .idle(let iterator):
      iterator.close()
    case .loadingNext(let iterator, let cancellable):
      cancellable?.cancel()
      iterator.close()
    default:
      break
    }
    
    results.removeAll()
    state = .empty
  }

  func userSelected(_ locator: Locator) {
    delegate?.didSelect(location: locator)
  }
}
