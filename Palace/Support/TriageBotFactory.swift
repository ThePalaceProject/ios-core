//
//  TriageBotFactory.swift
//  Palace
//
//  Composition root for PalaceTriageBot: builds the view model with Palace
//  context collectors and picks the ticket gateway from Remote Config flags.
//  Callers must gate on `featureFlags.isTriageBotEnabled` (the master
//  kill-switch) before calling this factory.
//

import Foundation
import PalaceLogging
import PalaceFeatureFlags
import TriageBotCore
import TriageBotIOS

enum TriageBotFactory {

    /// Builds a fully-wired ViewModel for the active user. Returns nil if the
    /// bundled KB can't be loaded (degenerate; bot is unusable in that case).
    @MainActor
    static func makeViewModel(featureFlags: FeatureFlagProviding) -> Any? {
        // Synchronous load: the work is a bundled JSON read + decode. A
        // semaphore bridge over the async loader triggered iOS 26's "Hang Risk"
        // fault and could return nil on relaunch, hiding the Settings row.
        let catalog: KBCatalog
        do {
            catalog = try BundledCatalogSource.loadCatalogSync()
        } catch {
            Log.error(#file, "Triage bot: catalog load failed — \(error)")
            return nil
        }

        let kb = KnowledgeBase(catalog: catalog)

        // AI fallback: bootstraps the Anthropic API key from the
        // ANTHROPIC_API_KEY env var (Xcode scheme, DEBUG only) into the
        // Keychain on first call. If the key is present in the Keychain
        // AND the Firebase RC kill-switch is on, wire ClaudeFallbackClassifier
        // behind the local matcher. Otherwise the reducer's
        // aiFallbackEnabled stays false and behavior is local-only
        // (today's behavior — no regression).
        let keyStore = AnthropicKeyStore()
        let bootstrappedKey = keyStore.bootstrapFromEnvironmentIfNeeded()
        // Inert-by-default invariant (flag AND key) lives in TriageBotAIWiring so
        // it is unit-tested under `swift test`; see TriageBotAIWiringTests (PP-4810).
        let aiEnabled = TriageBotAIWiring.aiWiring(
            flagEnabled: featureFlags.isTriageBotAIFallbackEnabled,
            keyPresent: bootstrappedKey != nil
        )

        let fallbackClassifier: FallbackClassifier? = aiEnabled
            ? ClaudeFallbackClassifier(keyProvider: { keyStore.read() })
            : nil

        let reducer = ConversationReducer(
            knowledgeBase: kb,
            aiFallbackEnabled: aiEnabled
        )

        let fullContextProvider = DefaultIosContextProvider(
            palaceFields: { @Sendable in
                await Self.currentPalaceFields()
            },
            logSubsystem: Bundle.main.bundleIdentifier
        )
        // PP-4809: honor the patron's "Include diagnostics" choice (default ON).
        // OFF returns an app/OS/device-only snapshot without the full capture.
        let contextProvider = DiagnosticsGatingContextProvider(
            full: fullContextProvider,
            minimal: { fullContextProvider.minimalSnapshot() },
            preference: UserDefaultsDiagnosticsPreference()
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
        if featureFlags.isTriageBotTicketSubmissionEnabled {
            gateway = EmailTicketGateway(
                supportEmail: "support@thepalaceproject.org",
                fallback: ClipboardTicketGateway()
            )
        } else {
            gateway = ClipboardTicketGateway()
        }

        // PP-4808/PP-4813: DEBUG-only failure injection. On a simulator
        // canSendMail() is false and every gateway succeeds, so the error+retry
        // UI is unreachable. The "Force ticket submission failure" developer
        // toggle (or `-TriageBotForceSubmitFailure 1`) swaps in a gateway that
        // always throws `.transport`.
        let effectiveGateway: TicketGateway
        #if DEBUG
        // Read off the concrete type: a DEBUG-only requirement on
        // FeatureFlagProviding would differ across build configurations.
        if RemoteFeatureFlags.shared.isTriageBotForceSubmitFailureEnabled {
            effectiveGateway = ForcedFailureTicketGateway(mode: .transport)
        } else {
            effectiveGateway = gateway
        }
        #else
        effectiveGateway = gateway
        #endif

        // Telemetry sink: OSLog for local/dev visibility, Firebase Analytics in
        // release builds (PP-4814). Both forward only enumerable id/count/enum
        // parameters — FirebaseTriageTelemetrySink runs TelemetryContract so no
        // free text can reach Analytics.
        let sink: TelemetrySink
        #if DEBUG
        sink = OSLogTelemetrySink(subsystem: Bundle.main.bundleIdentifier ?? "palace", category: "triagebot")
        #else
        sink = FirebaseTriageTelemetrySink()
        #endif

        return makeViewModel(
            reducer: reducer,
            contextProvider: contextProvider,
            gateway: effectiveGateway,
            sink: sink,
            fallbackClassifier: fallbackClassifier
        )
    }

    // MARK: - Palace-specific field snapshot

    private static func currentPalaceFields() async -> DefaultIosContextProvider.PalaceFields {
        // Read `currentAccount` (main-actor state on the non-Sendable
        // AccountsManager) INSIDE the MainActor hop and return only the
        // already-`Sendable` PalaceFields snapshot. This keeps the
        // non-Sendable AccountsManager from crossing the actor boundary —
        // same values, same source, no behavior change.
        return await MainActor.run { () -> DefaultIosContextProvider.PalaceFields in
            let account = AppContainer.production().accountsManager.currentAccount
            return DefaultIosContextProvider.PalaceFields(
                libraryName: account?.name,
                libraryUUID: account?.uuid,
                distributor: nil,        // Phase 2: derive from catalog metadata
                authType: nil,           // Phase 2: derive from currentAuthentication
                // PP-4807: raw barcode — hashed by the redactor, omitted by default.
                barcode: TPPUserAccount.sharedAccount().barcode
            )
        }
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
        sink: TelemetrySink,
        fallbackClassifier: FallbackClassifier?
    ) -> TriageBotViewModel {
        TriageBotViewModel(
            reducer: reducer,
            contextProvider: contextProvider,
            ticketGateway: gateway,
            telemetry: sink,
            fallbackClassifier: fallbackClassifier,
            // PP-4808: persist a failed ticket so it can be re-offered next open.
            pendingDraftStore: UserDefaultsPendingDraftStore()
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
        sink: TelemetrySink,
        fallbackClassifier: FallbackClassifier?
    ) -> Any? {
        nil
    }
}
#endif
