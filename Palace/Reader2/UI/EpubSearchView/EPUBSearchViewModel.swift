//
//  SearchViewModel.swift
//  Palace
//
//  Created by Maurice Carrier on 10/11/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import ReadiumShared
import ReadiumNavigator

protocol EPUBSearchDelegate: AnyObject {
  func didSelect(location: Locator)
}

typealias SearchViewSection = (id: String, title: String, locators: [Locator])

@MainActor
final class EPUBSearchViewModel: ObservableObject {
  enum State {
    case empty
    case starting
    case idle(SearchIterator, isFetching: Bool)
    case loadingNext(SearchIterator)
    case end
    case failure(Error)

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
  @Published private(set) var sections: [SearchViewSection] = []

  private var publication: Publication
  weak var delegate: EPUBSearchDelegate?

  init(publication: Publication) {
    self.publication = publication
  }

  func search(with query: String) async {
    cancelSearch()

    state = .starting
    let result = await publication.search(query: query)
    switch result {
    case .success(let iterator):
      state = .idle(iterator, isFetching: false)
      await fetchNextBatch()
    case .failure(let error):
      state = .failure(error)
    }
  }

  func fetchNextBatch() async {
    guard case let .idle(iterator, _) = state else {
      return
    }

    state = .loadingNext(iterator)

    let result = await iterator.next()
    switch result {
    case .success(let collection):
      handleNewCollection(iterator, collection: collection)
    case .failure(let error):
      state = .end
      state = .failure(error)
    }
  }

  private func handleNewCollection(_ iterator: SearchIterator, collection: LocatorCollection?) {
    guard let collection = collection else {
      state = .end
      return
    }

    for newLocator in collection.locators {
      if !isDuplicate(newLocator) {
        results.append(newLocator)
      }
    }

    groupResults()
    state = .idle(iterator, isFetching: false)
  }

  private func groupResults() {
    var groupedResults: [String: [Locator]] = [:]

    for locator in results {
      let titleKey = locator.title ?? locator.href.string

      if !groupedResults.keys.contains(titleKey) {
        groupedResults[titleKey] = []
      }

      if !groupedResults[titleKey]!.contains(where: { existingLocator in
        existingLocator.href.isEquivalentTo(locator.href) &&
        existingLocator.locations.progression == locator.locations.progression &&
        existingLocator.locations.totalProgression == locator.locations.totalProgression
      }) {
        groupedResults[titleKey]!.append(locator)
      }
    }

    self.sections = groupedResults
      .map { (id: UUID().uuidString, title: $0.value.first?.title ?? "", locators: $0.value) }
      .sorted { section1, section2 in
        let href1 = section1.locators.first?.href.string ?? ""
        let href2 = section2.locators.first?.href.string ?? ""
        return href1 < href2
      }
  }

  private func isDuplicate(_ locator: Locator) -> Bool {
    return results.contains { existingLocator in
      existingLocator.href.isEquivalentTo(locator.href) &&
      existingLocator.locations.progression == locator.locations.progression &&
      existingLocator.locations.totalProgression == locator.locations.totalProgression
    }
  }

  func cancelSearch() {
    results.removeAll()
    state = .empty
  }

  func userSelected(_ locator: Locator) {
    delegate?.didSelect(location: locator)
  }
}
