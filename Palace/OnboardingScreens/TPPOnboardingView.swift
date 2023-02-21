//
//  TPPOnboardingView.swift
//  Palace
//
//  Created by Vladimir Fedorov on 08.12.2021.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import SwiftUI

struct TPPOnboardingView: View {
  
  // 2 x pan distance to switch between slides
  // (relative to screen width)
  private var activationDistance: CGFloat = 0.8
  
  private var onboardingImageNames =
    ["Onboarding-1", "Onboarding-2", "Onboarding-3"]
  @GestureState private var translation: CGFloat = 0
  
  @State private var currentIndex = 0 {
    didSet {
      // Dismiss the view after the user swipes past the last slide.
      if currentIndex == onboardingImageNames.count {
        dismissView()
      }
    }
  }
  
  // dismiss handler
  var dismissView: (() -> Void)
  
  init(dismissHandler: @escaping (() -> Void)) {
    self.dismissView = dismissHandler
  }
  
  var body: some View {
    ZStack(alignment: .top) {
      onboardingSlides()
      pagerDots()
      closeButton()
    }
    .edgesIgnoringSafeArea(.all)
    .statusBar(hidden: true)
  }
  
  @ViewBuilder
  private func onboardingSlides() -> some View {
    GeometryReader { geometry in
      HStack(spacing: 0) {
        ForEach(onboardingImageNames, id: \.self) { imageName in
          Image(imageName)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: geometry.size.width)
            .accessibility(label: Text(NSLocalizedString(imageName, comment: "Onboarding slide localised description")))
        }
      }
      .contentShape(Rectangle())
      .frame(width: geometry.size.width, alignment: .leading)
      .offset(x: translation - CGFloat(currentIndex) * geometry.size.width)
      .animation(.interactiveSpring(), value: currentIndex)
      .gesture(
        DragGesture()
          .updating($translation) { value, state, _translation in
            state = value.translation.width
          }
          .onEnded { value in
            let offset = value.translation.width / geometry.size.width / activationDistance
            let newIndex = (CGFloat(currentIndex) - offset).rounded()
            // This is intentional, it makes possible swiping past the last slide to dismiss this view.
            let lastIndex = onboardingImageNames.count
            currentIndex = min(max(Int(newIndex), 0), lastIndex)
          }
      )
    }
    .background(
      Color(UIColor(named: "OnboardingBackground") ?? .systemBackground)
    )
  }
  
  @ViewBuilder
  private func pagerDots() -> some View {
    VStack {
      Spacer()
      TPPPagerDotsView(count: onboardingImageNames.count, currentIndex: $currentIndex)
        .padding()
    }
  }
  
  @ViewBuilder
  private func closeButton() -> some View {
    HStack {
      Spacer()
      Button {
        dismissView()
      } label: {
        Image(systemName: "xmark.circle.fill")
          .font(.title)
          .foregroundColor(.gray)
          .padding()
      }
      .accessibility(label: Text(Strings.Generic.close))
    }
  }
}
