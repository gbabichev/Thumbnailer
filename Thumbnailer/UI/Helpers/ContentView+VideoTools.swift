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
    
    
}
