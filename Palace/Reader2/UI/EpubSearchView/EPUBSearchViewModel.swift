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
    case idle(SearchIterator, isFetching: Bool)
    case loadingNext(SearchIterator, R2Shared.Cancellable?)
    case end
    case failure(LocalizedError)
  
    var isLoadingState: Bool {
      switch self {
        case .starting, .loadingNext:
         return true
      default:
        return false
      }
    }
  }
  
  @Published private(set) var state: State = .empty
  @Published private(set) var results: [Locator] = []
  @Published private(set) var groupedResults: [(title: String, locators: [Locator])] = []

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
        self.state = .idle(iterator, isFetching: false)
        self.fetchNextBatch()
      case .failure(let error):
        self.state = .failure(error)
      }
    }
    
    state = .starting(cancellable)
  }
  
  func fetchNextBatch() {
    guard case let .idle(iterator, _) = state else {
      return
    }
    
    state = .loadingNext(iterator, nil)
    
    let cancellable = iterator.next { [weak self] result in
      guard let self = self else { return }
      
      switch result {
      case .success(let collection):
        self.handleNewCollection(iterator, collection: collection)
      case .failure(let error):
        self.state = .failure(error)
      }
    }
    
    state = .loadingNext(iterator, cancellable)
  }

  private func handleNewCollection(_ iterator: SearchIterator, collection: _LocatorCollection?) {
    guard let collection = collection else {
      state = .end
      return
    }
    
    for newLocator in collection.locators {
      if !isDuplicate(newLocator) {
        self.results.append(newLocator)
      }
    }
    
    groupResults()
    
    self.state = .idle(iterator, isFetching: false)
  }
  
  private func groupResults() {
    var groupedResults: [String: [Locator]] = [:]
    
    for locator in results {
      let titleKey = locator.title ?? locator.href
      
      if !groupedResults.keys.contains(titleKey) {
        groupedResults[titleKey] = []
      }
      
      if !groupedResults[titleKey]!.contains(where: { existingLocator in
        existingLocator.href == locator.href &&
        existingLocator.locations.progression == locator.locations.progression &&
        existingLocator.locations.totalProgression == locator.locations.totalProgression
      }) {
        groupedResults[titleKey]!.append(locator)
      }
    }
    
    self.groupedResults = groupedResults
      .map { (title: $0.value.first?.title ?? "", locators: $0.value) }
      .sorted { section1, section2 in
        let href1 = section1.locators.first?.href.split(separator: "/").dropFirst(2).joined(separator: "/") ?? ""
        let href2 = section2.locators.first?.href.split(separator: "/").dropFirst(2).joined(separator: "/") ?? ""
        return href1 < href2
      }
  }

  private func isDuplicate(_ locator: Locator) -> Bool {
    return self.results.contains { existingLocator in
      existingLocator.href == locator.href &&
      existingLocator.locations.progression == locator.locations.progression &&
      existingLocator.locations.totalProgression == locator.locations.totalProgression
    }
  }
  
  func cancelSearch() {
    switch state {
    case .starting(let cancellable):
      cancellable?.cancel()
    case .idle(let iterator, _):
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
