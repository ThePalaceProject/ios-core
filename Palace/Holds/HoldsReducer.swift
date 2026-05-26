import Foundation

/// Pure state for the Holds feature, driven by `HoldsReducer`.
///
/// Not `Equatable` — TPPBook is a reference-type Obj-C class and equality
/// semantics are historically identity-based. Tests compare slices (counts,
/// identifiers, presence) instead of whole-state equality.
struct HoldsState {
    var reservedBooks: [TPPBook]
    var heldBooks: [TPPBook]
    var visibleBooks: [TPPBook]
    var isLoading: Bool
    var syncErrorMessage: String?
    var searchQuery: String

    init(
        reservedBooks: [TPPBook] = [],
        heldBooks: [TPPBook] = [],
        visibleBooks: [TPPBook] = [],
        isLoading: Bool = false,
        syncErrorMessage: String? = nil,
        searchQuery: String = ""
    ) {
        self.reservedBooks = reservedBooks
        self.heldBooks = heldBooks
        self.visibleBooks = visibleBooks
        self.isLoading = isLoading
        self.syncErrorMessage = syncErrorMessage
        self.searchQuery = searchQuery
    }
}

enum HoldsAction {
    case syncBegan
    case syncEnded
    /// `cached` = visibleBooks was non-empty at the moment of failure.
    /// `anonymous` = the session has no credentials (can't fetch holds at all).
    /// Both flags drive the banner-suppression rules that HoldsViewModel's
    /// legacy `handleSyncFailure` enforced; the reducer keeps them explicit.
    case syncFailed(errorMessage: String?, cached: Bool, anonymous: Bool)
    case registryChanged(held: [TPPBook])
    case searchQueryChanged(String)
    case filterCompleted([TPPBook])
    case dismissSyncError
}

struct HoldsEnvironment {
    let filterBooks: (String, [TPPBook]) async -> [TPPBook]
}

/// Namespace holder for the Holds reducer. Using an enum with a single
/// static property keeps the reducer a pure function (no instance state)
/// while giving it a clear home for documentation and helper predicates.
enum HoldsReducer {

    /// The pure reducer. Mutates state synchronously and returns an effect;
    /// callers (Store or tests) run the effect to get a follow-up action.
    static func reduce(
        _ state: inout HoldsState,
        _ action: HoldsAction
    ) -> Effect<HoldsAction, HoldsEnvironment> {
        switch action {

        case .syncBegan:
            state.isLoading = true
            state.syncErrorMessage = nil
            return .none

        case .syncEnded:
            state.isLoading = false
            return .none

        case .syncFailed(let message, let cached, let anonymous):
            state.isLoading = false
            // Banner-suppression rules — see HoldsAction doc for context.
            guard !cached, !anonymous else { return .none }
            state.syncErrorMessage = message ?? Strings.HoldsView.syncFailedMessage
            return .none

        case .registryChanged(let held):
            var reserved: [TPPBook] = []
            var active: [TPPBook] = []
            for book in held {
                if isReserved(book) { reserved.append(book) } else { active.append(book) }
            }
            state.reservedBooks = reserved
            state.heldBooks = active
            // Don't stomp the filtered view when the user has an active search.
            if state.searchQuery.isEmpty {
                state.visibleBooks = reserved + active
            }
            return .none

        case .searchQueryChanged(let query):
            state.searchQuery = query
            if query.isEmpty {
                state.visibleBooks = state.reservedBooks + state.heldBooks
                return .none
            }
            let snapshot = state.reservedBooks + state.heldBooks
            return .task { env in
                let filtered = await env.filterBooks(query, snapshot)
                return .filterCompleted(filtered)
            }

        case .filterCompleted(let books):
            state.visibleBooks = books
            return .none

        case .dismissSyncError:
            state.syncErrorMessage = nil
            return .none
        }
    }

    /// Matches the legacy `HoldsBookViewModel.isReserved` predicate: a book
    /// counts as "reserved" for partitioning purposes if its availability is
    /// `.reserved` OR `.ready`. Ready books are still in the holds list,
    /// they're just the subset that's ready to borrow.
    private static func isReserved(_ book: TPPBook) -> Bool {
        var flag = false
        book.defaultAcquisition?.availability.match(
            unavailable: nil,
            limited: nil,
            unlimited: nil,
            reserved: { _ in flag = true },
            ready: { _ in flag = true }
        )
        return flag
    }
}
