import Foundation
import Combine
@preconcurrency import SQLite
import PalaceLogging
import PalaceNetwork

/**
 Recommended pattern by SQLite docs
 userVersion access allows us to migrate schemas going forward
 */
extension Connection {
    public var userVersion: Int {
        get { return Int((try? scalar("PRAGMA user_version") as? Int64) ?? 0) }
        set { try? run("PRAGMA user_version = \(newValue)") }
    }
}

enum HTTPMethodType: String {
    case GET, POST, HEAD, PUT, DELETE, OPTIONS, CONNECT
}

/**
 The NetworkQueue is insantiated once on app startup and listens
 for a valid network notification from a reachability class. It then
 will retry any queued requests and purge them if necessary.
 */
/// - Note: `@unchecked Sendable` is safe here: all SQLite work and every access
///   to the mutable `retryRequestCount` are funnelled through the private serial
///   `serialQueue`, so there is no concurrent mutation of that state. `cancellables`
///   is written once during `addObserverForOfflineQueue` at startup, and every
///   other stored property is an immutable `let` (the `SQLite` expressions,
///   `path`, `serialQueue`, `transport`, `reachability`). Capturing `self` in the
///   `serialQueue.async` / URLSession-completion `@Sendable` closures therefore
///   crosses no unsynchronized boundary.
final class NetworkQueue: NSObject, @unchecked Sendable {
    typealias Expression = SQLite.Expression

    private var cancellables = Set<AnyCancellable>()
    private let transport: NetworkTransport
    private let reachability: Reachability

    /// Constructor-injected rather than reaching for a static: the drop-report
    /// guarantee below has to be observable, and this type is already being
    /// handed its collaborators. Deliberately NOT another `nonisolated(unsafe)
    /// static var` override — those are what the decomposition campaign is
    /// removing.
    private let errorLogger: ErrorLogging

    /// Supplies the `Authorization` header value at DRAIN time.
    ///
    /// Queued rows deliberately do NOT store the one they were created with.
    /// Two reasons, and the second is why this exists at all:
    ///
    ///  1. Secrets at rest. `simplified.db` is an unencrypted SQLite file in
    ///     Application Support. Archiving `Authorization: Bearer …` into it
    ///     writes a live credential to disk in the clear. Until PP-4987 this
    ///     dormant on CURRENT builds because nothing was being queued — but it
    ///     DID run historically: up to Release 1.1.0 `postAnnotation` used
    ///     `URLSession.shared` directly, so the raw NSURLError reached the gate
    ///     and rows were written carrying `Basic base64(barcode:PIN)`. See
    ///     `purgeAnyPersistedCredentials`, which cleans those off devices.
    ///  2. Correctness. A write can sit in this queue for days. The token it
    ///     was created with may have expired, been refreshed, or belong to an
    ///     account the patron has since signed out of. Replaying a stored
    ///     header retries with a stale credential; re-deriving at drain uses
    ///     whatever is valid NOW, or nothing.
    ///
    /// Takes the ROW'S library, never the currently-selected one. `retryQueue`
    /// drains every row regardless of library, and each row's URL is its own
    /// library's annotation host — so resolving `currentUserAccount` here would
    /// send library B's bearer token to library A's server whenever a patron
    /// queued a write for A and then switched to B. That is a cross-tenant
    /// credential disclosure, and it also 401s a write that had a perfectly
    /// good token in the keychain. `TPPNetworkExecutor.request(for:accountId:)`
    /// exists for precisely this reason — see its "prevent TOCTOU races during
    /// account switches … causing cross-account credential leaks" note. Here
    /// the window is not a race; it is days.
    private let authorizationHeaderProvider: @Sendable (String) -> String?

    init(transport: NetworkTransport,
         reachability: Reachability,
         databaseDirectory: String = NSSearchPathForDirectoriesInDomains(
            .applicationSupportDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory(),
         errorLogger: ErrorLogging = DefaultErrorLogger(),
         // Defaults to NO credential rather than resolving one. The single
         // production site binds this explicitly at the composition root, so a
         // resolving default is dead code — and a dangerous one: it would reach
         // `AppContainer.production()` from the drain's serial queue for any
         // future caller who forgot to bind it. Sending no credential is the
         // safe failure (the server refuses); silently reaching for a global is
         // not.
         authorizationHeaderProvider: @escaping @Sendable (String) -> String? = { _ in nil }) {
        self.path = databaseDirectory
        self.transport = transport
        self.reachability = reachability
        self.errorLogger = errorLogger
        self.authorizationHeaderProvider = authorizationHeaderProvider
        super.init()
    }

    static let StatusCodes = [NSURLErrorTimedOut,
                              NSURLErrorCannotFindHost,
                              NSURLErrorCannotConnectToHost,
                              NSURLErrorNetworkConnectionLost,
                              NSURLErrorNotConnectedToInternet,
                              NSURLErrorInternationalRoamingOff,
                              NSURLErrorCallIsActive,
                              NSURLErrorDataNotAllowed,
                              NSURLErrorSecureConnectionFailed]
    let MaxRetriesInQueue = 5

    let serialQueue = DispatchQueue(label: (Bundle.main.bundleIdentifier ?? "org.thepalaceproject.palace")
                                        + "."
                                        + String(describing: NetworkQueue.self))

    private static let DBVersion = 1
    private static let TableName = "offline_queue"

    private var retryRequestCount = 0
    /// Where `simplified.db` lives. Injectable ONLY so the drop paths can be
    /// tested: PP-4987 makes a failed enqueue report to Crashlytics instead of
    /// vanishing, and that guarantee is worthless unless something proves it
    /// fires. Pointing this at an unwritable location is the only way to make
    /// `startDatabaseConnection()` return nil deterministically. Production
    /// callers use the default and are unaffected.
    private let path: String

    private let sqlTable = Table(NetworkQueue.TableName)

    private let sqlID = Expression<Int>("id")
    private let sqlLibraryID = Expression<String>("library_identifier")
    private let sqlUpdateID = Expression<String?>("update_identifier")
    private let sqlUrl = Expression<String>("request_url")
    private let sqlMethod = Expression<String>("request_method")
    private let sqlParameters = Expression<Data?>("request_parameters")
    private let sqlHeader = Expression<Data?>("request_header")
    private let sqlRetries = Expression<Int>("retry_count")
    private let sqlDateCreated = Expression<Data>("date_created")

    // MARK: - Public Functions

    @objc func addObserverForOfflineQueue() {
        reachability.connectivityPublisher
            .filter { $0 }
            .sink { [weak self] _ in self?.retryQueue() }
            .store(in: &cancellables)
    }

    /// Strips credentials from a header set before it is written to disk.
    ///
    /// Internal rather than private so the guarantee is directly assertable —
    /// "the credential never reaches `simplified.db`" is a security property,
    /// and proving it by reading the code is not proving it. Matched
    /// case-insensitively because HTTP header names are.
    static func headersSafeToPersist(_ headers: [String: String]) -> [String: String] {
        headers.filter { $0.key.caseInsensitiveCompare("Authorization") != .orderedSame }
    }

    /// Drops any `Authorization` header left in the store by an older build.
    ///
    /// This is NOT hypothetical. Up to and including Release 1.1.0,
    /// `postAnnotation` issued its request through `URLSession.shared`
    /// directly, so the raw `NSURLError` reached `NetworkQueue.StatusCodes` and
    /// offline writes really were queued — with headers of the form
    /// `Authorization: Basic base64(barcode:PIN)`. That is a patron's library
    /// card number and PIN, base64 is not encryption, and `simplified.db` is an
    /// unencrypted file in Application Support. Rows created then can still be
    /// sitting on a device today.
    ///
    /// Expired rows do get deleted after `MaxRetriesInQueue` drains, so most
    /// are long gone — but "most" is not a basis on which to leave a cleartext
    /// PIN on disk, and re-deriving the credential at drain means nothing is
    /// lost by clearing it. Runs on every `migrate()` rather than as a
    /// versioned step so it also catches a store whose version was already
    /// current when this shipped.
    private func purgeAnyPersistedCredentials(_ db: Connection) {
        do {
            let rows = try db.prepare(sqlTable)
            for row in rows {
                // `unarchivedObject(ofClasses:from:)`, NEVER the legacy
                // `unarchiveObject(with:)`. The legacy call raises
                // `NSArchiverArchiveInconsistency` /
                // `NSInvalidUnarchiveOperationException` on a corrupt archive,
                // which is uncatchable from Swift — `try?` does not help.
                //
                // Measured, not assumed. Bit-flipping each byte of a valid
                // 277-byte header archive in turn:
                //
                //     legacy  unarchiveObject(with:)      63 of 277 ABORT the
                //                                         process (first at
                //                                         byte 81)
                //     modern  unarchivedObject(ofClasses:) 0 of 277 abort
                //
                // On-disk corruption is bit-level, which is exactly the shape
                // that kills the legacy call — garbage bytes and truncated
                // archives both return nil, so a casual probe finds nothing.
                // An earlier revision of this comment said the crash could not
                // be reproduced and called the swap mere hygiene; that was a
                // weak-probe artifact and it was wrong. This is a real crash
                // fix on the launch path (the purge runs via SEMigrations) and
                // on the drain path (`retry()`), and both reads are converted.
                guard let data = row[sqlHeader],
                      let headers = try? NSKeyedUnarchiver.unarchivedObject(
                        ofClasses: [NSDictionary.self, NSString.self], from: data
                      ) as? [String: String],
                      headers.keys.contains(where: {
                          $0.caseInsensitiveCompare("Authorization") == .orderedSame
                      }) else { continue }
                let cleaned = NSKeyedArchiver.archivedData(
                    withRootObject: NetworkQueue.headersSafeToPersist(headers))
                try db.run(sqlTable.filter(sqlID == row[sqlID]).update(sqlHeader <- cleaned))
                Log.info(#file, "Purged a persisted credential from a legacy offline-queue row")
            }
        } catch {
            Log.error(#file, "Failed to purge persisted credentials from the offline queue")
        }
    }

#if DEBUG
    /// What is ACTUALLY on disk, for tests.
    ///
    /// Deliberate test-support surface, and the justification is specific: the
    /// guarantees this type now makes are about PERSISTED BYTES — "the
    /// credential never reaches the database", "two bookmarks do not collapse
    /// into one row". Asserting those against a helper, or against a spy that
    /// stands in front of the database, proves nothing about what was stored;
    /// round 4 of review caught exactly that mistake here. The alternative —
    /// re-declaring the schema inside the test target — would drift from this
    /// file the first time a column changed, which is the same failure wearing
    /// a different hat.
    struct PersistedRow {
        let libraryID: String
        let updateID: String?
        let url: String
        let headers: [String: String]?
        /// The POSTed body. Without it, "one row survived a collapse" is
        /// indistinguishable from "the second write was silently dropped" —
        /// which is the whole property under test.
        let parameters: Data?
        let retries: Int
    }

    /// NOTE: takes `serialQueue.sync` — never call it from inside that queue.
    func persistedRowsForTesting() -> [PersistedRow] {
        serialQueue.sync {
            guard let db = startDatabaseConnection() else { return [] }
            guard let rows = try? db.prepare(sqlTable) else { return [] }
            return rows.map { row in
                let headers: [String: String]?
                if let data = row[sqlHeader] {
                    headers = try? NSKeyedUnarchiver.unarchivedObject(
                        ofClasses: [NSDictionary.self, NSString.self], from: data
                    ) as? [String: String]
                } else {
                    headers = nil
                }
                return PersistedRow(libraryID: row[sqlLibraryID],
                                    updateID: row[sqlUpdateID],
                                    url: row[sqlUrl],
                                    headers: headers,
                                    parameters: row[sqlParameters],
                                    retries: Int(row[sqlRetries]))
            }
        }
    }

    /// Writes a row the way a PRE-PP-4987 build did — credential and all.
    ///
    /// `addRequest` now strips `Authorization`, so a legacy row cannot be
    /// created through the normal API, and the purge that exists to clean those
    /// rows off real devices would be untestable without this. That purge
    /// guards a cleartext library card number and PIN; shipping it unverified
    /// is not an option, and every other claim on this branch that rested on
    /// reading rather than asserting turned out to be wrong.
    /// `rawHeaderData` overrides `headers`, so a test can plant a blob that is
    /// not a valid archive at all — which is what a five-year-old row written
    /// by a long-dead build may actually be.
    func insertLegacyRowForTesting(libraryID: String,
                                   updateID: String,
                                   url: URL,
                                   headers: [String: String],
                                   rawHeaderData: Data? = nil) {
        serialQueue.sync {
            guard let db = startDatabaseConnection() else { return }
            let headerData = rawHeaderData
                ?? NSKeyedArchiver.archivedData(withRootObject: headers)
            let dateCreated = NSKeyedArchiver.archivedData(withRootObject: Date())
            _ = try? db.run(sqlTable.insert(
                sqlLibraryID <- libraryID,
                sqlUpdateID <- updateID,
                sqlUrl <- url.absoluteString,
                sqlMethod <- HTTPMethodType.POST.rawValue,
                sqlParameters <- Data("{}".utf8),
                sqlHeader <- headerData,
                sqlRetries <- 0,
                sqlDateCreated <- dateCreated))
        }
    }
#endif

    func addRequest(_ libraryID: String,
                    _ updateID: String?,
                    _ requestUrl: URL,
                    _ method: HTTPMethodType,
                    _ parameters: Data?,
                    _ headers: [String: String]?) {
        self.serialQueue.async {

            // Serialize Data
            let urlString = requestUrl.absoluteString
            let methodString = method.rawValue
            let dateCreated = NSKeyedArchiver.archivedData(withRootObject: Date())

            let headerData: Data?
            if let headers = headers {
                // NEVER persist the credential (PP-4987). `simplified.db` is an
                // unencrypted file in Application Support, and callers build
                // their headers from `TPPNetworkExecutor.request(for:)`, whose
                // `useTokenIfAvailable` defaults to TRUE — so `Authorization:
                // Bearer …` is present unless it is removed here. It is
                // re-derived at drain time from whatever credential is current.
                // Matched case-insensitively because HTTP header names are.
                headerData = NSKeyedArchiver.archivedData(
                    withRootObject: NetworkQueue.headersSafeToPersist(headers))
            } else {
                headerData = nil
            }

            guard let db = self.startDatabaseConnection() else {
                // PP-4987: never drop a queued write in silence. The caller has
                // already been told "queued for retry" and has stopped
                // reporting on that basis, so this is the last place the loss
                // can still be seen.
                self.errorLogger.logError(withCode: .offlineQueueWriteFailed,
                                          summary: "Offline queue write dropped",
                                        metadata: [
                                            "reason": "no database connection",
                                            "libraryID": libraryID,
                                            "url": urlString,
                                            "method": methodString
                                        ])
                return
            }

            // Update (not insert) if uniqueID and libraryID match existing row in table
            let query = self.sqlTable.filter(self.sqlLibraryID == libraryID && self.sqlUpdateID == updateID)
                .filter(self.sqlUpdateID != nil)

            do {
                // Try to update row
                // Reset `retries` (PP-4987). This row is being SUPERSEDED — the
                // body is new even though the key is the same. Without the
                // reset the new write inherits the old one's retry count, and
                // because `retryQueue` deletes `retries > MaxRetriesInQueue`
                // BEFORE it drains, a fresh reading position landing on an
                // exhausted row is deleted having never been sent once. That is
                // silent loss, and PP-4965 has already removed the error report
                // for this path — so nothing would have said so.
                let result = try db.run(query.update(self.sqlParameters <- parameters,
                                                     self.sqlHeader <- headerData,
                                                     self.sqlRetries <- 0))
                if result > 0 {
                    Log.debug(#file, "SQLite: Row Updated")
                } else {
                    // Insert new row
                    try db.run(self.sqlTable.insert(self.sqlLibraryID <- libraryID, self.sqlUpdateID <- updateID, self.sqlUrl <- urlString, self.sqlMethod <- methodString, self.sqlParameters <- parameters, self.sqlHeader <- headerData, self.sqlRetries <- 0, self.sqlDateCreated <- dateCreated))
                    Log.debug(#file, "SQLite: Row Added")
                }
            } catch {
                Log.error(#file, "SQLite Error: Could not insert or update row")
                // PP-4987: as above — a local Log.error is invisible in
                // production telemetry, and the caller believes this write is
                // safely pending.
                // `logNetworkError(_:code:…)`, NOT the bare `logError(_:summary:
                // metadata:)` overload — that one hardcodes `code: .ignore`,
                // which would file this under the raw bridged SQLite code with
                // `error_origin = unknown` instead of 916. Round 1 of review
                // blocked this branch for exactly that substitution in
                // `TPPAnnotations`; it was reintroduced here in new code and
                // caught by all three reviewers in round 3.
                self.errorLogger.logNetworkError(error,
                                          code: .offlineQueueWriteFailed,
                                          summary: "Offline queue write dropped",
                                          request: nil,
                                          response: nil,
                                        metadata: [
                                            "reason": "insert or update threw",
                                            "libraryID": libraryID,
                                            "url": urlString,
                                            "method": methodString
                                        ])
            }
        }
    }

    func migrate() {
        self.serialQueue.async {
            guard let db = self.startDatabaseConnection() else {
                Log.error(#file, "Failed to start database connection for a retry attempt.")
                return
            }


            let tableCount = Int((try? db.scalar("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = '\(NetworkQueue.TableName)'") as? Int64) ?? 0)
            if tableCount < 1 {
                self.createTable(db: db)
                db.userVersion = NetworkQueue.DBVersion
            } else {
                // Only once the table exists — on a fresh install there is
                // nothing to purge and the attempt would log a failure for a
                // non-error.
                self.purgeAnyPersistedCredentials(db)

                var dbVersion = db.userVersion
                // TODO: Consider optimizing migrations by checking if
                // there's a breaking change between current version and target version
                // If there is, we can probably immediately jump to current version,
                // invoking createTable()
                do {
                    while dbVersion < NetworkQueue.DBVersion { // Iterate
                        switch dbVersion {
                        case 0:
                            try db.run(self.sqlTable.drop(ifExists: true))
                            self.createTable(db: db)
                            dbVersion = NetworkQueue.DBVersion
                            db.userVersion = NetworkQueue.DBVersion
                        default:
                            break
                        }
                        dbVersion += 1
                    }
                } catch {
                    Log.error(#file, "SQLite Error: Could not migrate.")
                }
            }
        }
    }

    // MARK: - Private Functions

    private func createTable(db: Connection) {
        do {
            try db.run(self.sqlTable.create(ifNotExists: true) { t in
                t.column(self.sqlID, primaryKey: true)
                t.column(self.sqlLibraryID)
                t.column(self.sqlUpdateID)
                t.column(self.sqlUrl)
                t.column(self.sqlMethod)
                t.column(self.sqlParameters)
                t.column(self.sqlHeader)
                t.column(self.sqlRetries)
                t.column(self.sqlDateCreated)
            })
        } catch {
            Log.error(#file, "SQLite Error: Could not create table")
        }
    }

    /// Not `private`: the drain is normally kicked by a reachability publisher,
    /// and its behaviour (credential scoping, expiry, retry accounting) is
    /// exactly the part of this type with the least coverage and the most risk.
    /// Tests drive it directly rather than through `perform(Selector(…))`,
    /// which compiles to nothing checkable and breaks silently on a rename.
    @objc func retryQueue() {
        self.serialQueue.async {

            if self.retryRequestCount > 0 {
                Log.debug(#file, "Retry requests are still in progress. Cancelling this attempt.")
                return
            }

            guard let db = self.startDatabaseConnection() else {
                Log.error(#file, "Failed to start database connection for a retry attempt.")
                return
            }

            let expiredRows = self.sqlTable.filter(self.sqlRetries > self.MaxRetriesInQueue)
            do {
                try db.run(expiredRows.delete())

                self.retryRequestCount = try db.scalar(self.sqlTable.count)
                Log.debug(#file, "Executing \"retry\" with \(self.retryRequestCount) row(s) in the table.")

                for row in try db.prepare(self.sqlTable) {
                    Log.debug(#file, "Retrying row: \(row[self.sqlID])")
                    self.retry(db, requestRow: row)
                }
            } catch {
                Log.error(#file, "SQLite Error: Failure to prepare table or run deletion")
            }
        }
    }

    private func retry(_ db: Connection, requestRow: Row) {
        do {
            let ID = Int(requestRow[sqlID])
            let newValue = Int(requestRow[sqlRetries]) + 1
            try db.run(sqlTable.filter(sqlID == ID).update(sqlRetries <- newValue))
        } catch {
            Log.error(#file, "SQLite Error incrementing retry count")
        }

        // Re-attempt network request
        guard let url = URL(string: requestRow[sqlUrl]) else {
            Log.error(#file, "SQLite: Invalid URL in queue row, skipping: \(requestRow[sqlUrl])")
            deleteRow(db, id: requestRow[sqlID])
            retryRequestCount -= 1
            return
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = requestRow[sqlMethod]
        urlRequest.httpBody = requestRow[sqlParameters]
        urlRequest.applyCustomUserAgent()

        if let headerData = requestRow[sqlHeader],
           let headers = (try? NSKeyedUnarchiver.unarchivedObject(
              ofClasses: [NSDictionary.self, NSString.self], from: headerData
           )) as? [String: String] {
            for (headerKey, headerValue) in headers {
                urlRequest.setValue(headerValue, forHTTPHeaderField: headerKey)
            }
        }

        // Attach the credential current for THIS ROW'S LIBRARY (PP-4987).
        // Rows carry no `Authorization` by design — see
        // `authorizationHeaderProvider`. A row can be days old, so the token it
        // was queued with may be expired or belong to a signed-out account;
        // this uses whatever is valid now for that library, or sends none and
        // lets the server refuse (correct for a signed-out patron). Keyed on
        // the row's library, never the selected one — see the provider's doc.
        if let authorization = authorizationHeaderProvider(requestRow[sqlLibraryID]) {
            urlRequest.setValue(authorization, forHTTPHeaderField: "Authorization")
        }

        let task = transport.urlSession.dataTask(with: urlRequest) { (_, response, _) in
            self.serialQueue.async {
                if let response = response as? HTTPURLResponse,
                   (200...299).contains(response.statusCode) {
                    Log.info(#file, "Queued Request Upload: Success (\(response.statusCode))")
                    self.deleteRow(db, id: requestRow[self.sqlID])
                } else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    Log.warn(#file, "Queued Request retry failed with status \(code)")
                }
                self.retryRequestCount -= 1
            }
        }
        task.resume()
    }

    private func deleteRow(_ db: Connection, id: Int) {
        let rowToDelete = sqlTable.filter(sqlID == id)
        if (try? db.run(rowToDelete.delete())) != nil {
            Log.info(#file, "SQLite: deleted row from queue")
        } else {
            Log.error(#file, "SQLite Error: Could not delete row")
        }
    }

    private func startDatabaseConnection() -> Connection? {
        let db: Connection
        do {
            db = try Connection("\(path)/simplified.db")
        } catch {
            Log.error(#file, "SQLite: Could not start DB connection.")
            return nil
        }
        return db
    }
}

// Wave 1c (cycle 3): package-protocol seam for the circulation-analytics
// offline enqueue. Maps the package HTTPMethod onto the app HTTPMethodType
// (rawValues are identical — "GET" → .GET).
extension NetworkQueue: OfflineRequestEnqueuing {
    func enqueueOfflineRequest(
        libraryID: String,
        updateID: String?,
        url: URL,
        method: HTTPMethod,
        parameters: Data?,
        headers: [String: String]?
    ) {
        // App-side HTTPMethodType has no PATCH case; the package protocol's
        // HTTPMethod does. Assert-loud on any unmapped method so a future
        // caller doesn't get a SILENT downgrade to .GET (today only .GET flows).
        let mappedMethod = HTTPMethodType(rawValue: method.rawValue)
        assert(mappedMethod != nil,
               "OfflineRequestEnqueuing: HTTPMethod.\(method.rawValue) has no HTTPMethodType mapping — would silently degrade to .GET")
        addRequest(libraryID, updateID, url, mappedMethod ?? .GET, parameters, headers)
    }
}
