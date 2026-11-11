//
//  BookDetailNavigating.swift
//  Palace
//
//  The book detail screen opens catalog lanes through this capability, handed
//  to its view model, instead of building catalog screens itself (PP-5548).
//

import Foundation

/// A catalog destination the book detail screen can open.
enum BookDetailDestination: Equatable {
    /// The lane of other books in the book's series.
    case seriesLane(URL)
    /// The full list behind a related-books lane's "More" link.
    case relatedLane(URL)
}

@MainActor
protocol BookDetailNavigating {
    func open(_ destination: BookDetailDestination)
}

/// Pushes book detail destinations onto the navigation stack of the visible tab.
@MainActor
struct CoordinatorBookDetailNavigator: BookDetailNavigating {
    let hub: NavigationCoordinatorHub

    func open(_ destination: BookDetailDestination) {
        switch destination {
        case .seriesLane(let url), .relatedLane(let url):
            // Empty title, as the detail screen's lane links have always passed;
            // the lane screen's navigation title is left blank.
            hub.coordinator?.push(.catalogLaneMore(title: "", url: url))
        }
    }
}
