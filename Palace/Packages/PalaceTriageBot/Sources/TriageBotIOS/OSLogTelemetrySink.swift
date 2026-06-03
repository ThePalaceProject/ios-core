import Foundation
import OSLog
import TriageBotCore

/// Default TelemetrySink that writes events to OSLog under the configured
/// subsystem. Useful for demo + dev. Production replaces with a Firebase-
/// backed sink, but the protocol contract stays identical so the reducer
/// doesn't notice.
public struct OSLogTelemetrySink: TelemetrySink {
    private let logger: Logger

    public init(subsystem: String = "org.thepalaceproject.palace.triagebot", category: String = "telemetry") {
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    public func emit(_ event: TelemetryEvent) {
        // Parameters are pre-redacted by the reducer (no PII enters here),
        // but we still log defensively at .info — never .debug, so they
        // ship in TestFlight runs too.
        let params = event.parameters
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        logger.info("triagebot.\(event.name, privacy: .public) \(params, privacy: .public)")
    }
}
