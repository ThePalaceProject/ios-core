//
//  TriageBotFactory.swift
//  Palace
//
//  Palace-side composition root for the PalaceTriageBot package. Builds the
//  TriageBotViewModel with Palace-specific context-collector lambdas and
//  ticket-gateway selection (real submission vs. demo-clipboard) based on
//  Firebase Remote Config flags.
//
//  Visibility of the whole bot — Settings row, chat surface, anything —
//  must be gated on `RemoteFeatureFlags.shared.isTriageBotEnabled` BEFORE
//  this factory is called. Treat that flag as the master kill-switch.
//

import Foundation
import PalaceLogging
import TriageBotCore
import TriageBotIOS

enum TriageBotFactory {

    /// Builds a fully-wired ViewModel for the active user. Returns nil if the
    /// bundled KB can't be loaded (degenerate; bot is unusable in that case).
    @MainActor
    static func makeViewModel() -> Any? {
        // Bundled catalog — synchronous load to keep this call site simple.
        // Server-backed source (Phase 2) implements the same protocol and
        // would slot in here without changes elsewhere.
        let source = BundledCatalogSource()
        let catalog: KBCatalog
        do {
            catalog = try syncLoad(source: source)
        } catch {
            Log.error(#file, "Triage bot: catalog load failed — \(error)")
            return nil
        }

        let kb = KnowledgeBase(catalog: catalog)
        let reducer = ConversationReducer(knowledgeBase: kb)

        let contextProvider = DefaultIosContextProvider(
            palaceFields: { @Sendable in
                await Self.currentPalaceFields()
            },
            logSubsystem: Bundle.main.bundleIdentifier
        )

        // Gateway selection:
        //   - Submission ON: EmailTicketGateway opens the iOS Mail composer
        //     pre-filled with the support address, body, and palace-diagnostics.json
        //     + palace-logs.txt attachments. The user reviews + sends from their
        //     own mail account — bot never sends programmatically.
        //   - Submission OFF: ClipboardTicketGateway copies the JSON payload so
        //     the conversation flow stays exercisable without poking real email.
        //   - Either way, EmailTicketGateway has ClipboardTicketGateway as an
        //     internal fallback when canSendMail() returns false (sim without
        //     configured Mail account), so the demo never gets stuck.
        let gateway: TicketGateway
        if RemoteFeatureFlags.shared.isTriageBotTicketSubmissionEnabled {
            gateway = EmailTicketGateway(
                supportEmail: "support@thepalaceproject.org",
                fallback: ClipboardTicketGateway()
            )
        } else {
            gateway = ClipboardTicketGateway()
        }

        let sink = OSLogTelemetrySink(subsystem: Bundle.main.bundleIdentifier ?? "palace", category: "triagebot")

        return makeViewModel(
            reducer: reducer,
            contextProvider: contextProvider,
            gateway: gateway,
            sink: sink
        )
    }

    // MARK: - Palace-specific field snapshot

    private static func currentPalaceFields() async -> DefaultIosContextProvider.PalaceFields {
        let manager = await MainActor.run { AppContainer.production().accountsManager }
        let account = manager.currentAccount

        return DefaultIosContextProvider.PalaceFields(
            libraryName: account?.name,
            libraryUUID: account?.uuid,
            distributor: nil,        // Phase 2: derive from catalog metadata
            authType: nil            // Phase 2: derive from currentAuthentication
        )
    }

    // MARK: - Helpers

    /// Synchronous wrapper around the KnowledgeBaseSource async API. The
    /// bundled source reads a small JSON file off disk — blocking briefly
    /// on the main thread at Settings entry is acceptable. A server-backed
    /// source would prefetch in AppDelegate.
    private static func syncLoad(source: KnowledgeBaseSource) throws -> KBCatalog {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<KBCatalog, Error>!
        Task {
            do {
                let catalog = try await source.loadCatalog()
                result = .success(catalog)
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }
}

// The TriageBotViewModel construction is wrapped in a generic helper because
// the ViewModel itself is only available when UIKit is — same canImport guard
// as the package's UI target. Outside iOS this returns nil and callers (the
// SwiftUI host below) won't render the chat surface.
#if canImport(UIKit)
import TriageBotUI

private extension TriageBotFactory {
    @MainActor
    static func makeViewModel(
        reducer: ConversationReducer,
        contextProvider: ContextProvider,
        gateway: TicketGateway,
        sink: TelemetrySink
    ) -> TriageBotViewModel {
        TriageBotViewModel(
            reducer: reducer,
            contextProvider: contextProvider,
            ticketGateway: gateway,
            telemetry: sink
        )
    }
}
#else
private extension TriageBotFactory {
    @MainActor
    static func makeViewModel(
        reducer: ConversationReducer,
        contextProvider: ContextProvider,
        gateway: TicketGateway,
        sink: TelemetrySink
    ) -> Any? {
        nil
    }
}
#endif
