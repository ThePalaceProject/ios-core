import Foundation

/// Searches multiple library OPDS feeds simultaneously and merges results.
final class CrossLibrarySearchService: @unchecked Sendable {
    private let accountsProvider: TPPLibraryAccountsProvider
    private let catalogAPI: CatalogAPI
    private let session: URLSession

    init(
        accountsProvider: TPPLibraryAccountsProvider = AccountsManager.shared,
        catalogAPI: CatalogAPI,
        session: URLSession = .shared
    ) {
        self.accountsProvider = accountsProvider
        self.catalogAPI = catalogAPI
        self.session = session
    }

    /// Search all connected libraries in parallel and return merged, ranked results.
    func search(query: String) async throws -> CrossLibrarySearchResponse {
        let accounts = getConnectedAccounts()
        guard !accounts.isEmpty else {
            throw DiscoveryError.noLibrariesConfigured
        }

        let results = await searchAllLibraries(query: query, accounts: accounts)

        let searchedLibraries = results.map { result in
            CrossLibrarySearchResponse.SearchedLibrary(
                id: result.libraryId,
                name: result.libraryName,
                succeeded: result.succeeded,
                resultCount: result.results.count
            )
        }

        // Check if all libraries failed
        if results.allSatisfy({ !$0.succeeded }) {
            throw DiscoveryError.allLibrariesFailed
        }

        let allResults = results.flatMap(\.results)
        let merged = mergeAndDeduplicateResults(allResults)
        let ranked = rankResults(merged)

        return CrossLibrarySearchResponse(
            query: query,
            results: ranked,
            searchedLibraries: searchedLibraries,
            timestamp: Date()
        )
    }

    /// Search libraries for specific titles (used to enrich AI recommendations with availability).
    func checkAvailability(for recommendations: [DiscoveryRecommendation]) async -> [DiscoveryRecommendation] {
        let accounts = getConnectedAccounts()
        guard !accounts.isEmpty else { return recommendations }

        return await withTaskGroup(of: (Int, [LibraryAvailability]).self) { group in
            for (index, recommendation) in recommendations.enumerated() {
                group.addTask { [weak self] in
                    guard let self else { return (index, []) }
                    let availability = await self.searchForTitle(
                        recommendation.title,
                        authors: recommendation.authors,
                        in: accounts
                    )
                    return (index, availability)
                }
            }

            var enriched = recommendations
            for await (index, availability) in group {
                guard index < enriched.count else { continue }
                let rec = enriched[index]
                enriched[index] = DiscoveryRecommendation(
                    id: rec.id,
                    title: rec.title,
                    authors: rec.authors,
                    summary: rec.summary,
                    coverImageURL: rec.coverImageURL,
                    reason: rec.reason,
                    confidenceScore: rec.confidenceScore,
                    categories: rec.categories,
                    availability: availability
                )
            }

            return enriched
        }
    }

    // MARK: - Private

    private func getConnectedAccounts() -> [Account] {
        // Get all accounts the user has signed into
        var accounts: [Account] = []
        if let current = accountsProvider.currentAccount {
            accounts.append(current)
        }
        // Add additional signed-in accounts by checking known UUIDs
        for uuid in AccountsManager.TPPAccountUUIDs + AccountsManager.TPPNationalAccountUUIDs {
            if let account = accountsProvider.account(uuid),
               account.uuid != accountsProvider.currentAccountId,
               account.catalogUrl != nil {
                accounts.append(account)
            }
        }
        return accounts
    }

    private struct LibrarySearchBatch {
        let libraryId: String
        let libraryName: String
        let succeeded: Bool
        let results: [LibrarySearchResult]
    }

    private func searchAllLibraries(query: String, accounts: [Account]) async -> [LibrarySearchBatch] {
        await withTaskGroup(of: LibrarySearchBatch.self) { group in
            for account in accounts {
                group.addTask { [weak self] in
                    guard let self else {
                        return LibrarySearchBatch(libraryId: account.uuid, libraryName: account.name, succeeded: false, results: [])
                    }
                    return await self.searchSingleLibrary(query: query, account: account)
                }
            }

            var batches: [LibrarySearchBatch] = []
            for await batch in group {
                batches.append(batch)
            }
            return batches
        }
    }

    private func searchSingleLibrary(query: String, account: Account) async -> LibrarySearchBatch {
        guard let catalogUrlString = account.catalogUrl,
              let catalogURL = URL(string: catalogUrlString) else {
            return LibrarySearchBatch(libraryId: account.uuid, libraryName: account.name, succeeded: false, results: [])
        }

        do {
            guard let feed = try await catalogAPI.search(query: query, baseURL: catalogURL) else {
                return LibrarySearchBatch(libraryId: account.uuid, libraryName: account.name, succeeded: true, results: [])
            }

            let results = parseSearchResults(from: feed, libraryId: account.uuid, libraryName: account.name)
            return LibrarySearchBatch(libraryId: account.uuid, libraryName: account.name, succeeded: true, results: results)
        } catch {
            Log.warn(#file, "Search failed for library \(account.name): \(error.localizedDescription)")
            return LibrarySearchBatch(libraryId: account.uuid, libraryName: account.name, succeeded: false, results: [])
        }
    }

    private func searchForTitle(_ title: String, authors: [String], in accounts: [Account]) async -> [LibraryAvailability] {
        await withTaskGroup(of: LibraryAvailability?.self) { group in
            for account in accounts {
                group.addTask { [weak self] in
                    guard let self else { return nil }
                    return await self.checkTitleInLibrary(title: title, authors: authors, account: account)
                }
            }

            var availabilities: [LibraryAvailability] = []
            for await availability in group {
                if let availability {
                    availabilities.append(availability)
                }
            }
            return availabilities
        }
    }

    private func checkTitleInLibrary(title: String, authors: [String], account: Account) async -> LibraryAvailability? {
        guard let catalogUrlString = account.catalogUrl,
              let catalogURL = URL(string: catalogUrlString) else { return nil }

        do {
            guard let feed = try await catalogAPI.search(query: title, baseURL: catalogURL) else { return nil }
            let results = parseSearchResults(from: feed, libraryId: account.uuid, libraryName: account.name)

            // Find best matching result by title similarity
            let match = results.first { result in
                result.title.localizedCaseInsensitiveContains(title) ||
                title.localizedCaseInsensitiveContains(result.title)
            }

            guard let match else { return nil }

            return LibraryAvailability(
                libraryId: account.uuid,
                libraryName: account.name,
                status: match.availability,
                copiesAvailable: match.copiesAvailable,
                copiesTotal: match.copiesTotal,
                holdPosition: match.holdPosition,
                estimatedWaitDays: estimateWaitDays(holdPosition: match.holdPosition, copiesTotal: match.copiesTotal),
                opdsIdentifier: match.bookIdentifier,
                borrowURL: match.borrowURL
            )
        } catch {
            return nil
        }
    }

    // MARK: - OPDS Parsing

    private func parseSearchResults(from feed: CatalogFeed, libraryId: String, libraryName: String) -> [LibrarySearchResult] {
        guard let entries = feed.opdsFeed.entries as? [TPPOPDSEntry] else { return [] }

        return entries.compactMap { entry -> LibrarySearchResult? in
            let book = CatalogViewModel.makeBook(from: entry)
            let availability = determineAvailability(from: entry)
            let format = determineFormat(from: entry)

            var coverURL: URL? = nil
            var thumbnailURL: URL? = nil
            if let links = entry.links as? [TPPOPDSLink] {
                for link in links {
                    if link.rel == "http://opds-spec.org/image" {
                        coverURL = link.href
                    } else if link.rel == "http://opds-spec.org/image/thumbnail" {
                        thumbnailURL = link.href
                    }
                }
            }

            var borrowURL: URL? = nil
            if let firstAcquisition = entry.acquisitions.first {
                borrowURL = firstAcquisition.hrefURL
            }

            let copiesInfo = extractCopiesInfo(from: entry)

            return LibrarySearchResult(
                libraryId: libraryId,
                libraryName: libraryName,
                bookIdentifier: entry.identifier,
                title: entry.title,
                authors: (entry.authorStrings as? [String]) ?? [],
                summary: entry.summary,
                categories: entry.categories?.compactMap { $0.label ?? $0.term } ?? [],
                coverImageURL: coverURL,
                thumbnailURL: thumbnailURL ?? coverURL,
                availability: availability,
                copiesAvailable: copiesInfo.available,
                copiesTotal: copiesInfo.total,
                holdPosition: copiesInfo.holdPosition,
                published: entry.published,
                publisher: entry.publisher,
                borrowURL: borrowURL,
                format: format,
                book: book
            )
        }
    }

    private func determineAvailability(from entry: TPPOPDSEntry) -> AvailabilityStatus {
        for acquisition in entry.acquisitions {
            var status: AvailabilityStatus = .unavailable
            acquisition.availability.matchUnavailable({ _ in
                status = .unavailable
            }, limited: { limited in
                let copies = Int(limited.copiesAvailable)
                status = copies > 0 ? .availableNow : .shortWait
            }, unlimited: { _ in
                status = .availableNow
            }, reserved: { reserved in
                let position = Int(reserved.holdPosition)
                status = position <= 3 ? .shortWait : .longWait
            }, ready: { _ in
                status = .availableNow
            })
            return status
        }
        return .unavailable
    }

    private struct CopiesInfo {
        var available: Int?
        var total: Int?
        var holdPosition: Int?
    }

    private func extractCopiesInfo(from entry: TPPOPDSEntry) -> CopiesInfo {
        var info = CopiesInfo()
        for acquisition in entry.acquisitions {
            acquisition.availability.matchUnavailable({ _ in },
            limited: { limited in
                info.available = Int(limited.copiesAvailable)
                info.total = Int(limited.copiesTotal)
            }, unlimited: { _ in },
            reserved: { reserved in
                info.holdPosition = Int(reserved.holdPosition)
                info.total = Int(reserved.copiesTotal)
            }, ready: { _ in })
        }
        return info
    }

    private func determineFormat(from entry: TPPOPDSEntry) -> BookFormat {
        for acquisition in entry.acquisitions {
            let type = acquisition.type
            if type.contains("audiobook") { return .audiobook }
            if type.contains("pdf") { return .pdf }
            if type.contains("epub") { return .epub }

            // Check indirect acquisitions
            for indirect in acquisition.indirectAcquisitions {
                let indirectType = indirect.type
                if indirectType.contains("audiobook") { return .audiobook }
                if indirectType.contains("pdf") { return .pdf }
                if indirectType.contains("epub") { return .epub }
            }
        }
        return .unknown
    }

    // MARK: - Merging & Ranking

    private func mergeAndDeduplicateResults(_ results: [LibrarySearchResult]) -> [CrossLibrarySearchResponse.MergedSearchResult] {
        // Group by normalized title + first author to detect duplicates across libraries
        var groups: [String: [LibrarySearchResult]] = [:]
        for result in results {
            let key = normalizeForDedup(title: result.title, author: result.authors.first ?? "")
            groups[key, default: []].append(result)
        }

        return groups.values.compactMap { group -> CrossLibrarySearchResponse.MergedSearchResult? in
            guard let first = group.first else { return nil }
            return CrossLibrarySearchResponse.MergedSearchResult(
                id: first.bookIdentifier,
                title: first.title,
                authors: first.authors,
                summary: first.summary,
                categories: first.categories,
                coverImageURL: group.compactMap(\.coverImageURL).first,
                thumbnailURL: group.compactMap(\.thumbnailURL).first,
                published: first.published,
                publisher: first.publisher,
                format: first.format,
                libraryResults: group.sorted { $0.availability < $1.availability }
            )
        }
    }

    private func normalizeForDedup(title: String, author: String) -> String {
        let normalizedTitle = title
            .lowercased()
            .replacingOccurrences(of: "the ", with: "")
            .replacingOccurrences(of: "a ", with: "")
            .filter { $0.isLetter || $0.isNumber }
        let normalizedAuthor = author
            .lowercased()
            .filter { $0.isLetter }
        return "\(normalizedTitle)_\(normalizedAuthor)"
    }

    private func rankResults(_ results: [CrossLibrarySearchResponse.MergedSearchResult]) -> [CrossLibrarySearchResponse.MergedSearchResult] {
        results.sorted { a, b in
            // Primary: availability (available now first)
            if a.bestAvailability != b.bestAvailability {
                return a.bestAvailability < b.bestAvailability
            }
            // Secondary: number of libraries that have it
            if a.libraryCount != b.libraryCount {
                return a.libraryCount > b.libraryCount
            }
            // Tertiary: alphabetical
            return a.title < b.title
        }
    }

    private func estimateWaitDays(holdPosition: Int?, copiesTotal: Int?) -> Int? {
        guard let position = holdPosition, position > 0 else { return nil }
        let copies = copiesTotal ?? 1
        // Rough estimate: 14 days per loan cycle, distributed across copies
        return max(1, (position * 14) / max(copies, 1))
    }
}
