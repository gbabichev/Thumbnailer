/*
 
 ContentView+Photo.swift
 Thumbnailer
 
 Photo Actions - SMB Performance Optimized
 
 Increased SMB performance by writing locally first and moving content with an atomic copy.
 
 */

import SwiftUI
import Foundation
import UserNotifications


enum ThumbnailOutputFormat {
    case jpeg
    case heic
    
    nonisolated var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .heic: return "heic"
        }
    }
}

extension ContentView {
    // MARK: - Photo Actions

    @MainActor
    func startPhotoThumbnailProcessing() {
        guard !isProcessing else { return }
        
        // Ensure badge clears on foreground & clear any stale badge
        ensureBadgeAutoClearInstalled()
        clearAppBadge()
        
        // Request permission for notifications (non-blocking)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
        
        isProcessing = true
        logLines.removeAll()

        let targets = leafFolders.map(\.url)
        let size = thumbnailSize
        let folder = thumbnailFolderName
        let quality = jpegQuality
        let selectedFormat = ThumbnailFormat(rawValue: thumbnailFormatRaw) ?? .jpeg
        let runBegan = Date()
        
        // Convert UI format to PhotoThumbnailer format
        let outputFormat: ThumbnailOutputFormat = selectedFormat == .heic ? .heic : .jpeg

        currentWork?.cancel()
        currentWork = Task(priority: .utility) {
            var totalImages = 0
            var processedImages = 0
            
            // First pass: count total images for accurate progress
            for leaf in targets {
                let imageCount = await countImagesInFolder(leaf, thumbFolderName: folder)
                totalImages += imageCount
            }
            
            let progressTracker = createProgressTracker(total: totalImages)
            await MainActor.run {
                let formatName = selectedFormat.rawValue
                appendLog("🖼 Processing \(totalImages) images across \(targets.count) folders as \(formatName)")
            }

            for (folderIndex, leaf) in targets.enumerated() {
                do {
                    try Task.checkCancellation()
                    
                    await MainActor.run {
                        appendLog("📁 Folder \(folderIndex + 1)/\(targets.count): \(leaf.lastPathComponent)")
                    }

                    // Process this folder with per-image progress reporting
                    let result = try await processLeafFolderWithProgress(
                        leaf: leaf,
                        height: size,
                        thumbFolderName: folder,
                        quality: quality,
                        format: outputFormat,
                        progressCallback: { @Sendable imageProcessed in
                            Task { @MainActor in
                                processedImages += 1
                                progressTracker.updateTo(processedImages)
                                
                                // Log every 10th image or significant milestones
                                if imageProcessed % 10 == 0 || processedImages % 50 == 0 {
                                    appendLog("  📷 Processed \(processedImages)/\(totalImages) images")
                                }
                            }
                        }
                    )

                    await MainActor.run {
                        appendLog("  ✅ Created \(result) thumbnails")
                    }
                    
                } catch is CancellationError {
                    break
                } catch {
                    await MainActor.run {
                        appendLog("  ❌ \(error.localizedDescription)")
                    }
                }
            }

            // Finalize & notify
            let duration = Date().timeIntervalSince(runBegan)
            await MainActor.run {
                isProcessing = false
                progressTracker.finish()

                let center = UNUserNotificationCenter.current()
                let content = UNMutableNotificationContent()
                
                if Task.isCancelled {
                    appendLog("ℹ️ Processing cancelled.")
                    content.title = "Photo thumbnails cancelled"
                    content.body = String(format: "Processing cancelled after %.0fs", duration)
                } else {
                    appendLog("✅ Processing complete.")
                    let summary = "ℹ️ Processed: \(processedImages) images across \(targets.count) folders"
                    appendLog(summary)

                    content.title = "Photo thumbnails complete"
                    content.body = String(format: "%@ (%.0fs)", summary, duration)
                }
                
                content.sound = .default
                content.badge = 1

                if !NSApp.isActive {
                    center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
                    NSApplication.shared.dockTile.badgeLabel = Task.isCancelled ? "!" : "✓"
                }
            }
        }
    }

    @MainActor
    func makePhotoSheets() {
        if mode == .videos { makeVideoSheets(); return }
        guard mode == .photos, !isProcessing else { return }

        // Ensure badge clears on foreground & clear any stale badge
        ensureBadgeAutoClearInstalled()
        clearAppBadge()
        
        // Request permission for notifications (non-blocking)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }

        isProcessing = true
        logLines.removeAll()

        let targets = leafFolders.map(\.url)
        let cellSide = CGFloat(thumbnailSize)
        let cellSize = CGSize(width: cellSide, height: cellSide)
        let fitMode = (SheetFitMode(rawValue: photoSheetFitModeRaw) ?? .pad).composerMode
        let columns = photoSheetColumns
        let q = jpegQuality
        let runBegan = Date()

        currentWork?.cancel()
        currentWork = Task(priority: .utility) {
            var totalImages = 0
            var processedImages = 0
            var totalSheets = 0
            var successfulSheets = 0
            
            // Count total images for progress
            for leaf in targets {
                let imageCount = await countImagesInFolder(leaf, thumbFolderName: "temp")
                totalImages += imageCount
            }
            
            let progressTracker = createProgressTracker(total: totalImages + targets.count) // +targets for composition steps
            await MainActor.run {
                appendLog("🖼 Creating contact sheets for \(totalImages) images across \(targets.count) folders")
            }

            // Bounded concurrency across FOLDERS (in addition to per-image concurrency inside each folder)
            let cpuCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
            let maxFolderConcurrent = max(1, cpuCount / 3) // scale with cores, leave headroom for per-image tasks & memory

            // Helper to process a single folder (creates temp thumbs, composes sheet, cleans up)
            @Sendable func processFolder(index: Int, leaf: URL) async {
                do {
                    if Task.isCancelled { return }

                    await MainActor.run {
                        appendLog("📁 Sheet \(index + 1)/\(targets.count): \(leaf.lastPathComponent)")
                    }

                    let tempName = ".zz_tmp_sheet_\(UUID().uuidString.prefix(8))"
                    let dir = leaf.appendingPathComponent(tempName, isDirectory: true)

                    // Step 1: Create temp directory
                    try await MainActor.run {
                        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    }

                    // Step 2: Process thumbnails with progress (always JPEG for temp thumbs)
                    _ = try await processLeafFolderWithProgress(
                        leaf: leaf,
                        height: Int(cellSide),
                        thumbFolderName: tempName,
                        quality: q,
                        format: .jpeg,
                        progressCallback: { @Sendable _ in
                            Task { @MainActor in
                                processedImages += 1
                                progressTracker.updateTo(processedImages)
                                if processedImages % 10 == 0 {
                                    appendLog("    📷 Processed \(processedImages)/\(totalImages) images")
                                }
                            }
                        }
                    )

                    // Step 3: Compose and write sheet (off main thread)
                    await MainActor.run { appendLog("  🎨 Composing contact sheet...") }

                    // Capture the format selection on the main actor before heavy work
                    let selectedFormat = await MainActor.run { ThumbnailFormat(rawValue: thumbnailFormatRaw) ?? .jpeg }
                    let sheetFormat: SheetOutputFormat = (selectedFormat == .heic) ? .heic : .jpeg

                    let outputPath = try await Task.detached(priority: .userInitiated) { () -> URL in
                        let thumbs = PhotoSheetComposer.loadDownsampledCGImages(in: dir, fitting: cellSize, scale: 1.0)
                        let baseURL = leaf.deletingLastPathComponent()
                            .appendingPathComponent(leaf.lastPathComponent)
                            .appendingPathExtension("jpg") // Will be adjusted by composeAndWriteSheet
                        let finalURL = try await PhotoSheetComposer.composeAndWriteSheet(
                            thumbnails: thumbs,
                            columns: columns,
                            cellSize: cellSize,
                            background: NSColor.black.cgColor,
                            contentMode: fitMode,
                            to: baseURL,
                            quality: q,
                            format: sheetFormat
                        )
                        return finalURL
                    }.value

                    // Clean up temp directory
                    if FileManager.default.fileExists(atPath: dir.path) {
                        try? FileManager.default.removeItem(at: dir)
                    }

                    await MainActor.run {
                        appendLog("  ✅ Wrote sheet: \(outputPath.lastPathComponent)")
                        progressTracker.increment() // composition step
                        totalSheets += 1
                        successfulSheets += 1
                    }

                } catch is CancellationError {
                    // Best-effort cleanup
                    await MainActor.run {
                        appendLog("  ⚠️ Sheet cancelled: \(leaf.lastPathComponent)")
                        totalSheets += 1
                        progressTracker.increment()
                    }
                    if FileManager.default.fileExists(atPath: leaf.path) { /* no-op */ }
                } catch {
                    // Clean up temp directory on error
                    let tempName = ".zz_tmp_sheet_" // prefix used above
                    let dir = leaf.appendingPathComponent(tempName, isDirectory: true)
                    if FileManager.default.fileExists(atPath: dir.path) { try? FileManager.default.removeItem(at: dir) }

                    await MainActor.run {
                        appendLog("  ❌ \(error.localizedDescription)")
                        progressTracker.increment()
                        totalSheets += 1
                    }
                }
            }

            var it = Array(targets.enumerated()).makeIterator()
            await withTaskGroup(of: Void.self) { group in
                // Prime the group
                for _ in 0..<maxFolderConcurrent {
                    guard let (i, leaf) = it.next() else { break }
                    group.addTask { @Sendable in await processFolder(index: i, leaf: leaf) }
                }
                // Drain & refill
                while let _ = await group.next() {
                    if let (i, leaf) = it.next() {
                        group.addTask { @Sendable in await processFolder(index: i, leaf: leaf) }
                    }
                }
            }

            // Finalize & notify
            let duration = Date().timeIntervalSince(runBegan)
            await MainActor.run {
                isProcessing = false
                progressTracker.finish()

                let center = UNUserNotificationCenter.current()
                let content = UNMutableNotificationContent()
                
                if Task.isCancelled {
                    appendLog("ℹ️ Photo sheets cancelled.")
                    content.title = "Photo sheets cancelled"
                    content.body = String(format: "Processing cancelled after %.0fs", duration)
                } else {
                    appendLog("✅ Photo sheets complete.")
                    let failedSheets = totalSheets - successfulSheets
                    let summary = "ℹ️ Created: \(successfulSheets) sheets — ✅ \(successfulSheets)  ❌ \(failedSheets)"
                    appendLog(summary)

                    if failedSheets == 0 {
                        appendLog("No failures 🎉")
                    }

                    content.title = "Photo sheets complete"
                    content.body = String(format: "%@ (%.0fs)", summary, duration)
                }
                
                content.sound = .default
                content.badge = 1

                if !NSApp.isActive {
                    center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
                    NSApplication.shared.dockTile.badgeLabel = Task.isCancelled ? "!" : "✓"
                }
            }
        }
    }
    
    // MARK: - Helper Methods - SMB OPTIMIZED
    
    /// Process a leaf folder with per-image progress reporting and LOCAL WRITE + ATOMIC MOVE for SMB performance
    private func processLeafFolderWithProgress(
        leaf: URL,
        height: Int,
        thumbFolderName: String,
        quality: Double,
        format: ThumbnailOutputFormat,
        progressCallback: @escaping @Sendable (Int) -> Void
    ) async throws -> Int {
        let fm = FileManager.default
        let finalThumbFolder = leaf.appendingPathComponent(thumbFolderName, isDirectory: true)
        
        // Create local temp directory for fast writes
        let localTempFolder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("thumbnailer_\(UUID().uuidString)")
        
        // Create both directories
        try await MainActor.run {
            try fm.createDirectory(at: localTempFolder, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: finalThumbFolder.path) {
                try fm.createDirectory(at: finalThumbFolder, withIntermediateDirectories: true)
            }
        }
        
        // Ensure cleanup on exit
        defer {
            try? FileManager.default.removeItem(at: localTempFolder)
        }

        // Get all image files
        let items = try await MainActor.run {
            try fm.contentsOfDirectory(
                at: leaf,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        }

        // Filter to image files
        var imageFiles: [URL] = []
        for url in items {
            let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if resourceValues?.isRegularFile == true {
                if url.lastPathComponent == thumbFolderName { continue }
                
                let skipSubstrings = ["db", "DS_Store", "dump"]
                if skipSubstrings.contains(where: { url.lastPathComponent.localizedCaseInsensitiveContains($0) }) { continue }
                
                let allowedExts: Set<String> = ["jpg","jpeg","png","heic","tif","tiff","bmp","gif","webp"]
                if allowedExts.contains(url.pathExtension.lowercased()) {
                    imageFiles.append(url)
                }
            }
        }

        // Process images to local temp folder first — BOUNDED CONCURRENCY
        // Determine concurrency based on active CPU count (avoid hardcoding)
        let cpuCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let maxConcurrent = max(1, cpuCount - 1) // leave a little headroom for UI/IO

        // Helper to process a single image and return pair of (local, final) for later atomic move
        @Sendable func processOne(imageURL: URL, index: Int) async -> (local: URL, final: URL)? {
            do {
                // Generate thumbnail filename
                let fileExtension = format.fileExtension
                let thumbnailName = imageURL.deletingPathExtension().lastPathComponent + "." + fileExtension

                let localThumbURL = localTempFolder.appendingPathComponent(thumbnailName)
                let finalThumbURL = finalThumbFolder.appendingPathComponent(thumbnailName)

                // Skip if thumbnail already exists in final location
                let exists = await MainActor.run { FileManager.default.fileExists(atPath: finalThumbURL.path) }
                if exists {
                    progressCallback(index + 1)
                    return nil
                }

                // Use ImageIO downsampling then CGContext scaling
                let thumbnailCGImage = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, Error>) in
                    DispatchQueue.global(qos: .utility).async {
                        guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else {
                            continuation.resume(throwing: NSError(domain: "ImageProcessing", code: 1))
                            return
                        }

                        let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as NSDictionary?
                        let metaW = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
                        let metaH = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0

                        let orientationValue = (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
                        let isRotated90 = (5...8).contains(orientationValue)
                        let (effW, effH) = isRotated90 ? (metaH, metaW) : (metaW, metaH)

                        guard effW > 0 && effH > 0 else {
                            continuation.resume(throwing: NSError(domain: "ImageProcessing", code: 2))
                            return
                        }

                        let scale = CGFloat(height) / CGFloat(effH)
                        let targetW = max(1, Int(round(CGFloat(effW) * scale)))
                        let targetH = max(1, height)
                        let firstPassMax = max(targetW, targetH)

                        let thumbOptions: [CFString: Any] = [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceThumbnailMaxPixelSize: firstPassMax,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceShouldCache: false
                        ]

                        guard let downsampled = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbOptions as CFDictionary) else {
                            continuation.resume(throwing: NSError(domain: "ImageProcessing", code: 3))
                            return
                        }

                        if downsampled.height == targetH {
                            continuation.resume(returning: downsampled)
                            return
                        }

                        guard let ctx = CGContext(
                            data: nil,
                            width: targetW,
                            height: targetH,
                            bitsPerComponent: 8,
                            bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        ) else {
                            continuation.resume(throwing: NSError(domain: "ImageProcessing", code: 4))
                            return
                        }

                        ctx.interpolationQuality = .medium
                        ctx.draw(downsampled, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))

                        guard let finalImage = ctx.makeImage() else {
                            continuation.resume(throwing: NSError(domain: "ImageProcessing", code: 5))
                            return
                        }

                        continuation.resume(returning: finalImage)
                    }
                }

                // Write to LOCAL temp folder (fast!)
                switch format {
                case .jpeg:
                    try await JPEGWriter.write(
                        image: thumbnailCGImage,
                        to: localThumbURL,
                        quality: quality,
                        overwrite: true,
                        progressive: false
                    )
                case .heic:
                    try await HEICWriter.write(
                        image: thumbnailCGImage,
                        to: localThumbURL,
                        quality: quality,
                        overwrite: true
                    )
                }

                // Report progress for this image
                progressCallback(index + 1)
                return (local: localThumbURL, final: finalThumbURL)

            } catch {
                // Report progress even on failure to keep UI consistent
                progressCallback(index + 1)
                return nil
            }
        }

        var written = 0
        let batchSize = 5 // Smaller batch for atomic moves
        var moveBuffer: [(local: URL, final: URL)] = []

        // Seed the task group with up to maxConcurrent items, then keep feeding as tasks finish
        var enumerated = Array(imageFiles.enumerated()).makeIterator()

        try await withThrowingTaskGroup(of: (local: URL, final: URL)?.self) { group in
            // initial window
            for _ in 0..<maxConcurrent {
                guard let (index, url) = enumerated.next() else { break }
                group.addTask { await processOne(imageURL: url, index: index) }
            }

            // drain & refill
            while let result = try await group.next() {
                if let pair = result { moveBuffer.append(pair) }

                // Batch atomic moves to SMB when buffer fills
                if moveBuffer.count >= batchSize {
                    try await performAtomicMoves(moveBuffer)
                    written += moveBuffer.count
                    moveBuffer.removeAll()
                }

                // add another task if items remain
                if let (index, url) = enumerated.next() {
                    group.addTask { await processOne(imageURL: url, index: index) }
                }
            }
        }
        
        // Move any remaining thumbnails
        if !moveBuffer.isEmpty {
            try await performAtomicMoves(moveBuffer)
            written += moveBuffer.count
            moveBuffer.removeAll()
        }
        return written
    }
    
    /// Perform atomic moves from local temp to final SMB location
    private func performAtomicMoves(_ thumbnails: [(local: URL, final: URL)]) async throws {
        try await MainActor.run {
            for (localURL, finalURL) in thumbnails {
                // Atomic move operation - single SMB transaction per file
                if FileManager.default.fileExists(atPath: finalURL.path) {
                    try? FileManager.default.removeItem(at: finalURL)
                }
                try FileManager.default.moveItem(at: localURL, to: finalURL)
            }
        }
    }
    
    /// Count images in a folder (for progress calculation)
    private func countImagesInFolder(_ folder: URL, thumbFolderName: String) async -> Int {
        do {
            let items = try await MainActor.run {
                try FileManager.default.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
            }
            
            var count = 0
            let skipSubstrings = ["db", "DS_Store", "dump"]
            let allowedExts: Set<String> = ["jpg","jpeg","png","heic","tif","tiff","bmp","gif","webp"]
            
            for url in items {
                let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey])
                if resourceValues?.isRegularFile == true {
                    if url.lastPathComponent == thumbFolderName { continue }
                    if skipSubstrings.contains(where: { url.lastPathComponent.localizedCaseInsensitiveContains($0) }) { continue }
                    if allowedExts.contains(url.pathExtension.lowercased()) {
                        count += 1
                    }
                }
            }
            return count
        } catch {
            return 0
        }
    }
 

}
 
