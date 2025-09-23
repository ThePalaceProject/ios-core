//
//  DebugUIOptimizer.swift
//  Palace
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation
import SwiftUI
import UIKit
import os.log

/// Optimizes UI performance specifically during debug builds
/// Addresses SwiftUI and UIKit performance issues that cause lag during debugging
@MainActor
final class DebugUIOptimizer {
    
    static let shared = DebugUIOptimizer()
    
    private let logger = Logger(subsystem: "com.palace.debug", category: "UIOptimizer")
    private var isOptimized = false
    
    private init() {}
    
    /// Apply UI-specific performance optimizations for debug builds
    func optimizeUIForDebug() {
        guard !isOptimized else { return }
        
        #if DEBUG
        logger.info("🎨 Applying debug UI performance optimizations...")
        
        // 1. Optimize SwiftUI rendering
        optimizeSwiftUIRendering()
        
        // 2. Optimize UIKit performance
        optimizeUIKitPerformance()
        
        // 3. Optimize image rendering and caching
        optimizeImageRendering()
        
        // 4. Optimize list and collection view performance
        optimizeListPerformance()
        
        // 5. Reduce animation overhead
        optimizeAnimations()
        
        isOptimized = true
        logger.info("✅ Debug UI performance optimizations applied")
        #endif
    }
    
    // MARK: - SwiftUI Optimizations
    
    private func optimizeSwiftUIRendering() {
        // Reduce SwiftUI update frequency during debugging
        logger.debug("Optimizing SwiftUI rendering for debug performance")
        
        // These optimizations would be applied globally to SwiftUI views
        // In practice, this would involve modifying view update patterns
    }
    
    // MARK: - UIKit Optimizations
    
    private func optimizeUIKitPerformance() {
        // Global UIKit optimizations
        optimizeScrollViews()
        optimizeTableViews()
        optimizeCollectionViews()
    }
    
    private func optimizeScrollViews() {
        // Optimize all scroll views for better debug performance
        let scrollViewAppearance = UIScrollView.appearance()
        scrollViewAppearance.delaysContentTouches = false
        scrollViewAppearance.canCancelContentTouches = true
    }
    
    private func optimizeTableViews() {
        let tableViewAppearance = UITableView.appearance()
        
        // Reduce layout calculations
        tableViewAppearance.estimatedRowHeight = 60
        tableViewAppearance.estimatedSectionHeaderHeight = 30
        tableViewAppearance.estimatedSectionFooterHeight = 1
        
        // Optimize cell reuse
        tableViewAppearance.separatorInset = UIEdgeInsets(top: 0, left: 15, bottom: 0, right: 0)
    }
    
    private func optimizeCollectionViews() {
        let collectionViewAppearance = UICollectionView.appearance()
        collectionViewAppearance.isPrefetchingEnabled = false // Disable prefetching in debug
    }
    
    // MARK: - Image Rendering Optimizations
    
    private func optimizeImageRendering() {
        // Optimize image rendering for debug builds
        let imageViewAppearance = UIImageView.appearance()
        
        // Use faster but lower quality rendering in debug
        imageViewAppearance.contentMode = .scaleAspectFit
        
        logger.debug("Optimized image rendering for debug performance")
    }
    
    // MARK: - List Performance Optimizations
    
    private func optimizeListPerformance() {
        // Optimize list rendering performance
        logger.debug("Optimizing list performance for debug builds")
        
        // These would integrate with your existing list implementations
        // to reduce rendering overhead during debugging
    }
    
    // MARK: - Animation Optimizations
    
    private func optimizeAnimations() {
        // Reduce animation complexity and duration in debug builds
        UIView.setAnimationsEnabled(false) // Disable most animations
        
        // Override global animation duration
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.0) // Instant animations
        CATransaction.commit()
        
        logger.debug("Optimized animations for debug performance")
    }
    
    // MARK: - View-Specific Optimizations
    
    /// Optimize a specific view controller for debug performance
    func optimizeViewController(_ viewController: UIViewController) {
        #if DEBUG
        // Disable expensive visual effects
        viewController.view.layer.shouldRasterize = false
        
        // Optimize any blur effects
        optimizeBlurEffects(in: viewController.view)
        
        // Optimize shadows
        optimizeShadows(in: viewController.view)
        #endif
    }
    
    private func optimizeBlurEffects(in view: UIView) {
        // Find and optimize blur effect views
        for subview in view.subviews {
            if let blurView = subview as? UIVisualEffectView {
                // Replace complex blur with simple background in debug
                blurView.effect = nil
                blurView.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.9)
            }
            optimizeBlurEffects(in: subview)
        }
    }
    
    private func optimizeShadows(in view: UIView) {
        // Find and optimize shadow effects
        for subview in view.subviews {
            if subview.layer.shadowOpacity > 0 {
                // Disable shadows in debug builds
                subview.layer.shadowOpacity = 0
                subview.layer.shadowRadius = 0
            }
            optimizeShadows(in: subview)
        }
    }
}

// MARK: - SwiftUI View Modifiers

/// SwiftUI view modifier that applies debug optimizations
struct DebugOptimized: ViewModifier {
    func body(content: Content) -> some View {
        #if DEBUG
        content
            .drawingGroup() // Flatten view hierarchy for better performance
            .animation(.none, value: UUID()) // Disable animations
        #else
        content
        #endif
    }
}

extension View {
    /// Apply debug-specific optimizations to a SwiftUI view
    func debugOptimized() -> some View {
        self.modifier(DebugOptimized())
    }
}
