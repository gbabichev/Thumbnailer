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
    private let updateETA: (TimeInterval?) -> Void
    let total: Int
    private var completed: Int = 0
    private let startedAt = Date()
    
    /// Initialize progress tracker
    /// - Parameters:
    ///   - total: Total number of items to process
    ///   - updateProgress: Callback to update UI progress (0.0-1.0, or nil to clear)
    ///   - updateETA: Callback to update ETA in seconds, or nil to clear/hide
    init(
        total: Int,
        updateProgress: @escaping (Double?) -> Void,
        updateETA: @escaping (TimeInterval?) -> Void
    ) {
        self.total = max(1, total) // Avoid division by zero
        self.updateProgress = updateProgress
        self.updateETA = updateETA
        
        // Start at 0%
        updateProgress(0)
        updateETA(nil)
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
        updateETA(estimateETA())
    }
    
    /// Mark as complete and clear progress UI
    func finish() {
        updateProgress(nil)
        updateETA(nil)
    }

    private func estimateETA(effectiveCompleted: Double? = nil) -> TimeInterval? {
        let done = effectiveCompleted ?? Double(completed)
        guard done > 0, done < Double(total) else { return nil }

        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 0 else { return nil }

        let rate = done / elapsed
        guard rate > 0 else { return nil }

        let remaining = Double(total) - done
        return remaining / rate
    }
    
}

// MARK: - ContentView Extension
extension ContentView {
    /// Create a progress tracker for the current operation
    /// - Parameter total: Total number of items to process
    /// - Returns: Progress tracker that updates this view's progress property
    func createProgressTracker(total: Int) -> ProgressTracker {
        ProgressTracker(
            total: total,
            updateProgress: { progress in
                // Since we're already on MainActor, update immediately without Task wrapper
                self.progress = progress
            },
            updateETA: { eta in
                self.progressETASeconds = eta
            }
        )
    }
}
