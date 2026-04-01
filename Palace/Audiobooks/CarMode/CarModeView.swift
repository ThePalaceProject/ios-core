//
//  CarModeView.swift
//  Palace
//
//  Fullscreen car mode view for audiobook playback.
//  Designed for maximum glanceability: large buttons, high contrast, dark background.
//  All interactive elements have minimum 60pt tap targets.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI
import Combine

// MARK: - CarModeView

public struct CarModeView: View {

    @ObservedObject var viewModel: CarModeViewModel

    // MARK: - Layout Constants

    private enum Layout {
        static let playButtonSize: CGFloat = 120
        static let skipButtonSize: CGFloat = 72
        static let bottomButtonSize: CGFloat = 60
        static let progressBarHeight: CGFloat = 8
        static let minimumTextSize: CGFloat = 18
        static let titleTextSize: CGFloat = 24
        static let chapterTextSize: CGFloat = 20
        static let timeTextSize: CGFloat = 16
        static let blurRadius: CGFloat = 40
        static let controlsSpacing: CGFloat = 32
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            // Background: blurred cover art on dark
            backgroundLayer

            // Content
            VStack(spacing: 0) {
                // Top: Book title + chapter
                headerSection
                    .padding(.top, 16)

                Spacer()

                // Center: Play/pause + skip controls
                controlsSection

                Spacer()

                // Progress bar
                progressSection
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)

                // Bottom row: Speed, Sleep, Chapters, Exit
                bottomToolbar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .sheet(isPresented: $viewModel.showingSpeedPicker) {
            CarModeSpeedPicker(
                currentSpeed: viewModel.playbackSpeed,
                onSelect: { viewModel.setSpeed($0) }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $viewModel.showingSleepTimerPicker) {
            CarModeSleepTimerPicker(
                timerState: viewModel.sleepTimer,
                onSelect: { viewModel.setSleepTimer($0) },
                onCancel: { viewModel.cancelSleepTimer() }
            )
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $viewModel.showingChapterList) {
            CarModeChapterList(
                chapters: viewModel.chapters,
                onSelect: { viewModel.jumpToChapter(at: $0) }
            )
            .presentationDetents([.medium, .large])
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Car Mode Audiobook Player")
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if let cover = viewModel.currentBook?.coverImage {
                Image(uiImage: cover)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: Layout.blurRadius)
                    .opacity(0.3)
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            Text(viewModel.currentBook?.title ?? "No Book")
                .font(.system(size: Layout.titleTextSize, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text(viewModel.currentChapter)
                .font(.system(size: Layout.chapterTextSize, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Controls

    private var controlsSection: some View {
        HStack(spacing: Layout.controlsSpacing) {
            // Skip back 15s
            skipButton(
                systemName: "gobackward.15",
                label: "Skip back 15 seconds",
                action: { viewModel.skipBack() }
            )

            // Play/Pause
            playPauseButton

            // Skip forward 30s
            skipButton(
                systemName: "goforward.30",
                label: "Skip forward 30 seconds",
                action: { viewModel.skipForward() }
            )
        }
    }

    private var playPauseButton: some View {
        Button(action: { viewModel.togglePlayback() }) {
            Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 52, weight: .bold))
                .foregroundColor(.white)
                .frame(width: Layout.playButtonSize, height: Layout.playButtonSize)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.2))
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.4), lineWidth: 2)
                )
        }
        .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")
        .accessibilityHint(viewModel.isPlaying ? "Pauses audiobook playback" : "Resumes audiobook playback")
    }

    private func skipButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 30, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: Layout.skipButtonSize, height: Layout.skipButtonSize)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.12))
                )
        }
        .accessibilityLabel(label)
    }

    // MARK: - Progress

    private var progressSection: some View {
        VStack(spacing: 8) {
            // Progress bar (non-interactive for safety)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: Layout.progressBarHeight / 2)
                        .fill(Color.white.opacity(0.2))
                        .frame(height: Layout.progressBarHeight)

                    RoundedRectangle(cornerRadius: Layout.progressBarHeight / 2)
                        .fill(Color.white.opacity(0.8))
                        .frame(
                            width: geometry.size.width * CGFloat(viewModel.progress),
                            height: Layout.progressBarHeight
                        )
                        .animation(.linear(duration: 0.3), value: viewModel.progress)
                }
            }
            .frame(height: Layout.progressBarHeight)
            .accessibilityElement()
            .accessibilityLabel("Chapter progress")
            .accessibilityValue("\(Int(viewModel.progress * 100)) percent")

            // Time labels
            HStack {
                Text(viewModel.elapsedTime)
                    .font(.system(size: Layout.timeTextSize, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))

                Spacer()

                Text("-\(viewModel.remainingTime)")
                    .font(.system(size: Layout.timeTextSize, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
    }

    // MARK: - Bottom Toolbar

    private var bottomToolbar: some View {
        HStack(spacing: 0) {
            // Speed
            toolbarButton(
                title: viewModel.speedLabel,
                systemName: "speedometer",
                action: { viewModel.showingSpeedPicker = true }
            )
            .accessibilityLabel("Playback speed \(viewModel.speedLabel)")
            .accessibilityHint("Opens speed picker")

            Spacer()

            // Sleep Timer
            toolbarButton(
                title: viewModel.sleepTimer.buttonLabel,
                systemName: viewModel.sleepTimer.isActive ? "moon.fill" : "moon",
                isActive: viewModel.sleepTimer.isActive,
                action: { viewModel.showingSleepTimerPicker = true }
            )
            .accessibilityLabel(viewModel.sleepTimer.isActive
                ? "Sleep timer active, \(viewModel.sleepTimer.buttonLabel) remaining"
                : "Sleep timer off")
            .accessibilityHint("Opens sleep timer options")

            Spacer()

            // Chapters
            toolbarButton(
                title: "Chapters",
                systemName: "list.bullet",
                action: { viewModel.showingChapterList = true }
            )
            .accessibilityLabel("Chapter list")
            .accessibilityHint("Opens chapter navigation")

            Spacer()

            // Exit
            toolbarButton(
                title: "Exit",
                systemName: "xmark.circle",
                action: { viewModel.exitCarMode() }
            )
            .accessibilityLabel("Exit car mode")
        }
    }

    private func toolbarButton(
        title: String,
        systemName: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 22, weight: .medium))

                Text(title)
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundColor(isActive ? .yellow : .white)
            .frame(minWidth: Layout.bottomButtonSize, minHeight: Layout.bottomButtonSize)
            .contentShape(Rectangle())
        }
    }
}

// MARK: - Preview

#if DEBUG
struct CarModeView_Previews: PreviewProvider {
    static var previews: some View {
        CarModeView(viewModel: CarModeViewModel(service: PreviewCarModeService()))
    }
}

/// A minimal mock service for SwiftUI previews.
@MainActor
private final class PreviewCarModeService: CarModeServiceProtocol {
    var isCarModeActive: Bool = true
    var currentBookInfo: CarModeBookInfo? = CarModeBookInfo(
        identifier: "preview",
        title: "The Great Gatsby",
        author: "F. Scott Fitzgerald",
        coverImage: nil,
        totalDuration: 3600,
        progress: 0.45
    )
    var currentChapterTitle: String = "Chapter 5: The Party"
    var chapters: [CarModeChapterInfo] = []
    var isPlaying: Bool = true
    var playbackSpeed: PlaybackSpeed = .normal
    var sleepTimerState: SleepTimerState = .inactive
    var elapsedTimeFormatted: String = "12:34"
    var remainingTimeFormatted: String = "23:45"
    var elapsedSeconds: TimeInterval = 754
    var chapterDurationSeconds: TimeInterval = 1800
    var statePublisher: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher()

    func enterCarMode() {}
    func exitCarMode() {}
    func togglePlayback() {}
    func skipForward() {}
    func skipBack() {}
    func nextChapter() {}
    func previousChapter() {}
    func jumpToChapter(at index: Int) {}
    func setSpeed(_ speed: PlaybackSpeed) {}
    func setSleepTimer(_ option: SleepTimerOption) {}
    func cancelSleepTimer() {}
}
#endif
