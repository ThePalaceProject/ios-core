import Foundation
import UIKit

extension Notification.Name {
    static let TPPAccountLogoUpdated = Notification.Name("TPPAccountLogoUpdated")
}

// `@MainActor`: this observer only ever lives inside SwiftUI views (held as
// `@StateObject`), so its `@Published token` is main-actor state. Isolating the
// type lets `logoDidUpdate` hop to the main actor without capturing a
// non-Sendable `self` in a `@Sendable` closure.
@MainActor
final class CatalogLogoObserver: NSObject, ObservableObject, AccountLogoDelegate {
    @Published var token = UUID()

    // `nonisolated` to satisfy the nonisolated `AccountLogoDelegate` requirement;
    // the delegate callback may arrive off the main actor, so we hop before
    // mutating `token`. `self` is `@MainActor` (hence `Sendable`), so capturing
    // it in the `@Sendable` `Task` closure is race-free. Preserves the previous
    // async-hop-to-main behavior of `DispatchQueue.main.async`.
    nonisolated func logoDidUpdate(in account: Account, to newLogo: UIImage) {
        Task { @MainActor in self.token = UUID() }
    }
}
