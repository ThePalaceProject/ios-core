//
//  CoverDebugLabels.swift
//  Palace
//
//  PP-5285: format and DRM labels drawn on covers when the Testing menu toggle
//  is on, so testers can find a format/DRM combination without opening books.
//

import SwiftUI
import PalaceCatalog

/// The two labels for one title. Values are derived only from the final content
/// type of each acquisition path, so they agree with the other Palace clients:
/// an LCP or Adobe EPUB reads "epub"/"none", because its final type is the EPUB.
struct CoverDebugLabels: Equatable {
    let format: String
    let drm: String

    static func overlay(for acquisitions: [TPPOPDSAcquisition], enabled: Bool) -> CoverDebugLabels? {
        enabled ? labels(for: acquisitions) : nil
    }

    static func labels(for acquisitions: [TPPOPDSAcquisition]) -> CoverDebugLabels {
        // Sample and preview links are not acquisitions of the title itself.
        let acquisitions = acquisitions.filter { $0.relation != .sample && $0.relation != .preview }
        let finalTypesPerAcquisition = acquisitions.map { finalTypes(of: $0) }
        return CoverDebugLabels(
            format: format(of: finalTypesPerAcquisition),
            drm: drm(of: Set(finalTypesPerAcquisition.joined()))
        )
    }

    // MARK: - Format

    private static let epubTypes: Set<String> = [
        "application/epub+zip",
        "application/vnd.librarysimplified.axisnow+json",
    ]
    private static let audiobookTypes: Set<String> = [
        "application/vnd.librarysimplified.findaway.license+json",
        "application/audiobook+json",
        "audio/mpeg",
        "application/audiobook+lcp",
        "application/vnd.overdrive.circulation.api+json",
    ]
    private static let pdfTypes: Set<String> = ["application/pdf"]

    /// The first acquisition with a recognised final type decides; within one
    /// acquisition EPUB wins over audiobook, which wins over PDF.
    private static func format(of finalTypesPerAcquisition: [Set<String>]) -> String {
        let formats: [(name: String, types: Set<String>)] = [
            ("epub", epubTypes), ("audiobook", audiobookTypes), ("pdf", pdfTypes),
        ]
        for types in finalTypesPerAcquisition {
            if let match = formats.first(where: { !$0.types.isDisjoint(with: types) }) {
                return match.name
            }
        }
        return "unknown"
    }

    // MARK: - DRM

    private static func drm(of types: Set<String>) -> String {
        func has(_ names: String...) -> Bool { names.contains(where: types.contains) }

        if has("application/vnd.readium.lcp.license.v1.0+json", "application/audiobook+lcp") { return "LCP" }
        if has("application/vnd.adobe.adept+xml") { return "Adobe" }
        if has("application/vnd.thepalaceproject.baker-taylor.kdrm+json") { return "Boundless" }
        if has("application/vnd.librarysimplified.findaway.license+json") { return "Findaway" }
        if has("application/vnd.overdrive.circulation.api+json") { return "Overdrive" }
        return "none"
    }

    // MARK: - Content types

    /// The last type on every path through the acquisition, without parameters.
    private static func finalTypes(of acquisition: TPPOPDSAcquisition) -> Set<String> {
        guard !acquisition.indirectAcquisitions.isEmpty else { return [baseType(acquisition.type)] }
        var result = Set<String>()
        var pending = acquisition.indirectAcquisitions
        while let node = pending.popLast() {
            if node.indirectAcquisitions.isEmpty {
                result.insert(baseType(node.type))
            } else {
                pending.append(contentsOf: node.indirectAcquisitions)
            }
        }
        return result
    }

    private static func baseType(_ type: String) -> String {
        (type.split(separator: ";", maxSplits: 1).first.map(String.init) ?? type)
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }
}

/// The labels as drawn on a cover. Hidden from VoiceOver: the cover is already
/// decorative and the cell announces the book.
struct CoverDebugLabelsOverlay: View {
    let labels: CoverDebugLabels

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            tag(labels.format)
            tag(labels.drm)
        }
        .padding(4)
        .accessibilityHidden(true)
    }

    /// Light text on a dark plate with a light rim reads over both light and
    /// dark cover art.
    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.78)))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.7), lineWidth: 0.5))
    }
}
