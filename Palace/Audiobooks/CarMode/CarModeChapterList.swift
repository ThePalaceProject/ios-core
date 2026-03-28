//
//  CarModeChapterList.swift
//  Palace
//
//  Simplified chapter navigation list for car mode.
//  Large rows with current chapter highlighted. Tap to jump.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI

// MARK: - CarModeChapterList

public struct CarModeChapterList: View {

    let chapters: [CarModeChapterInfo]
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    private let impactFeedback = UIImpactFeedbackGenerator(style: .light)

    public var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(chapters) { chapter in
                            chapterRow(chapter)
                                .id(chapter.index)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onAppear {
                    // Scroll to current chapter
                    if let current = chapters.first(where: { $0.isCurrent }) {
                        proxy.scrollTo(current.index, anchor: .center)
                    }
                }
            }
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 18, weight: .semibold))
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Chapter Row

    private func chapterRow(_ chapter: CarModeChapterInfo) -> some View {
        Button(action: {
            impactFeedback.impactOccurred()
            onSelect(chapter.index)
        }) {
            HStack(spacing: 12) {
                // Current chapter indicator
                if chapter.isCurrent {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.yellow)
                        .frame(width: 28)
                } else {
                    Text("\(chapter.index + 1)")
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                        .frame(width: 28)
                }

                // Chapter title
                Text(chapter.title)
                    .font(.system(size: 20, weight: chapter.isCurrent ? .bold : .regular))
                    .foregroundColor(chapter.isCurrent ? .yellow : .white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer()

                // Duration
                Text(chapter.formattedDuration)
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(chapter.isCurrent ? Color.white.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .accessibilityLabel("\(chapter.title), \(chapter.formattedDuration)")
        .accessibilityAddTraits(chapter.isCurrent ? .isSelected : [])
        .accessibilityHint("Jumps to this chapter")
    }
}
