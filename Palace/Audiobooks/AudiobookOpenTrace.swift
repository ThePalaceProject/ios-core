//
//  AudiobookOpenTrace.swift
//  Palace
//
//  Where the current audiobook open has got to. iOS reports no app hang, so a
//  patron left on the loading spinner leaves no crash report (PP-4973). Each
//  step change logs one info line, which reaches Crashlytics breadcrumbs, and
//  an open still running at the stall deadline is reported with its step.
//

import Foundation
import PalaceBookModel
import PalaceLogging

enum AudiobookOpenStep: String, Equatable {
    case stoppingPreviousSession = "stopping the previous session"
    case checkingAccess = "checking sign-in and content"
    case awaitingContent = "waiting for the content download"
    case loading = "loading the manifest and content"
}

/// An open that had not finished when its stall deadline passed.
struct AudiobookOpenStall: Equatable {
    let bookId: String
    let distributor: String?
    let origin: AudiobookOpenOrigin
    let step: AudiobookOpenStep
}

/// The open in progress. A newer open replaces it, so a superseded open can
/// neither move the step nor be reported as stalled.
struct AudiobookOpenTrace {
    /// The router's open-lock release, after which a repeated tap starts a new
    /// open. Read from the router rather than copied, so the two cannot drift:
    /// a deadline shorter than the lock reports opens that are still allowed to
    /// finish, and a longer one leaves the window after the lock unreported.
    static let stallDeadline: TimeInterval = BookOpenRouter.openLockSafetyRelease

    private(set) var openId: UUID?
    private var book: (id: String, distributor: String?)?
    private var origin: AudiobookOpenOrigin = .patron
    private(set) var step: AudiobookOpenStep?

    /// Starts tracing a new open and returns its id.
    mutating func begin(bookId: String, distributor: String?, origin: AudiobookOpenOrigin) -> UUID {
        let id = UUID()
        openId = id
        book = (bookId, distributor)
        self.origin = origin
        step = nil
        return id
    }

    /// Moves open `id` to `step`. Returns the line to log, or nil when `id`
    /// is no longer the current open.
    mutating func enter(_ step: AudiobookOpenStep, for id: UUID) -> String? {
        guard id == openId, let book else { return nil }
        self.step = step
        return "Audiobook open \(book.id) (\(origin)): \(step.rawValue)"
    }

    /// Ends open `id`. A newer open's trace is left alone.
    mutating func finish(_ id: UUID) {
        guard id == openId else { return }
        openId = nil
        book = nil
        step = nil
    }

    /// The stall report for open `id`, if it is still the current open. A
    /// content download is not a stall: it shows its progress and has its own
    /// 180 s bound that ends in an alert.
    func stall(of id: UUID) -> AudiobookOpenStall? {
        guard id == openId, let book, let step, step != .awaitingContent else { return nil }
        return AudiobookOpenStall(bookId: book.id, distributor: book.distributor, origin: origin, step: step)
    }
}

/// Owns the open trace for the session: logs each step and reports an open
/// still running at the stall deadline. The scheduler and the reporter are
/// injected so tests fire the deadline by hand.
@MainActor
final class AudiobookOpenMonitor {
    typealias Scheduler = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void

    private var trace = AudiobookOpenTrace()
    private let schedule: Scheduler
    private let report: @MainActor (AudiobookOpenStall) -> Void

    init(schedule: @escaping Scheduler = AudiobookOpenMonitor.scheduleOnMainQueue,
         report: @escaping @MainActor (AudiobookOpenStall) -> Void = { AudiobookOpenMonitor.record($0) }) {
        self.schedule = schedule
        self.report = report
    }

    func begin(_ book: TPPBook, origin: AudiobookOpenOrigin) -> UUID {
        let openId = trace.begin(bookId: book.identifier, distributor: book.distributor, origin: origin)
        schedule(AudiobookOpenTrace.stallDeadline) { [weak self] in
            guard let self, let stall = self.trace.stall(of: openId) else { return }
            self.report(stall)
        }
        return openId
    }

    func enter(_ step: AudiobookOpenStep, for openId: UUID) {
        if let line = trace.enter(step, for: openId) {
            Log.info(#file, line)
        }
    }

    func finish(_ openId: UUID) {
        trace.finish(openId)
    }

    /// Records an open still in flight at the deadline. A hang leaves no crash
    /// report on iOS, so this is the only count of opens that never finish. It
    /// does not count a session parked at `.loading` between opens.
    ///
    /// `emit` is injected so a test can assert that the event is sent at all;
    /// the payload itself is pinned through `stallReportPayload`.
    static func record(
        _ stall: AudiobookOpenStall,
        emit: FleetEventEmitting = { code, summary, metadata in
            TPPErrorLogger.logError(withCode: code, summary: summary, metadata: metadata)
        }
    ) {
        Log.error(#file, "Audiobook open \(stall.bookId) (\(stall.origin)) still \(stall.step.rawValue) after \(Int(AudiobookOpenTrace.stallDeadline))s")
        let payload = stallReportPayload(for: stall)
        emit(payload.code, payload.summary, payload.metadata)
    }

    /// The exact event a stalled open puts on the wire.
    ///
    /// Separate from the emit so `AudiobookOpenTraceTests` can pin the code and
    /// the key set: these reports are the only signal that an open hung, so a
    /// renamed key empties a Crashlytics view that nothing else refills.
    static func stallReportPayload(
        for stall: AudiobookOpenStall
    ) -> (code: TPPErrorCode, summary: String, metadata: [String: Any]) {
        (
            .audiobookOpenStalled,
            "Audiobook open stalled: \(stall.step.rawValue)",
            [
                "bookId": stall.bookId,
                "distributor": stall.distributor ?? "unknown",
                "origin": stall.origin.description,
                "step": stall.step.rawValue
            ]
        )
    }

    static func scheduleOnMainQueue(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { work() }
        }
    }
}
