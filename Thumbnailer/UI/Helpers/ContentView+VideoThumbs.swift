/*
 
 ContentView+Video.swift
 Thumbnailer
 
 - Enumerate video leaf folders and video files (MP4, MOV, M4V)
 - Process videos with simple progress tracking using ProgressTracker
 - Call `VideoContactSheetProcessor.process` for each video
 - Post completion notification and Dock badge
 - Summarize failures at the end
 - Enhanced with 2-phase progress to prevent beach balling
 - FIXED: Proper cancellation support throughout the task group processing
 
 George Babichev
 
 */

import Foundation
import SwiftUI
import UserNotifications

extension ContentView {

    // MARK: - Public entrypoint
    @MainActor
    /// Builds contact sheets for videos within each video leaf folder.
    /// - Shows a Dock badge + Notification on completion.
    /// - Adds a final "Failed videos" summary section with absolute paths.
    func makeVideoSheets() {
        // Ensure badge clears on foreground & clear any stale badge
        ensureBadgeAutoClearInstalled()
        clearAppBadge()

        // Require video leaf folders
        let targets = leafFolders.map(\.url)
        guard !targets.isEmpty else {
            appendLog("No video folders to process. Select a folder with video files.")
            return
        }

        // Determine where to place contact sheets
        let folderName = thumbnailFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !videoCreateInParent && folderName.isEmpty {
            appendLog("⚠️ Thumbnail folder name is blank — aborting to avoid overwriting originals. Set a name in Settings or enable 'Create in Parent'.")
            return
        }

        isProcessing = true
        logLines.removeAll()

        // Request permission for notifications (non-blocking)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }

        // Snapshot UI state
        let cols = videoSheetColumns
        let cellH = CGFloat(thumbnailSize)
        let cellW = cellH * 16.0 / 9.0
        let q = jpegQuality
        let runBegan = Date()
        
        // Capture format selection
        let selectedFormat = ThumbnailFormat(rawValue: thumbnailFormatRaw) ?? .jpeg
        let videoFormat: VideoSheetOutputFormat = selectedFormat == .heic ? .heic : .jpeg

        // Cancel previous run if any
        currentWork?.cancel()
        currentWork = Task(priority: .utility) {
            let progressTracker = createProgressTracker(total: targets.count)
            
            do {
                
                await MainActor.run {
                    let formatName = selectedFormat.rawValue
                    appendLog("🎬 Creating video contact sheets in \(formatName) format")
                }
                
                // --- Live reporting helpers (overall ETA + heartbeats) ---
                actor OverallMeter {
                    let start = Date()
                    private var processed = 0
                    private var known = 0
                    private var lastHeartbeat = Date()

                    func addKnown(_ n: Int) { known += n }
                    func incProcessed() { processed += 1 }

                    /// At most every ~10s after at least 5s, returns a log line; otherwise nil.
                    func heartbeatMessage() -> String? {
                        let elapsed = Date().timeIntervalSince(start)
                        guard elapsed > 5 else { return nil }
                        let denom = max(1, known)
                        let pct = (Double(processed) / Double(denom)) * 100.0
                        let rate = Double(processed) / max(elapsed, 1)
                        let remaining = max(0, denom - processed)
                        let etaSec = rate > 0 ? Int(Double(remaining) / rate) : 0
                        if Date().timeIntervalSince(lastHeartbeat) > 10 {
                            lastHeartbeat = Date()
                            return String(format: "⏱️ %d/%d videos (%.1f%%), ETA ~%dm %ds", processed, denom, pct, etaSec/60, etaSec%60)
                        }
                        return nil
                    }
                }
                let overallMeter = OverallMeter()
                // ---------------------------------------------------------
                
                var totalVideos = 0
                var totalSuccess = 0
                var totalFailures = 0
                var failedVideoPaths: [String] = []

                for folder in targets {
                    // FIXED: Check for cancellation at folder level
                    try Task.checkCancellation()
                    
                    await MainActor.run {
                        appendLog("🎬 Scanning for videos under: \(folder.path)")
                    }

                    // Determine output directory based on user preference
                    let outputDir: URL
                    if videoCreateInParent {
                        // Place contact sheets in the parent folder of the leaf
                        outputDir = folder.deletingLastPathComponent()
                        await MainActor.run {
                            appendLog("  📁 Contact sheets will be created in parent folder: \(outputDir.path)")
                        }
                    } else {
                        // Use thumbnail subfolder (existing behavior)
                        outputDir = folder.appendingPathComponent(folderName, isDirectory: true)
                        do {
                            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
                        } catch {
                            await MainActor.run {
                                appendLog("❌ Failed to create thumbnail folder: \(outputDir.path) — \(error.localizedDescription)")
                                progressTracker.increment()
                            }
                            continue
                        }
                    }

                    // Build work list - call helper methods on main actor
                    let work = await MainActor.run {
                        videos(in: folder, ignoringSubdirNamed: videoCreateInParent ? "" : folderName)
                            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                    }
                    await overallMeter.addKnown(work.count)
                    totalVideos += work.count
                    
                    if work.isEmpty {
                        await MainActor.run {
                            appendLog("  No video files found")
                            progressTracker.increment()
                        }
                        continue
                    }

                    // Get concurrency limit on main actor
                    let limit = await MainActor.run { defaultMaxConcurrent() }
                    var completedInFolder = 0
                    
                    // Sheet options
                    var opts = VideoSheetOptions()
                    opts.columns = cols
                    opts.cellSize = CGSize(width: cellW, height: cellH)
                    opts.spacing = 0
                    opts.background = CGColor(gray: 0.08, alpha: 1)

                    // Snapshot sendable values to avoid capturing in group
                    let taskOutputDir = outputDir
                    let taskOpts = opts
                    let taskQuality = q
                    let taskFormat = videoFormat

                    // Folder-level heartbeat: if no video finishes for a while, log a reassuring message.
                    var lastFolderProgressTick = Date()
                    var folderHeartbeatTask: Task<Void, Never>? = Task(priority: .background) {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(8))
                            if Date().timeIntervalSince(lastFolderProgressTick) > 8 {
                                await MainActor.run {
                                    appendLog("  ⏳ Still working in \(folder.lastPathComponent)… \(completedInFolder)/\(work.count) done")
                                }
                            }
                        }
                    }

                    // FIXED: Process in batches with proper cancellation checking
                    await withTaskGroup(of: VideoContactSheetResult?.self) { group in
                        var workIterator = work.makeIterator()
                        
                        // Start initial batch
                        for _ in 0..<min(limit, work.count) {
                            if let video = workIterator.next() {
                                group.addTask { @Sendable in
                                    // FIXED: Check for cancellation before processing each video
                                    guard !Task.isCancelled else { return nil }
                                    
                                    let result = await VideoContactSheetProcessor.process(
                                        videoURL: video,
                                        thumbsDir: taskOutputDir,
                                        options: taskOpts,
                                        jpegQuality: taskQuality,
                                        format: taskFormat
                                    )
                                    return result
                                }
                            }
                        }
                        
                        // Process results and start new tasks
                        for await optionalResult in group {
                            // FIXED: Check for cancellation in result processing loop
                            guard !Task.isCancelled else { break }
                            
                            // Handle nil result (cancelled task)
                            guard let result = optionalResult else { continue }
                            
                            completedInFolder += 1
                            lastFolderProgressTick = Date()
                            
                            // Log result
                            let rel = "/\(folder.lastPathComponent)/\(result.videoURL.lastPathComponent)"
                            if result.isSuccess {
                                await MainActor.run {
                                    if let outputURL = result.outputURL {
                                        appendLog("     ✅ - \(rel) → \(outputURL.lastPathComponent)")
                                    } else {
                                        appendLog("     ✅ - \(rel) contact sheet created")
                                    }
                                }
                                totalSuccess += 1
                            } else {
                                await MainActor.run {
                                    appendLog("     ❌ - \(rel) contact sheet failure")
                                }
                                failedVideoPaths.append(result.videoURL.path)
                                totalFailures += 1
                            }
                            
                            // Update progress with fractional completion for this folder
                            let folderProgress = Double(completedInFolder) / Double(work.count)
                            await MainActor.run {
                                progressTracker.updateWithFraction(folderProgress)
                            }
                            
                            await overallMeter.incProcessed()
                            if let msg = await overallMeter.heartbeatMessage() {
                                await MainActor.run { appendLog(msg) }
                            }
                            
                            // FIXED: Check for cancellation before starting next video
                            if !Task.isCancelled, let nextVideo = workIterator.next() {
                                group.addTask { @Sendable in
                                    // Check for cancellation before processing
                                    guard !Task.isCancelled else { return nil }
                                    
                                    let result = await VideoContactSheetProcessor.process(
                                        videoURL: nextVideo,
                                        thumbsDir: taskOutputDir,
                                        options: taskOpts,
                                        jpegQuality: taskQuality,
                                        format: taskFormat
                                    )
                                    return result
                                }
                            }
                        }
                    }
                    
                    // Stop the folder heartbeat when this folder is done.
                    folderHeartbeatTask?.cancel()
                    folderHeartbeatTask = nil

                    // Folder complete - move to next
                    await MainActor.run {
                        progressTracker.increment()
                    }

                    // FIXED: Final cancellation check before continuing to next folder
                    try Task.checkCancellation()
                }

                // FIXED: Check for cancellation before finalizing
                try Task.checkCancellation()

                // Finalize & notify (success case)
                let duration = Date().timeIntervalSince(runBegan)
                await MainActor.run {
                    appendLog("✅ Video contact sheets complete.")
                    let summary = "ℹ️ Processed: \(totalVideos) videos — ✅ \(totalSuccess)  ❌ \(totalFailures)"
                    appendLog(summary)

                    if totalFailures > 0 {
                        appendLog("---- Failed videos (\(totalFailures)) ----")
                        for path in failedVideoPaths.sorted() {
                            appendLog("❌ \(path)")
                        }
                    } else {
                        appendLog("No failures 🎉")
                    }

                    // Send success notification if app is not active
                    if !NSApp.isActive {
                        let center = UNUserNotificationCenter.current()
                        let content = UNMutableNotificationContent()
                        content.title = "Video sheets complete"
                        content.body = String(format: "%@ (%.0fs)", summary, duration)
                        content.sound = .default
                        content.badge = 1
                        
                        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
                        NSApplication.shared.dockTile.badgeLabel = "✓"
                    }
                }
                
            } catch is CancellationError {
                // Handle cancellation
                let duration = Date().timeIntervalSince(runBegan)
                await MainActor.run {
                    appendLog("ℹ️ Video sheets cancelled.")
                    
                    // Send cancellation notification if app is not active
                    if !NSApp.isActive {
                        let center = UNUserNotificationCenter.current()
                        let content = UNMutableNotificationContent()
                        content.title = "Video sheets cancelled"
                        content.body = String(format: "Run cancelled after %.0fs", duration)
                        content.sound = .default
                        content.badge = 1
                        
                        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
                        NSApplication.shared.dockTile.badgeLabel = "!"
                    }
                }
            } catch {
                // Handle other errors
                await MainActor.run {
                    appendLog("❌ Video sheets failed: \(error.localizedDescription)")
                }
            }
            
            // FIXED: Always clean up UI state
            await MainActor.run {
                isProcessing = false
                progressTracker.finish()
            }
        }
    }

    @MainActor
    /// Simple concurrency heuristic based on system resources
    private func defaultMaxConcurrent() -> Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let memGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        let base = min(max(1, cores - 2), 6)  // leave 1-2 cores, cap at 6
        if memGB >= 32 { return base }
        if memGB >= 16 { return min(base, 4) }
        return min(base, 2)
    }
    
    /// Enumerate video files under `folder` (recursive), skipping any subdir named `ignore`.
    /// Supports all video formats defined in AppConstants.videoExts (mp4, mov, m4v)
    private func videos(in folder: URL, ignoringSubdirNamed ignore: String) -> [URL] {
        guard let e = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        
        var xs: [URL] = []
        while let u = e.nextObject() as? URL {
            let rv = try? u.resourceValues(forKeys: [.isDirectoryKey, .nameKey])
            let isDir = rv?.isDirectory ?? false
            let name = rv?.name ?? u.lastPathComponent
            if isDir {
                if name.caseInsensitiveCompare(ignore) == .orderedSame {
                    e.skipDescendants()
                }
                continue
            }
            // Fixed: Use AppConstants.videoExts instead of hardcoded "mp4"
            if AppConstants.allVideoExts.contains(u.pathExtension.lowercased()) {
                xs.append(u)
            }
        }
        return xs
    }
}
