/*
 
 ProgressTracker.swift
 Thumbnailer
 
 Simple progress tracking helper for operations with known item counts.
 Provides consistent progress reporting across all app operations.
 
 George Babichev
 
 */

import Foundation

/// Simple progress tracking helper for ContentView operations
@MainActor
class ProgressTracker {
    private let updateProgress: (Double?) -> Void
    let total: Int
    private var completed: Int = 0
    
    /// Initialize progress tracker
    /// - Parameters:
    ///   - total: Total number of items to process
    ///   - updateProgress: Callback to update UI progress (0.0-1.0, or nil to clear)
    init(total: Int, updateProgress: @escaping (Double?) -> Void) {
        self.total = max(1, total) // Avoid division by zero
        self.updateProgress = updateProgress
        
        // Start at 0%
        updateProgress(0)
    }
    
    /// Mark one item as completed
    func increment() {
        completed += 1
        updateTo(completed)
    }
    
    /// Set progress to a specific completed count
    /// - Parameter completedCount: Number of items completed (will be clamped to total)
    func updateTo(_ completedCount: Int) {
        completed = min(completedCount, total) // Don't exceed total
        let progress = Double(completed) / Double(total)
        updateProgress(progress)
    }
    
    /// Set fractional progress for current item (useful for nested operations)
    /// - Parameter fraction: Progress within current item (0.0-1.0)
    ///
    /// Example: Processing folder 3 of 10, and 40% done with that folder:
    /// ```
    /// progressTracker.updateWithFraction(0.4)
    /// // Shows: (2 + 0.4) / 10 = 24% total progress
    /// ```
    func updateWithFraction(_ fraction: Double) {
        let clampedFraction = max(0, min(1, fraction))
        let progress = (Double(completed) + clampedFraction) / Double(total)
        updateProgress(progress)
    }
    
    
    /// Mark as complete and clear progress UI
    func finish() {
        updateProgress(nil)
    }
    
}

// MARK: - ContentView Extension
extension ContentView {
    /// Create a progress tracker for the current operation
    /// - Parameter total: Total number of items to process
    /// - Returns: Progress tracker that updates this view's progress property
    func createProgressTracker(total: Int) -> ProgressTracker {
        ProgressTracker(total: total) { progress in
            // Since we're already on MainActor, update immediately without Task wrapper
            self.progress = progress
        }
    }
}
