//
//  ContentView+VideoTools.swift
//  Thumbnailer
//
//  Created by George Babichev on 8/24/25.
//

import SwiftUI
import AVFoundation
import UserNotifications

extension ContentView {
    
    // MARK: - Video Tools
    
    @MainActor
    func scanNonMP4VideosMenuAction() {
        let leaves = leafFolders.map(\.url)
        guard !leaves.isEmpty else {
            appendLog("No video leaf folders to scan. Select a folder first.")
            return
        }
        
        // Only allow this in video mode or when video leafs are present
        guard mode == .videos else {
            appendLog("No video files detected. Switch to video mode or select folders with videos.")
            return
        }
        
        appendLog("🎬 Scanning for non-MP4 video files...")
        
        IdentifyNonMP4Videos.runScan(
            leafs: leaves,
            ignoreFolderNames: [thumbnailFolderName],
            includeHidden: false,
            appendLog: { appendLog($0) }
        )
    }
    
    @MainActor
    func identifyShortVideosMenuAction() {
        let leaves = leafFolders.map(\.url)
        guard !leaves.isEmpty else {
            appendLog("No video leaf folders to scan. Select a folder first.")
            return
        }
        
        // Only allow this in video mode or when video leafs are present
        guard mode == .videos else {
            appendLog("No video files detected. Switch to video mode or select folders with videos.")
            return
        }
        
        let durationMinutes = shortVideoDurationSeconds / 60.0
        appendLog("🎬 Scanning for short videos (< \(String(format: "%.1f", durationMinutes)) min)…")
        
        IdentifyShortVideos.runScan(
            leafs: leaves,
            maxDurationSeconds: shortVideoDurationSeconds,
            ignoreFolderNames: [thumbnailFolderName],
            includeHidden: false,
            appendLog: { appendLog($0) }
        )
    }
    
    // ---
    
    /// Trims the first N seconds from all videos in video leaf folders using FFmpeg
    @MainActor
    /// Trims the first N seconds from all videos in video leaf folders using FFmpeg
    func trimVideoFirstSeconds() {
        let targets = leafFolders.map(\.url)
        guard !targets.isEmpty else {
            appendLog("No video folders to process. Select a folder with video files.")
            return
        }
        
        // Safety check for thumbnail folder name
        let folderName = thumbnailFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if folderName.isEmpty {
            appendLog("⚠️ Thumbnail folder name is blank — set a name in Settings to avoid processing thumbnail files.")
            return
        }
        
        // Ensure badge clears on foreground & clear any stale badge
        ensureBadgeAutoClearInstalled()
        clearAppBadge()
        
        isProcessing = true
        logLines.removeAll()
        appendLog("✂️ Starting trimming with FFmpeg (removing first \(videoSecondsToTrim) seconds)...")
        
        currentWork?.cancel()
        currentWork = Task(priority: .userInitiated) {
            let runBegan = Date()
            
            // First, collect all videos from all folders
            var allVideos: [URL] = []
            for folder in targets {
                let videos = await MainActor.run {
                    findVideos(in: folder, ignoringSubdirNamed: folderName)
                }
                allVideos.append(contentsOf: videos)
            }
            
            let progressTracker = createProgressTracker(total: allVideos.count)
            
            await MainActor.run {
                appendLog("🎬 Found \(allVideos.count) video(s) across \(targets.count) folder(s)")
            }
            
            // Check FFmpeg availability first
            let ffmpegInfo = await FFmpegVideoTrimmer.findFFmpegWithInfo(customPath: nil)
            
            if ffmpegInfo == nil {
                await MainActor.run {
                    appendLog("❌ FFmpeg not found! Please install FFmpeg or add it to your app bundle.")
                    isProcessing = false
                    progressTracker.finish()
                }
                return
            } else {
                await MainActor.run {
                    appendLog("🔧 \(ffmpegInfo!.displayDescription)")
                }
            }
            
            var totalSuccess = 0
            var totalFailures = 0
            var totalSkipped = 0
            var totalUnsupported = 0
            var failedVideoPaths: [String] = []
            var totalSizeSaved: Int64 = 0
            var currentFolder = ""
            
            // Process each video individually with progress updates
            for (index, video) in allVideos.enumerated() {
                if Task.isCancelled { break }
                
                let folderName = video.deletingLastPathComponent().lastPathComponent
                if folderName != currentFolder {
                    currentFolder = folderName
                    await MainActor.run {
                        appendLog("📁 \(folderName):")
                    }
                }
                
                let relativePath = video.lastPathComponent
                let fileExt = video.pathExtension.lowercased()
                
                // Check if format is supported
                if !AppConstants.videoExts.contains(fileExt) {
                    await MainActor.run {
                        appendLog("    ⚠️ Skipped: \(relativePath) - Unsupported format (.\(fileExt))")
                        progressTracker.updateTo(index + 1)
                    }
                    totalUnsupported += 1
                    totalSkipped += 1
                    continue
                }
                
                // Check video duration
                let duration = await getVideoDuration(video)
                let minimumDurationSeconds = Double(videoSecondsToTrim) + 5.0
                
                if duration < minimumDurationSeconds {
                    let skipReason = "Video too short (\(String(format: "%.1f", duration))s < \(String(format: "%.1f", minimumDurationSeconds))s required)"
                    await MainActor.run {
                        appendLog("    ⚠️ Skipped: \(relativePath) - \(skipReason)")
                        progressTracker.updateTo(index + 1)
                    }
                    totalSkipped += 1
                    continue
                }
                
                // Process this video with FFmpeg
                var options = FFmpegTrimOptions()
                options.trimStartSeconds = Double(videoSecondsToTrim)
                
                let result = await trimVideoWithFFmpeg(video, ffmpegPath: ffmpegInfo!.path, options: options)
                
                // Log result immediately
                if result.isSuccess {
                    let timeSaved = String(format: "%.1fs", result.processingTime)
                    let sizeDiff = result.originalSize - result.newSize
                    
                    if sizeDiff > 0 {
                        let mbSaved = Double(sizeDiff) / 1_048_576.0
                        totalSizeSaved += sizeDiff
                        await MainActor.run {
                            appendLog("    ✅ \(relativePath) → intro trimmed (\(String(format: "%.1f", mbSaved))MB saved, \(timeSaved))")
                        }
                    } else {
                        await MainActor.run {
                            appendLog("    ✅ \(relativePath) → intro trimmed (\(timeSaved))")
                        }
                    }
                    totalSuccess += 1
                } else {
                    await MainActor.run {
                        appendLog("    ❌ Failed: \(relativePath)")
                    }
                    failedVideoPaths.append(result.originalURL.path)
                    totalFailures += 1
                }
                
                // Update progress after each video
                await MainActor.run {
                    progressTracker.updateTo(index + 1)
                }
                
                // Log batch progress every 10 videos
                if (index + 1) % 10 == 0 {
                    await MainActor.run {
                        appendLog("📊 Progress: \(index + 1)/\(allVideos.count) videos processed")
                    }
                }
            }
            
            // Final summary
            let totalVideos = allVideos.count
            let duration = Date().timeIntervalSince(runBegan)
            let summary = "ℹ️ Processed: \(totalVideos) videos — ✅ \(totalSuccess)  ⚠️ \(totalSkipped)  ❌ \(totalFailures)"
            
            await MainActor.run {
                isProcessing = false
                progressTracker.finish()
                
                if Task.isCancelled {
                    appendLog("ℹ️ Trimming cancelled.")
                } else {
                    appendLog("✅ Trimming complete!")
                    appendLog(summary)
                    
                    if totalUnsupported > 0 {
                        appendLog("⚠️ Unsupported formats skipped: \(totalUnsupported) (supported: \(AppConstants.supportedVideoFormatsString))")
                    }
                    
                    if totalSizeSaved > 0 {
                        let mbSaved = Double(totalSizeSaved) / 1_048_576.0
                        appendLog("💾 Total space saved: \(String(format: "%.1f", mbSaved))MB")
                    }
                    
                    if totalFailures > 0 {
                        appendLog("---- Failed videos (\(totalFailures)) ----")
                        for path in failedVideoPaths.sorted() {
                            appendLog("❌ \(path)")
                        }
                    } else {
                        appendLog("No failures 🎉")
                    }
                }
            }
            
            // Send notification if app isn't in focus
            if !NSApp.isActive {
                let center = UNUserNotificationCenter.current()
                let content = UNMutableNotificationContent()
                
                if Task.isCancelled {
                    content.title = "Video trimming cancelled"
                    content.body = String(format: "Processing cancelled after %.0fs", duration)
                } else {
                    content.title = "Video trimming complete"
                    content.body = String(format: "%@ (%.0fs)", summary, duration)
                }
                
                content.sound = .default
                content.badge = 1
                
                try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
                await MainActor.run {
                    NSApplication.shared.dockTile.badgeLabel = Task.isCancelled ? "!" : "✓"
                }
            }
        }
    }

    /// Trims the last N seconds from all videos in video leaf folders using FFmpeg
    @MainActor
    /// Trims the last N seconds from all videos in video leaf folders using FFmpeg
    func trimVideoLastSeconds() {
        let targets = leafFolders.map(\.url)
        guard !targets.isEmpty else {
            appendLog("No video folders to process. Select a folder with video files.")
            return
        }
        
        // Safety check for thumbnail folder name
        let folderName = thumbnailFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if folderName.isEmpty {
            appendLog("⚠️ Thumbnail folder name is blank — set a name in Settings to avoid processing thumbnail files.")
            return
        }
        
        // Ensure badge clears on foreground & clear any stale badge
        ensureBadgeAutoClearInstalled()
        clearAppBadge()
        
        isProcessing = true
        logLines.removeAll()
        appendLog("✂️ Starting trimming with FFmpeg (removing last \(videoSecondsToTrim) seconds)...")
        
        currentWork?.cancel()
        currentWork = Task(priority: .userInitiated) {
            let runBegan = Date()
            
            // First, collect all videos from all folders
            var allVideos: [URL] = []
            for folder in targets {
                let videos = await MainActor.run {
                    findVideos(in: folder, ignoringSubdirNamed: folderName)
                }
                allVideos.append(contentsOf: videos)
            }
            
            let progressTracker = createProgressTracker(total: allVideos.count)
            
            await MainActor.run {
                appendLog("🎬 Found \(allVideos.count) video(s) across \(targets.count) folder(s)")
            }
            
            // Check FFmpeg availability first
            let ffmpegInfo = await FFmpegVideoTrimmer.findFFmpegWithInfo(customPath: nil)
            
            if ffmpegInfo == nil {
                await MainActor.run {
                    appendLog("❌ FFmpeg not found! Please install FFmpeg or add it to your app bundle.")
                    isProcessing = false
                    progressTracker.finish()
                }
                return
            } else {
                await MainActor.run {
                    appendLog("🔧 \(ffmpegInfo!.displayDescription)")
                }
            }
            
            var totalSuccess = 0
            var totalFailures = 0
            var totalSkipped = 0
            var totalUnsupported = 0
            var failedVideoPaths: [String] = []
            var totalSizeSaved: Int64 = 0
            var currentFolder = ""
            
            // Process each video individually with progress updates
            for (index, video) in allVideos.enumerated() {
                if Task.isCancelled { break }
                
                let folderName = video.deletingLastPathComponent().lastPathComponent
                if folderName != currentFolder {
                    currentFolder = folderName
                    await MainActor.run {
                        appendLog("📁 \(folderName):")
                    }
                }
                
                let relativePath = video.lastPathComponent
                let fileExt = video.pathExtension.lowercased()
                
                // Check if format is supported
                if !AppConstants.videoExts.contains(fileExt) {
                    await MainActor.run {
                        appendLog("    ⚠️ Skipped: \(relativePath) - Unsupported format (.\(fileExt))")
                        progressTracker.updateTo(index + 1)
                    }
                    totalUnsupported += 1
                    totalSkipped += 1
                    continue
                }
                
                // Check video duration
                let duration = await getVideoDuration(video)
                let minimumDurationSeconds = Double(videoSecondsToTrim) + 5.0
                
                if duration < minimumDurationSeconds {
                    let skipReason = "Video too short (\(String(format: "%.1f", duration))s < \(String(format: "%.1f", minimumDurationSeconds))s required)"
                    await MainActor.run {
                        appendLog("    ⚠️ Skipped: \(relativePath) - \(skipReason)")
                        progressTracker.updateTo(index + 1)
                    }
                    totalSkipped += 1
                    continue
                }
                
                // Process this video with FFmpeg (END TRIMMING)
                var options = FFmpegTrimOptions()
                options.trimEndSeconds = Double(videoSecondsToTrim)  // Changed from trimStartSeconds
                
                let result = await trimVideoWithFFmpeg(video, ffmpegPath: ffmpegInfo!.path, options: options)
                
                // Log result immediately
                if result.isSuccess {
                    let timeSaved = String(format: "%.1fs", result.processingTime)
                    let sizeDiff = result.originalSize - result.newSize
                    
                    if sizeDiff > 0 {
                        let mbSaved = Double(sizeDiff) / 1_048_576.0
                        totalSizeSaved += sizeDiff
                        await MainActor.run {
                            appendLog("    ✅ \(relativePath) → outro trimmed (\(String(format: "%.1f", mbSaved))MB saved, \(timeSaved))")
                        }
                    } else {
                        await MainActor.run {
                            appendLog("    ✅ \(relativePath) → outro trimmed (\(timeSaved))")
                        }
                    }
                    totalSuccess += 1
                } else {
                    await MainActor.run {
                        appendLog("    ❌ Failed: \(relativePath)")
                    }
                    failedVideoPaths.append(result.originalURL.path)
                    totalFailures += 1
                }
                
                // Update progress after each video
                await MainActor.run {
                    progressTracker.updateTo(index + 1)
                }
                
                // Log batch progress every 10 videos
                if (index + 1) % 10 == 0 {
                    await MainActor.run {
                        appendLog("📊 Progress: \(index + 1)/\(allVideos.count) videos processed")
                    }
                }
            }
            
            // Final summary
            let totalVideos = allVideos.count
            let duration = Date().timeIntervalSince(runBegan)
            let summary = "ℹ️ Processed: \(totalVideos) videos — ✅ \(totalSuccess)  ⚠️ \(totalSkipped)  ❌ \(totalFailures)"
            
            await MainActor.run {
                isProcessing = false
                progressTracker.finish()
                
                if Task.isCancelled {
                    appendLog("ℹ️ Trimming cancelled.")
                } else {
                    appendLog("✅ Trimming complete!")
                    appendLog(summary)
                    
                    if totalUnsupported > 0 {
                        appendLog("⚠️ Unsupported formats skipped: \(totalUnsupported) (supported: \(AppConstants.supportedVideoFormatsString))")
                    }
                    
                    if totalSizeSaved > 0 {
                        let mbSaved = Double(totalSizeSaved) / 1_048_576.0
                        appendLog("💾 Total space saved: \(String(format: "%.1f", mbSaved))MB")
                    }
                    
                    if totalFailures > 0 {
                        appendLog("---- Failed videos (\(totalFailures)) ----")
                        for path in failedVideoPaths.sorted() {
                            appendLog("❌ \(path)")
                        }
                    } else {
                        appendLog("No failures 🎉")
                    }
                }
            }
            
            // Send notification if app isn't in focus
            if !NSApp.isActive {
                let center = UNUserNotificationCenter.current()
                let content = UNMutableNotificationContent()
                
                if Task.isCancelled {
                    content.title = "Video trimming cancelled"
                    content.body = String(format: "Processing cancelled after %.0fs", duration)
                } else {
                    content.title = "Video trimming complete"
                    content.body = String(format: "%@ (%.0fs)", summary, duration)
                }
                
                content.sound = .default
                content.badge = 1
                
                try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
                await MainActor.run {
                    NSApplication.shared.dockTile.badgeLabel = Task.isCancelled ? "!" : "✓"
                }
            }
        }
    }
    
    // ---
    
    @MainActor
    func moveVideosToParentMenuAction() {
        let leaves = leafFolders.map(\.url)
        guard !leaves.isEmpty else {
            appendLog("No video leaf folders loaded. Select roots first.")
            return
        }
        
        guard mode == .videos else {
            appendLog("This tool is only available in video mode.")
            return
        }
        
        isProcessing = true
        logLines.removeAll()
        appendLog("📁 Moving videos from leaf folders to their parents...")
        
        Task(priority: .userInitiated) {
            let result = VideoParentMover.moveVideosToParent(
                in: leaves,
                thumbFolderName: thumbnailFolderName,
                removeEmptyFolders: false, // Default to false for safety
                log: { message in
                    Task { @MainActor in appendLog(message) }
                }
            )
            
            await MainActor.run {
                appendLog("")
                appendLog("✅ Video move operation complete!")
                
                let summary = "📋 Processed: \(result.scannedLeafFolders) folders, \(result.totalVideoFiles) videos"
                appendLog(summary)
                
                if result.successfullyMoved > 0 {
                    appendLog("💾  Successfully moved: \(result.successfullyMoved) videos")
                }
                
                if result.skippedDuplicates > 0 {
                    appendLog("⚠️ Skipped (duplicates): \(result.skippedDuplicates) videos")
                }
                
                if result.failedMoves > 0 {
                    appendLog("❌ Failed moves: \(result.failedMoves)")
                    appendLog("---- Failed video moves (\(result.failedMoves)) ----")
                    for path in result.failedPaths.sorted() {
                        appendLog("❌ \(path)")
                    }
                }
                
                if result.emptyFoldersRemoved > 0 {
                    appendLog("🗑️ Empty folders removed: \(result.emptyFoldersRemoved)")
                }
                
                if result.successfullyMoved == 0 && result.skippedDuplicates == 0 {
                    appendLog("ℹ️ No videos were moved (no eligible files found)")
                } else if result.failedMoves == 0 {
                    appendLog("No failures 🎉")
                }
                
                isProcessing = false
            }
        }
    }
    
    // ---
    
    @MainActor
    func deleteContactlessVideoFiles() {
        let leaves = leafFolders.map(\.url)
        guard !leaves.isEmpty else {
            appendLog("No video leaf folders loaded. Select roots first.")
            return
        }

        guard mode == .videos else {
            appendLog("This tool is only available in video mode.")
            return
        }

        appendLog("🔍 Scanning for contactless video files…")

        Task(priority: .userInitiated) {
            // First, just find the contactless videos without deleting
            let contactlessVideos = ContactlessVideoFileRemover.findContactlessVideoFiles(
                in: leaves,
                thumbFolderName: thumbnailFolderName,
                log: { message in
                    Task { @MainActor in appendLog(message) }
                }
            )

            await MainActor.run {
                if contactlessVideos.isEmpty {
                    appendLog("✅ All video files have contact sheets. Nothing to delete.")
                    return
                }

                appendLog("")
                appendLog("⚠️ Found \(contactlessVideos.count) video file(s) without contact sheets:")
                for video in contactlessVideos {
                    appendLog("    📹 \(video.path)")
                }
                appendLog("")

                // Stage A: stash victims & ask user
                pendingContactlessVictims = contactlessVideos
                showConfirmDeleteContactless = true
            }
        }
    }

    // MARK: - VR Contact Sheets

    @MainActor
    /// Builds VR contact sheets for videos within each video leaf folder.
    /// Extracts frames and splits them vertically to show VR side-by-side content.
    /// - Shows a Dock badge + Notification on completion.
    /// - Adds a final "Failed videos" summary section with absolute paths.
    func makeVRVideoSheets() {
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
                    appendLog("🥽 Creating VR video contact sheets in \(formatName) format (with vertical split)")
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
                    // Check for cancellation at folder level
                    try Task.checkCancellation()

                    await MainActor.run {
                        appendLog("🎬 Scanning for VR videos under: \(folder.path)")
                    }

                    // Determine output directory based on user preference
                    let outputDir: URL
                    if videoCreateInParent {
                        // Place contact sheets in the parent folder of the leaf
                        outputDir = folder.deletingLastPathComponent()
                        await MainActor.run {
                            appendLog("  📁 VR contact sheets will be created in parent folder: \(outputDir.path)")
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
                        findVideos(in: folder, ignoringSubdirNamed: videoCreateInParent ? "" : folderName)
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
                                    appendLog("  ⏳ Still working on VR sheets in \(folder.lastPathComponent)… \(completedInFolder)/\(work.count) done")
                                }
                            }
                        }
                    }

                    // Process in batches with proper cancellation checking
                    await withTaskGroup(of: VideoContactSheetResult?.self) { group in
                        var workIterator = work.makeIterator()

                        // Start initial batch
                        for _ in 0..<min(limit, work.count) {
                            if let video = workIterator.next() {
                                group.addTask { @Sendable in
                                    // Check for cancellation before processing each video
                                    guard !Task.isCancelled else { return nil }

                                    let result = await VRVideoContactSheetProcessor.process(
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
                            // Check for cancellation in result processing loop
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
                                        appendLog("     ✅ - \(rel) VR contact sheet created")
                                    }
                                }
                                totalSuccess += 1
                            } else {
                                await MainActor.run {
                                    appendLog("     ❌ - \(rel) VR contact sheet failure")
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

                            // Check for cancellation before starting next video
                            if !Task.isCancelled, let nextVideo = workIterator.next() {
                                group.addTask { @Sendable in
                                    // Check for cancellation before processing
                                    guard !Task.isCancelled else { return nil }

                                    let result = await VRVideoContactSheetProcessor.process(
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

                    // Final cancellation check before continuing to next folder
                    try Task.checkCancellation()
                }

                // Check for cancellation before finalizing
                try Task.checkCancellation()

                // Finalize & notify (success case)
                let duration = Date().timeIntervalSince(runBegan)
                await MainActor.run {
                    appendLog("✅ VR video contact sheets complete.")
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
                        content.title = "VR video sheets complete"
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
                    appendLog("ℹ️ VR video sheets cancelled.")

                    // Send cancellation notification if app is not active
                    if !NSApp.isActive {
                        let center = UNUserNotificationCenter.current()
                        let content = UNMutableNotificationContent()
                        content.title = "VR video sheets cancelled"
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
                    appendLog("❌ VR video sheets failed: \(error.localizedDescription)")
                }
            }

            // Always clean up UI state
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
    func findVideos(in folder: URL, ignoringSubdirNamed ignore: String) -> [URL] {
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
            if AppConstants.allVideoExts.contains(u.pathExtension.lowercased()) {
                xs.append(u)
            }
        }
        return xs
    }

}
