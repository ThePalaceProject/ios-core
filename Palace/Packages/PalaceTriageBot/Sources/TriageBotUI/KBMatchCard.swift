#if canImport(UIKit)
import SwiftUI
import TriageBotCore

struct KBMatchCard: View {
    enum Action {
        case notifyMe
        case fileAnyway
        case dismiss
    }

    let entry: KBEntry
    let onAction: (Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusBadge

            Text(entry.userFacingWorkaround)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if entry.status == .fixedIn {
                    actionButton("Notify me when fixed", systemImage: "bell.fill") {
                        onAction(.notifyMe)
                    }
                }
                actionButton("File ticket anyway", systemImage: "envelope.fill") {
                    onAction(.fileAnyway)
                }
            }

            Button("Thanks, I'm good") {
                onAction(.dismiss)
            }
            .font(.footnote)
            .foregroundColor(.secondary)
        }
        .padding(14)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Known issue match: \(entry.id)")
    }

    @ViewBuilder private var statusBadge: some View {
        let (label, color): (String, Color) = {
            switch entry.status {
            case .fixedIn: return ("Fixed in \(entry.fixedInVersion ?? "next release")", .green)
            case .open: return ("Known issue — workaround available", .orange)
            case .userError: return ("Likely a setup mix-up", .blue)
            case .wontfix: return ("By design", .gray)
            case .duplicateOf: return ("Tracked", .gray)
            }
        }()
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundColor(color)
    }

    @ViewBuilder private func actionButton(
        _ label: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
#endif
