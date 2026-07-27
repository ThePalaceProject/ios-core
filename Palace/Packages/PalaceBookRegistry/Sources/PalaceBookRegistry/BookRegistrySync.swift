import Foundation
import PalaceLogging
import PalaceCatalog
import PalaceBookModel

/// Handles server synchronization for the book registry.
/// Manages syncing loans from the OPDS feed and loading/saving from disk.
///
/// Swift 6 concurrency (Wave 1, `SWIFT_STRICT_CONCURRENCY=targeted`):
/// `@unchecked Sendable`.
///
/// INVARIANT — this type carries no concurrently-mutated shared state:
///   • Every stored dependency (`store`, `accountsManager`,
///     `downloadCenterProvider`, `opdsFeedServiceProvider`, the folder/file
///     name constants, `diskWriteQueue`, `diskWriteQueueKey`) is an immutable
///     `let`. `store` (`BookRegistryStore`) serialises all registry access
///     through its own `syncQueue` barrier; all disk writes are serialised
///     through `diskWriteQueue`.
///   • The two mutable vars (`syncUrl`, `loadingAccount`) are main-thread
///     confined in production: every write happens inside a
///     `DispatchQueue.main.async` / `await MainActor.run` block (see `load`
///     and `sync`), and the reads that gate behaviour (e.g. `syncUrl != loansUrl`,
///     the duplicate-load guard) run on that same main queue. No write races
///     another write across threads.
///   • `_needsRebuildFromServer` (the INV-1 rebuild flag) is guarded by its own
///     `rebuildFlagLock`, so the disk-write queue can read/clear it race-free.
///
/// Marking the type Sendable lets it be captured by the structured-concurrency
/// (`Task { … }` / `await MainActor.run { … }`) closures in `sync(...)` without
/// any runtime change — it documents the main-thread confinement the code
/// already relies on, rather than altering it. See module-3 playbook (#1129):
/// prefer isolation / `@unchecked Sendable` with a documented invariant over
/// `nonisolated(unsafe)`.
final class BookRegistrySync: @unchecked Sendable {

  private let store: BookRegistryStore
  /// Value-only account scope (god-class decomposition Wave 2b — the Book→Accounts
  /// inversion). No `Account` / `AccountsManager` / `TPPUserAccount` type crosses
  /// this boundary; the engine reads `currentAccountID`, credential presence, and
  /// the loans URL through it, nothing more.
  private let accountScope: any AccountScopeProviding
  /// External collaborators — the download service, the loans-feed fetcher, the
  /// sideload-exemption set, the registry-directory path rule, and the
  /// availability-change hook. Each is resolved LAZILY by the composition root
  /// (same deferred `AppContainer.production()` semantics the inline closures had,
  /// now supplied from outside) so this package carries no edge to AppContainer,
  /// downloads, accounts, settings, or NotificationService. The download-service
  /// and loans-fetcher provider closures defer resolution because the download
  /// center reads the registry back for its own defaults — resolving at construction
  /// time (inside `TPPBookRegistry.init`, while the composition root is still
  /// settling) would deadlock the init chain. Side-loaded books are registered
  /// `.downloadSuccessful` but never appear in the loans feed, so
  /// `dependencies.sideloadedIdentifiers()` exempts them from reconciliation (the
  /// load-bearing hazard in `docs/architecture/sideloading-plan.md`).
  private let dependencies: RegistryExternalDependencies
  private let registryFolderName = "registry"
  private let registryFileName = "registry.json"
  /// Serial queue for disk writes — prevents out-of-order save races where a stale
  /// snapshot could overwrite a newer one if two saves dispatch concurrently.
  private let diskWriteQueue = DispatchQueue(label: "com.palace.registryDiskWrite")
  /// Identifies execution already inside `diskWriteQueue` so a reentrant
  /// `saveSync` runs its write inline instead of a nested `diskWriteQueue.sync`
  /// (which would deadlock). See `saveSync(for:)`.
  private let diskWriteQueueKey = DispatchSpecificKey<Void>()

  var syncUrl: URL?
  var loadingAccount: String?

  /// INV-1 (Reliability WS-B): set true when `load` finds the registry file
  /// corrupt/unrecoverable and leaves the in-memory shelf empty. While true,
  /// `save(for:)`/`saveSync(for:)` refuse to persist an EMPTY snapshot over a
  /// non-empty last-good `.bak` unless the save is marked server-authoritative
  /// (`sync()`'s loans-feed reconciliation). Cleared by the next successful
  /// non-empty or authoritative save. Lock-guarded so the disk-write queue can
  /// read it race-free (the class is `@unchecked Sendable`).
  private let rebuildFlagLock = NSLock()
  private var _needsRebuildFromServer = false
  var needsRebuildFromServer: Bool {
    get { rebuildFlagLock.lock(); defer { rebuildFlagLock.unlock() }; return _needsRebuildFromServer }
    set { rebuildFlagLock.lock(); defer { rebuildFlagLock.unlock() }; _needsRebuildFromServer = newValue }
  }

  /// Resolved-on-demand accessors. Tests inject fakes via `dependencies`;
  /// production wires the live download center + OPDS feed service through the
  /// composition root. Same lazy-resolution timing as before the extraction.
  private var downloadService: any RegistryDownloadServicing { dependencies.downloadService() }
  private var opdsFeedService: any OPDSFeedFetching { dependencies.loansFeedFetcher() }

  init(
    store: BookRegistryStore,
    accountScope: any AccountScopeProviding,
    dependencies: RegistryExternalDependencies
  ) {
    self.store = store
    self.accountScope = accountScope
    self.dependencies = dependencies
    diskWriteQueue.setSpecific(key: diskWriteQueueKey, value: ())
  }

  func registryUrl(for account: String) -> URL? {
    // The `TPPAccountUUIDs[0]` root-vs-subdir path-layout rule + error logging
    // lives app-side behind `dependencies.registryDirectory` (god-class decomp
    // Wave 2b) — the resolved file path is byte-identical (pinned by the migration
    // tests).
    return dependencies.registryDirectory(account)?
      .appendingPathComponent(registryFolderName)
      .appendingPathComponent(registryFileName)
  }

  func load(
    account: String?,
    setState: @escaping (TPPBookRegistry.RegistryState) -> Void,
    completion: (() -> Void)? = nil
  ) {
    guard let account = account ?? accountScope.currentAccountID,
          let url = registryUrl(for: account)
    else {
      completion?()
      return
    }

    // Prevent re-entrant loads for the same account
    if loadingAccount == account {
      Log.debug(#file, "Skipping duplicate load for account: \(account) (already loading)")
      completion?()
      return
    }

    loadingAccount = account
    Log.info(#file, "Loading registry for account: \(account)")

    // Box the injected callbacks so the `@Sendable` `DispatchQueue.main.async`
    // closures below (here and in the mutateRegistry completion) capture a
    // Sendable value rather than the raw non-Sendable `setState` / `completion`
    // function values — otherwise `complete` mode reports "capture of … in a
    // '@Sendable' closure" / "sending … risks data races". The callbacks are
    // still only ever invoked on main. Mirrors `sync(...)`'s `SyncCallbacks`.
    let callbacks = LoadCallbacks(setState: setState, completion: completion)

    DispatchQueue.main.async {
      callbacks.setState(.loading)
    }

    store.mutateRegistry { [weak self] registry in
      guard let self else { return }

      // PP-4129: books whose registry state says "downloaded" but whose content file
      // has vanished. After the load settles on main we schedule a silent background
      // re-download so the user doesn't end up on the helpspot #17669 "can't open,
      // can't delete, loops on missing file" path.
      var lcpBooksNeedingBackgroundRedownload = [TPPBook]()
      var orphanedBooksNeedingRedownload = [TPPBook]()

      var newRegistry = [String: TPPBookRegistryRecord]()
      var needsRebuild = false

      // Reliability WS-B / INV-1: distinguish an ABSENT registry file from an
      // existing-but-CORRUPT one. The old code conflated both into a single
      // `else` that silently zeroed the shelf, and the next save() then
      // overwrote the (recoverable) corrupt file with a valid-but-empty one —
      // erasing the patron's whole shelf on a single bad write. We now classify
      // the bytes, quarantine a corrupt file (never destroy), and try the
      // last-good `.bak` before falling back to empty + a rebuild flag.
      let fileExists = FileManager.default.fileExists(atPath: url.path)
      let fileData: Data? = fileExists ? try? Data(contentsOf: url) : nil
      let classification: RegistryFileRecovery.Classification
      if !fileExists {
        classification = .empty
      } else if let fileData {
        classification = RegistryFileRecovery.classify(data: fileData)
      } else {
        // File exists but could not be read — treat as corrupt (recoverable).
        classification = .corrupt
      }

      var recordsToParse: [TPPBookRegistryData]? = nil
      switch classification {
      case .valid(let records):
        recordsToParse = records
        if RegistryFileRecovery.needsMigration(data: fileData) {
          Log.info(#file, "  Registry file is unversioned (legacy) — will migrate to schema v\(RegistryFileRecovery.currentSchemaVersion) on next save")
        }
      case .empty:
        Log.info(#file, "  No existing registry file found — starting with an empty registry")
      case .corrupt:
        Log.error(#file, "  Registry file exists but is CORRUPT — quarantining (never overwriting/destroying)")
        if let quarantined = RegistryFileRecovery.quarantine(corruptFileAt: url) {
          Log.error(#file, "  Quarantined corrupt registry to \(quarantined.lastPathComponent)")
        }
        if let recovered = RegistryFileRecovery.recoverFromBackup(for: url) {
          Log.info(#file, "  Recovered \(recovered.count) record(s) from last-good .bak backup")
          recordsToParse = recovered
        } else {
          Log.error(#file, "  No usable .bak backup — leaving registry empty and flagging needsRebuildFromServer (next authenticated sync repopulates from the loans feed)")
          needsRebuild = true
        }
      }

      if let records = recordsToParse {
        Log.debug(#file, "  Found \(records.count) books in registry")

        for obj in records {
          guard let record = TPPBookRegistryRecord(record: obj) else { continue }
          let originalState = record.state

          // Validate file existence for download states. `.used` is included
          // because a book that has been opened at least once transitions from
          // .downloadSuccessful to .used, and if its file was evicted pre-fix
          // the reader otherwise shows "unable to load PDF/EPUB" instead of
          // the correct "Download" affordance. Treat missing-file the same
          // as .downloadSuccessful: flip to .downloadNeeded and schedule
          // auto-restart.
          if record.state == .downloading || record.state == .SAMLStarted || record.state == .downloadSuccessful || record.state == .downloadNeeded || record.state == .used {
            let fileExists = self.downloadService.contentFileSatisfied(for: record.book, account: account)

            if record.state == .downloading {
              if fileExists {
                Log.info(#file, "  '\(record.book.title)' was downloading but file exists - marking as successful")
                record.state = .downloadSuccessful
              } else {
                Log.warn(#file, "  '\(record.book.title)' was downloading but file missing - marking as failed")
                record.state = .downloadFailed
              }
            } else if record.state == .SAMLStarted {
              if fileExists {
                Log.info(#file, "  '\(record.book.title)' was in SAML flow but file exists - marking as download needed")
                record.state = .downloadNeeded
              } else {
                Log.warn(#file, "  '\(record.book.title)' was in SAML flow but file missing - marking as failed")
                record.state = .downloadFailed
              }
            } else if record.state == .downloadNeeded {
              // Migration heal: the pre-PR-#856 sync-before-load race (plus the
              // UpdatedKey parse regression that silently dropped records during
              // load) could leave a downloaded book persisted as .downloadNeeded
              // even though its content file was still on disk. If we see that
              // combination now, promote to .downloadSuccessful so the user
              // doesn't get a spurious "Download" button for a book they already
              // have locally. No-op for the normal case where .downloadNeeded
              // genuinely has no file.
              if fileExists {
                Log.info(#file, "  '\(record.book.title)' state was .downloadNeeded but file present — healing to .downloadSuccessful")
                record.state = .downloadSuccessful
              }
            } else if record.state == .used {
              // A book the user has opened at least once. If its content file
              // was evicted by the LRU budget (pre-fix) the reader fails to
              // load with "unable to open PDF/EPUB". Same heal as
              // .downloadSuccessful: flip to .downloadNeeded + auto-restart.
              if !fileExists {
                Log.error(#file, "  '\(record.book.title)' was .used but FILE MISSING — marking as download needed")
                record.state = .downloadNeeded
                orphanedBooksNeedingRedownload.append(record.book)
              } else {
                Log.debug(#file, "  '\(record.book.title)' used and file verified")
              }
            } else if record.state == .downloadSuccessful {
              if !fileExists {
                Log.error(#file, "  '\(record.book.title)' marked as downloaded but FILE MISSING - marking as download needed")
                Log.error(#file, "     This suggests the file was deleted or the path is wrong")
                record.state = .downloadNeeded
                orphanedBooksNeedingRedownload.append(record.book)
              } else {
                // LCP audiobooks pass `contentFileSatisfied` as soon as the .lcpl
                // license exists (playable via streaming). If the .lcpa content
                // file is missing, schedule a silent background re-download so
                // subsequent opens use the local copy instead of ranged reads
                // from GCS (PP-3704). The `#if LCP` / `LCPAudiobooks` probe now
                // lives app-side behind `lcpContentFileMissing` — SPM targets do
                // not inherit the app's LCP define (noDRM returns false → no-op).
                if self.downloadService.lcpContentFileMissing(for: record.book, account: account) {
                  Log.warn(#file, "  '\(record.book.title)' LCP audiobook playable via streaming but .lcpa MISSING - scheduling background re-download")
                  lcpBooksNeedingBackgroundRedownload.append(record.book)
                } else {
                  Log.debug(#file, "  '\(record.book.title)' downloaded and file verified")
                }
              }
            }

            if originalState != record.state {
              Log.info(#file, "  State changed for '\(record.book.title)': \(originalState) -> \(record.state)")
            }
          }

          newRegistry[record.book.identifier] = record
        }
      }

      registry = newRegistry

      // Capture states and snapshot while on sync queue
      let bookStates = newRegistry.map { ($0.key, $0.value.state) }
      let snapshot = registry
      let bookCount = snapshot.count
      let loadedAccount = account

      DispatchQueue.main.async { [weak self] in
        guard let self else {
          callbacks.completion?()
          return
        }

        if self.loadingAccount == loadedAccount {
          self.loadingAccount = nil
        }

        // INV-1: publish the rebuild flag on main (matches this class's
        // main-thread-confinement invariant for its mutable state). While set,
        // save() refuses to persist an empty snapshot over a non-empty backup
        // until an authoritative server sync repopulates the shelf.
        self.needsRebuildFromServer = needsRebuild

        callbacks.setState(.loaded)
        self.store.registrySubject.send(snapshot)

        for (identifier, state) in bookStates {
          self.store.bookStateSubject.send((identifier, state))
        }

        NotificationCenter.default.post(name: .TPPBookRegistryDidChange, object: nil)
        Log.info(#file, "  Registry loaded with \(bookCount) books")

        // Fire the completion AFTER state is .loaded and subscribers have been
        // notified — callers that chain sync() off load (e.g. the account-change
        // observer, AppDelegate cold-launch) need the store populated before
        // sync's reconciliation runs.
        callbacks.completion?()

        // PP-4129: schedule recovery for orphaned downloads. Each scheduled block
        // re-checks that the account that ran the load is still current before
        // firing downloads — switching libraries during the wait would otherwise
        // kick off a re-download with the wrong auth context.
        // The `#if LCP` gate is gone: on noDRM `lcpContentFileMissing` always
        // returns false, so `lcpBooksNeedingBackgroundRedownload` is empty and
        // this block no-ops — behavior-identical across build flavors.
        if !lcpBooksNeedingBackgroundRedownload.isEmpty {
          Log.info(#file, "  Scheduling background .lcpa re-download for \(lcpBooksNeedingBackgroundRedownload.count) orphaned LCP audiobook(s)")
          // Capture an immutable `let` snapshot in the capture list: the
          // escaping `@Sendable` asyncAfter closure must not capture the mutable
          // `var` (which the parse loop above mutated) — otherwise `complete`
          // mode flags "sending 'lcpBooksNeedingBackgroundRedownload' risks
          // causing data races". `TPPBook` elements are already Sendable, so the
          // snapshot array is a Sendable value. Mirrors the DLNavigator
          // "capture an immutable copy before the closure" pattern.
          let lcpRedownloadSnapshot = lcpBooksNeedingBackgroundRedownload
          DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [accountScope, downloadService, lcpRedownloadSnapshot] in
            guard accountScope.currentAccountID == loadedAccount else {
              Log.info(#file, "  Skipping LCP background re-download — account changed during wait")
              return
            }
            for book in lcpRedownloadSnapshot {
              downloadService.redownloadLCPContentFile(for: book)
            }
          }
        }

        if !orphanedBooksNeedingRedownload.isEmpty {
          Log.info(#file, "  Scheduling auto-restart for \(orphanedBooksNeedingRedownload.count) orphaned download(s)")
          // Immutable `let` snapshot captured in the list — see the LCP branch
          // above for the same `sending`-mutable-var rationale.
          let orphanRedownloadSnapshot = orphanedBooksNeedingRedownload
          DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [accountScope, downloadService, orphanRedownloadSnapshot] in
            guard accountScope.currentAccountID == loadedAccount else {
              Log.info(#file, "  Skipping orphan auto-restart — account changed during wait")
              return
            }
            for book in orphanRedownloadSnapshot {
              downloadService.startDownload(for: book)
            }
          }
        }
      }
    }
  }

  func sync(
    currentState: TPPBookRegistry.RegistryState,
    setState: @escaping (TPPBookRegistry.RegistryState) -> Void,
    completion: ((_ errorDocument: [AnyHashable: Any]?, _ newBooks: Bool) -> Void)? = nil
  ) {
    // Guard against running sync() before load() has populated the in-memory
    // registry. If we reach the reconciliation block below with an empty store,
    // every loan in the feed is written as a fresh .downloadNeeded record —
    // overwriting the on-disk file and destroying location/bookmarks for every
    // previously-downloaded book. On cold launches the only path that calls
    // load() is the account-change observer; if its notification is missed
    // (race with singleton init on a background queue) or if load's disk I/O
    // is still in flight when a view triggers sync(), this guard is the last
    // line of defence.
    if currentState == .unloaded || currentState == .loading {
      Log.warn(#file, "sync() called before load completed (state=\(currentState)) — skipping to protect on-disk state")
      return
    }

    // Capture the syncing account at the top so that if the user switches
    // libraries while the feed fetch is in flight, we persist the result to
    // the account that was syncing — not the one that happens to be current
    // when the save commits (PP-4129 regression).
    guard let accountUUID = accountScope.currentAccountID else { return }

    // Skip the loans fetch when no credentials are stored for the current
    // account. The `loansUrl` from the OPDS auth document is only useful
    // when we can authenticate the request — without credentials we get a
    // guaranteed 401 (or get blocked by the test stub during instrumented
    // runs). Originally written as `!needsAuth && !hasCredentials` to
    // target anonymous libraries, but chaos-qa dogfood-4 surfaced that
    // `needsAuth` returns conservatively-true during the relaunch
    // hydration race (auth document not yet loaded), defeating the gate.
    // The `hasCredentials` check alone is sufficient: post-sign-in the
    // auth-state-changed observer triggers a fresh sync(); during the
    // unhydrated window we just defer.
    //
    // Discovered by chaos-qa dogfood-3 → F-007 (PP-4164).
    // Refined by chaos-qa dogfood-4 → F-DG4-001.
    if !accountScope.hasCredentials(forAccount: accountUUID) {
      Log.debug(#file, "Skipping loans sync — no credentials for account \(accountUUID)")
      setState(.loaded)
      completion?(nil, false)
      return
    }

    if currentState == .syncing { return }

    setState(.syncing)

    // Box the injected callbacks so the `@Sendable` `Task` / `MainActor.run`
    // closures below capture a Sendable value rather than the raw non-Sendable
    // closures (which would otherwise trip the `targeted` capture diagnostic).
    // The callbacks are still only invoked inside `MainActor.run`, on main.
    let callbacks = SyncCallbacks(setState: setState, completion: completion)

    Task { [weak self] in
      guard let self else { return }

      // PHASE 1 (swarm_81b5099e Bucket A — PP-4407): the loansUrl read used
      // to happen on the sync `sync()` call frame above. Hoisted into the
      // Task block so we can await `Account.LoadState` readiness via
      // `awaitReady()`. Pre-Phase-1 this silently returned on first cold-
      // launch (details still loading → loansUrl nil → guard bailed →
      // registry stuck `.loaded` empty until the next sync trigger). Now
      // we block on terminal state. On `AccountLoadError` we revert state
      // to `.loaded` (BookRegistrySync's own retry policy from
      // `waitForLoadThenRunSync` / account-change notifications drives the
      // next attempt — per the ADR's "no additional timeout" UX policy).
      let loansUrl: URL
      do {
        guard let resolvedLoansUrl = try await accountScope.loansURL(forAccount: accountUUID) else {
          Log.debug(#file, "BookRegistrySync abort: account \(accountUUID) has no loansUrl after awaitReady — anonymous library")
          await MainActor.run {
            callbacks.setState(.loaded)
            self.syncUrl = nil
            callbacks.completion?(nil, false)
          }
          return
        }
        loansUrl = resolvedLoansUrl
      } catch {
        Log.warn(#file, "BookRegistrySync abort: awaitReady failed for \(accountUUID): \(error)")
        await MainActor.run {
          callbacks.setState(.loaded)
          self.syncUrl = nil
          callbacks.completion?(nil, false)
        }
        return
      }

      await MainActor.run { [weak self] in
        self?.syncUrl = loansUrl
      }

      let feed: TPPOPDSFeed
      do {
        feed = try await opdsFeedService.fetchFeed(from: loansUrl, resetCache: true)
      } catch {
        let errorDocument = SendableErrorDocument(value: (error as NSError).userInfo as? [AnyHashable: Any])
        Log.warn(#file, "Loans sync failed: \(error.localizedDescription)")
        await MainActor.run {
          callbacks.setState(.loaded)
          self.syncUrl = nil
          callbacks.completion?(errorDocument.value, false)
        }
        return
      }

      await MainActor.run { [weak self] in
        guard let self else { return }
        if self.syncUrl != loansUrl { return }

        var changesMade = false
        // Collected inside the barrier; the filesystem deletes (which resolve
        // the content file URL and touch audiobook manifests on disk) run AFTER
        // the barrier releases. Calling deleteLocalContent inside the barrier
        // re-enters the registry via bookRegistry.book(forIdentifier:) and trips
        // Swift's exclusivity trap — same class of bug as the save() note below.
        var booksToDeleteLocally: [TPPBook] = []
        self.store.mutateRegistrySync { registry in
          var recordsToDelete = Set<String>(registry.keys)
          // Side-loaded books never appear in the loans feed. Exempt them so
          // reconciliation neither un-registers them (:480-481) nor deletes
          // their on-disk content (:496-497). See sideloading-plan.md R1.
          recordsToDelete.subtract(dependencies.sideloadedIdentifiers())
          for entry in feed.entries {
            guard let opdsEntry = entry as? TPPOPDSEntry,
                  let book = TPPBook(entry: opdsEntry)
            else { continue }
            recordsToDelete.remove(book.identifier)

            if let record = registry[book.identifier] {
              var nextState = record.state
              if record.state == .unregistered {
                book.defaultAcquisition?.availability.match(unavailable:
                  nil, limited: nil, unlimited: nil,
                  reserved: { _ in nextState = .holding },
                  ready: { _ in nextState = .holding }
                )
              }
              dependencies.onAvailabilityChange(record, book)
              // Preserve metadata already in the registry if the loans feed's
              // entry for this book came back lean (authors / summary /
              // categories missing). The CM's loans endpoint has been observed
              // to omit those fields intermittently — without this guard, a
              // later sync overwrites a previously-enriched record and MyBooks
              // cells lose their author line until a catalog visit refills it.
              let mergedBook = record.book.mergingPreservingMetadata(from: book)
              registry[book.identifier] = TPPBookRegistryRecord(
                book: mergedBook,
                location: record.location,
                state: nextState,
                fulfillmentId: record.fulfillmentId,
                readiumBookmarks: record.readiumBookmarks,
                genericBookmarks: record.genericBookmarks
              )
              changesMade = true
            } else {
              let initialState = TPPBookRegistryRecord.deriveInitialState(for: book)
              registry[book.identifier] = TPPBookRegistryRecord(
                book: book,
                state: initialState
              )
              changesMade = true
            }
          }

          // Guard against bulk deletion from truncated server responses
          let localCount = registry.count
          let feedCount = feed.entries.count
          let deletionCount = recordsToDelete.count
          let deletionRatio = localCount > 0 ? Double(deletionCount) / Double(localCount) : 0

          let shouldSkipBulkDeletion = BookRegistrySync.shouldSkipBulkDeletion(
            localCount: localCount, feedCount: feedCount, deletionCount: deletionCount
          )

          let shouldWarnLargeDeletion = localCount > 4
            && deletionRatio > 0.5
            && deletionCount > 2

          if shouldSkipBulkDeletion {
            Log.error(#file, "Sync returned EMPTY feed but \(localCount) local books exist - skipping deletion (possible server issue)")
          } else if shouldWarnLargeDeletion {
            Log.warn(#file, "Sync would remove \(deletionCount)/\(localCount) books (\(Int(deletionRatio * 100))%) - proceeding but logging for investigation")
          }

          if !shouldSkipBulkDeletion {
            recordsToDelete.forEach { identifier in
              guard let record = registry[identifier] else { return }

              let wasDownloaded = record.state == .downloadSuccessful || record.state == .used

              if wasDownloaded {
                Log.info(#file, "Removing expired/returned book '\(record.book.title)' (not in server feed)")
                booksToDeleteLocally.append(record.book)
              }

              registry[identifier]?.state = .unregistered
              registry.removeValue(forKey: identifier)
              changesMade = true
            }
          }
          // NOTE: do NOT call save(for:) inside the mutateRegistrySync barrier —
          // save() reads the store's snapshot via performSync, which tries to
          // re-enter registry access while this barrier still holds the `inout`
          // on it. That triggers a Swift exclusivity trap ("Simultaneous
          // accesses to registry, but modification requires exclusive access").
          // The save call lives below, after the barrier has released.
        }

        // Run the filesystem deletes outside the barrier. Using the book-based
        // overload so the call never re-enters the registry to look up the book
        // by identifier (the record is already gone at this point anyway).
        for book in booksToDeleteLocally {
          downloadService.deleteLocalContent(forBook: book, account: accountUUID)
        }

        if changesMade {
          // Server-authoritative: this snapshot is the result of reconciling
          // against the loans feed (guarded by shouldSkipBulkDeletion), so it is
          // allowed to persist an empty shelf and it clears needsRebuildFromServer.
          self.save(for: accountUUID, serverAuthoritative: true)
        }

        callbacks.setState(.synced)
        self.syncUrl = nil
        callbacks.completion?(nil, changesMade)
      }
    }
  }

  /// Persist the registry for the given account. The caller MUST pass the account
  /// that owns the mutation being persisted (captured synchronously at the moment
  /// of dispatch), not `accountsManager.currentAccount` looked up at save
  /// time. In async flows, a mutation queued on account A can execute after the
  /// user has switched to account B; looking up the current account inside `save()`
  /// would persist A's state to B's registry file and cause cross-account
  /// contamination (PP-4129 regression).
  func save(for account: String) {
    save(for: account, serverAuthoritative: false)
  }

  /// - Parameter serverAuthoritative: `true` only when the snapshot being
  ///   persisted is the result of an authoritative server reconciliation
  ///   (`sync()`'s loans-feed pass). An authoritative save may persist an empty
  ///   registry (e.g. all loans genuinely returned) and clears
  ///   `needsRebuildFromServer`. A non-authoritative save (local mutation,
  ///   content validation) is REFUSED when it would overwrite a non-empty
  ///   last-good `.bak` with an empty snapshot during the post-corrupt rebuild
  ///   window (INV-1).
  func save(for account: String, serverAuthoritative: Bool) {
    guard let registryUrl = registryUrl(for: account) else { return }

    let snapshot = store.registrySnapshot()
    let isEmpty = snapshot.isEmpty
    let needsRebuild = needsRebuildFromServer
    // Box the JSON payload so the `@Sendable` `diskWriteQueue.async` closure
    // captures a Sendable value rather than the raw `[String: Any]` (non-Sendable
    // because it holds `Any`). INVARIANT: the payload is built once here from a
    // fresh snapshot and only ever READ inside the closure (serialized to JSON on
    // `diskWriteQueue`), never mutated or shared. Mirrors `SendableErrorDocument`.
    let payload = SendableRegistryPayload(value: [
      RegistryFileRecovery.schemaVersionKey: RegistryFileRecovery.currentSchemaVersion,
      TPPBookRegistryKey.records.rawValue: snapshot
    ])

    diskWriteQueue.async { [self] in
      // INV-1: during the post-corrupt-load rebuild window, only an authoritative
      // server sync may persist an empty shelf. Refuse any other empty save — the
      // corrupt original is quarantined and the last-good `.bak` (if present) still
      // holds the shelf, so we must not overwrite the primary with an empty file
      // before `sync()` repopulates from the loans feed.
      if isEmpty, !serverAuthoritative, needsRebuild {
        Log.error(#file, "INV-1: refusing to persist an EMPTY registry during rebuild window (no server authority) — backup non-empty: \(RegistryFileRecovery.backupHasRecords(for: registryUrl))")
        return
      }
      do {
        let directoryURL = registryUrl.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
          try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        directoryURL.registryExcludeFromBackup()
        let registryData = try JSONSerialization.data(withJSONObject: payload.value, options: .fragmentsAllowed)
        // Refresh the last-good `.bak` BEFORE overwriting the primary, but only
        // for a good snapshot (non-empty, or a server-authoritative empty) so a
        // transient empty can never clobber the backup.
        if !isEmpty || serverAuthoritative {
          try? RegistryFileRecovery.writeBackup(data: registryData, for: registryUrl)
        }
        try registryData.write(to: registryUrl, options: .atomic)
        if !isEmpty || serverAuthoritative {
          needsRebuildFromServer = false
        }
        DispatchQueue.main.async {
          NotificationCenter.default.post(name: .TPPBookRegistryDidChange, object: nil, userInfo: nil)
        }
      } catch {
        Log.error(#file, "Error saving book registry: \(error.localizedDescription)")
      }
    }
  }

  /// Blocking save — used on teardown (scene disconnect, last-read-position) where
  /// the caller cannot yield. Same account-capture contract as `save(for:)`.
  func saveSync(for account: String) {
    guard let registryUrl = registryUrl(for: account) else { return }

    // Snapshot in the CALLER's context — NOT inside `diskWriteQueue`. `saveSync`
    // is reached from `BookmarkManager.setLocationSync`'s `onComplete`, which
    // runs inside a `BookRegistryStore.syncQueue` barrier. Taking the snapshot
    // inside `diskWriteQueue.sync` re-entered `syncQueue` (`registrySnapshot` →
    // `performSync` → `syncQueue.sync`) from a thread already holding that
    // barrier → deadlock (8afb1c66 — the hang #1061 traded for the disk-write
    // race). The in-memory snapshot is independent of disk-flush ordering, so
    // reading it here is behavior-equivalent for persistence.
    let snapshot = store.registrySnapshot()
    let isEmpty = snapshot.isEmpty
    let needsRebuild = needsRebuildFromServer
    let registryObject: [String: Any] = [
      RegistryFileRecovery.schemaVersionKey: RegistryFileRecovery.currentSchemaVersion,
      TPPBookRegistryKey.records.rawValue: snapshot
    ]

    // Serialize the disk write through `diskWriteQueue` so a sync save can't run
    // its `.atomic` rename-replace concurrently with an in-flight async write to
    // the same URL (the race #1061 fixed — preserved). Reentrancy-safe: if we are
    // ALREADY executing on `diskWriteQueue`, run inline — a nested
    // `diskWriteQueue.sync` would deadlock against itself.
    let write = {
      // INV-1: saveSync is teardown persistence (bookmarks/location), never a
      // server reconciliation — so it is always non-authoritative. Refuse an
      // empty snapshot over a non-empty backup during the rebuild window.
      if isEmpty, needsRebuild {
        Log.error(#file, "INV-1: refusing synchronous EMPTY registry save during rebuild window (backup non-empty: \(RegistryFileRecovery.backupHasRecords(for: registryUrl)))")
        return
      }
      do {
        let directoryURL = registryUrl.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
          try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        directoryURL.registryExcludeFromBackup()
        let registryData = try JSONSerialization.data(withJSONObject: registryObject, options: .fragmentsAllowed)
        if !isEmpty {
          try? RegistryFileRecovery.writeBackup(data: registryData, for: registryUrl)
        }
        try registryData.write(to: registryUrl, options: .atomic)
        if !isEmpty {
          self.needsRebuildFromServer = false
        }
        Log.debug(#file, "Synchronously saved registry to disk")
      } catch {
        Log.error(#file, "Error saving book registry synchronously: \(error.localizedDescription)")
      }
    }

    if DispatchQueue.getSpecific(key: diskWriteQueueKey) != nil {
      write()
    } else {
      diskWriteQueue.sync(execute: write)
    }
  }

  // MARK: - Test-only deterministic-join seam

  /// Test-only: drain any pending async disk writes enqueued by `save(for:)`.
  ///
  /// `diskWriteQueue` is serial, so a trailing `async` block resumes STRICTLY
  /// AFTER every previously-enqueued write block has finished flushing to disk
  /// (and enqueued its main-hop `.TPPBookRegistryDidChange` post) — including a
  /// refused INV-1 empty save, whose block runs and returns without writing.
  /// Bounded by construction: no `wait(for:)` deadline, no sleep/poll/clock.
  /// Mirrors `BookRegistryStore._awaitPendingWritesForTesting`. Production never
  /// calls it — it is a deterministic replacement for a `.TPPBookRegistryDidChange`
  /// deadline wait in the persistence contract tests (STARVE-001).
  func _awaitPendingDiskWritesForTesting() async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      diskWriteQueue.async { cont.resume() }
    }
  }

  func validateDownloadedContent() {
    guard let account = accountScope.currentAccountID else { return }

    var didChange = false
    store.mutateRegistrySync { registry in
      for (identifier, record) in registry {
        guard record.state == .downloadSuccessful || record.state == .used else { continue }
        let fileExists = self.downloadService.contentFileSatisfied(for: record.book, account: account)
        if !fileExists {
          Log.warn(#file, "Post-update validation: '\(record.book.title)' file missing - marking as downloadNeeded")
          registry[identifier]?.state = .downloadNeeded
          didChange = true
        }
      }
    }
    if didChange {
      save(for: account)
      DispatchQueue.main.async {
        NotificationCenter.default.post(name: .TPPBookRegistryDidChange, object: nil)
      }
    }
  }

  func reset(_ account: String) {
    syncUrl = nil
    store.removeAll()
    if let registryUrl = registryUrl(for: account) {
      do {
        try FileManager.default.removeItem(at: registryUrl)
      } catch {
        Log.error(#file, "Error deleting registry data: \(error.localizedDescription)")
      }
    }
  }

  /// Decides whether a sync() reconciliation should skip deleting books that
  /// are absent from the feed response.
  ///
  /// Any empty feed paired with any non-empty local registry is treated as a
  /// transient server/CDN error rather than a legitimate "all loans returned".
  /// The prior `localCount > 2` floor let 1- and 2-book shelves fall through
  /// and delete every downloaded book on a single bad response — the pattern
  /// that caused previously-downloaded books to show "Download" again after
  /// relaunch across a wifi→cellular→wifi transition.
  ///
  /// Static + internal so tests can call it directly without mocking the full
  /// feed-fetch pipeline.
  static func shouldSkipBulkDeletion(localCount: Int, feedCount: Int, deletionCount: Int) -> Bool {
    return localCount >= 1 && feedCount == 0 && deletionCount > 0
  }

  /// Thin delegate over the `contentFileSatisfied` seam (god-class decomp Wave 2b):
  /// the app-side adapter owns the `#if LCP` license-vs-content probe that used to
  /// live here — the SPM package never sees the `LCP` compilation condition. Kept as
  /// an internal method so the white-box `BookRegistrySyncTests` continue to exercise
  /// this call path through an injected download service.
  func checkIfBookFileExists(for book: TPPBook, account: String) -> Bool {
    return downloadService.contentFileSatisfied(for: book, account: account)
  }
}

// MARK: - Sendable carriers for `sync`'s @Sendable-closure captures

/// Sendable carrier for `sync`'s injected callbacks. `setState` and `completion`
/// are non-Sendable function values, but `sync` only ever *invokes* them on the
/// main thread — inside the `MainActor.run` blocks in `sync(...)`. Wrapping them
/// lets the `Task { … }` / `MainActor.run { … }` closures capture this box
/// (Sendable) instead of the raw closures, clearing the `targeted`
/// "capture of 'setState'/'completion' in @Sendable closure" diagnostics WITHOUT
/// rippling `@Sendable` onto the callers — the caller closures in
/// `TPPBookRegistry` capture the non-Sendable `TPPBookRegistry`, so an
/// `@Sendable` parameter would just relocate the warning upstream. Mirrors
/// `ImageCompletionBox` in `ImageLoaderImpl`.
private struct SyncCallbacks: @unchecked Sendable {
  let setState: (TPPBookRegistry.RegistryState) -> Void
  let completion: ((_ errorDocument: [AnyHashable: Any]?, _ newBooks: Bool) -> Void)?
}

/// Sendable carrier for `load`'s injected callbacks. Same rationale as
/// `SyncCallbacks`, but `load`'s `completion` is the no-argument `(() -> Void)?`
/// shape (fired once the registry is populated), so it needs its own struct.
/// `setState` and `completion` are non-Sendable function values invoked only on
/// the main thread (inside `load`'s `DispatchQueue.main.async` blocks); boxing
/// them here lets those `@Sendable` closures capture a Sendable value instead of
/// the raw closures, clearing the `complete`-mode "capture … in a '@Sendable'
/// closure" / "sending … risks data races" diagnostics WITHOUT rippling
/// `@Sendable` onto the `TPPBookRegistry` caller closures.
private struct LoadCallbacks: @unchecked Sendable {
  let setState: (TPPBookRegistry.RegistryState) -> Void
  let completion: (() -> Void)?
}

/// Sendable carrier for the OPDS sync error document (`[AnyHashable: Any]` from
/// `NSError.userInfo`, whose `Any` values are not Sendable). It is created once
/// from a caught error and only ever read thereafter (forwarded to `completion`),
/// so moving it across an isolation boundary (`MainActor.run`, an actor-hop
/// return, or a `withCheckedContinuation` resume) is race-free. `@unchecked`
/// documents that write-once-then-read confinement.
///
/// Module-internal (not `private`) so the sibling async extension in
/// `TPPBookRegistryAsync.swift` can box the same error-document shape when it
/// crosses the `@MainActor processLoansSync` / continuation boundaries, rather
/// than each site minting its own near-identical carrier.
public struct SendableErrorDocument: @unchecked Sendable {
  public let value: [AnyHashable: Any]?
  public init(value: [AnyHashable: Any]?) { self.value = value }
}

/// Sendable carrier for the JSON registry payload that `save(for:)` hands to the
/// `@Sendable` `diskWriteQueue.async` closure. The value is a
/// `[String: Any]` (non-Sendable — the `schemaVersion` Int and the `records` array, — holds `Any`) built once from a
/// fresh in-memory snapshot and only ever READ (serialized to JSON) on the disk
/// queue, never mutated or shared. `@unchecked` documents that write-once /
/// read-off-thread confinement. Mirrors `SendableErrorDocument`.
private struct SendableRegistryPayload: @unchecked Sendable {
  let value: [String: Any]
}
