/*
 
 ContentView+Tools.swift
 Thumbnailer
 
 Photo & Video "menu bar tools" - FIXED: Cancellable convert operations
 
 George Babichev
 
 */

import Foundation
import UserNotifications
import AppKit

extension ContentView {
    // MARK: - Photo Tools
    
    @MainActor
    func scanJPGMenuAction(checkMagic: Bool = false) async {
        let leaves = leafFolders.map(\.url)
        guard !leaves.isEmpty else {
            appendLog("No leaf folders to scan. Select a folder first.")
            return
        }
        
        isProcessing = true
        logLines.removeAll()
        
        let progressTracker = createProgressTracker(total: leaves.count)
        var allBadFiles: [URL] = []
        
        for leaf in leaves {
            appendLog("🔍 Scanning JPGs under: \(leaf.path)")
            
            let nonJPEGs = ScanJPG.scan(root: leaf, checkMagic: checkMagic)
            allBadFiles.append(contentsOf: nonJPEGs)
            
            if nonJPEGs.isEmpty {
                appendLog("  ✅ All files are JPEG images.")
            } else {
                appendLog("  ❌ Non-JPEG files found (\(nonJPEGs.count)):")
                nonJPEGs.forEach { appendLog("    ⚠️ \($0.lastPathComponent)") }
            }
            
            progressTracker.increment()
        }
        
        let totalBad = allBadFiles.count
        appendLog("✅ Scan complete.")
        if totalBad == 0 {
            appendLog("ℹ️ All files are JPEG images!")
        } else {
            appendLog("📋  Summary — Non-JPEG files across all folders: \(totalBad)")
        }
        
        isProcessing = false
        progressTracker.finish()
    }
    
    @MainActor
    func scanHEICMenuAction() async {
        guard !leafFolders.isEmpty else {
            appendLog("No photo folders to scan. Select folders first.")
            return
        }
        
        guard !isProcessing else {
            appendLog("Cannot start HEIC scan while processing.")
            return
        }
        
        isProcessing = true
        logLines.removeAll()
        
        let targets = leafFolders.map(\.url)
        
        currentWork?.cancel()
        currentWork = Task(priority: .userInitiated) {
            let progressTracker = createProgressTracker(total: targets.count)
            
            await MainActor.run {
                appendLog("🔍 Scanning for non-HEIC image files...")
                appendLog("🔍 Checking \(targets.count) folder(s)")
            }
            
            var totalNonHeicFiles = 0
            var foldersWithIssues = 0
            
            let results = await ScanHEIC.scanLeafFolders(targets, checkMagic: false)
            
            for (_, folder) in targets.enumerated() {
                if Task.isCancelled { break }
                
                let nonHeicFiles = results[folder] ?? []
                
                await MainActor.run {
                    if nonHeicFiles.isEmpty {
                        appendLog("✅ \(folder.lastPathComponent): All image files are HEIC")
                    } else {
                        foldersWithIssues += 1
                        appendLog("⚠️ \(folder.lastPathComponent): \(nonHeicFiles.count) non-HEIC image files found")
                        
                        // Log up to 10 files per folder to avoid spam
                        let filesToShow = Array(nonHeicFiles.prefix(10))
                        for file in filesToShow {
                            let ext = file.pathExtension.uppercased()
                            appendLog("   • \(file.lastPathComponent) (\(ext))")
                        }
                        
                        if nonHeicFiles.count > 10 {
                            appendLog("   ... and \(nonHeicFiles.count - 10) more files")
                        }
                        
                        totalNonHeicFiles += nonHeicFiles.count
                    }
                    
                    progressTracker.increment()
                }
            }
            
            await MainActor.run {
                isProcessing = false
                progressTracker.finish()
                
                if Task.isCancelled {
                    appendLog("ℹ️ HEIC scan cancelled.")
                } else {
                    appendLog("✅ HEIC scan complete.")
                    
                    if totalNonHeicFiles == 0 {
                        appendLog("🎉 All image files are already in HEIC format!")
                    } else {
                        appendLog("📊 Summary: \(totalNonHeicFiles) non-HEIC image files in \(foldersWithIssues) folder(s)")
                        appendLog("💡 Tip: Use Photo Tools → Convert to HEIC to convert these files")
                    }
                }
            }
        }
    }
    
    // --- FIXED: Properly cancellable convert operations ---
    
    @MainActor
    func convertJPGMenuAction() async {
        let leaves = leafFolders.map(\.url)
        guard !leaves.isEmpty else {
            appendLog("No leaf folders selected.")
            return
        }
        
        // Ensure badge clears on foreground & clear any stale badge
        ensureBadgeAutoClearInstalled()
        clearAppBadge()
        
        // Request permission for notifications (non-blocking)
        Task {
            try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        }
        
        isProcessing = true
        logLines.removeAll()
        appendLog("🖼️ Converting images to .jpg…")
        
        let progressTracker = createProgressTracker(total: leaves.count)
        let runBegan = Date()
        
        // FIXED: Properly wrap in currentWork task for cancellation
        currentWork?.cancel()
        currentWork = Task(priority: .userInitiated) {
            do {
                // Use the existing ConvertToJPG.run method but track progress by folder
                let result = await ConvertToJPG.run(
                    leaves: leaves,
                    ignoreFolderName: thumbnailFolderName,
                    quality: jpegQuality,
                    log: { line in
                        // Check for cancellation in the log callback
                        guard !Task.isCancelled else { return }
                        
                        // Update progress when we see folder processing messages
                        if line.hasPrefix("📂 Processing:") {
                            Task { @MainActor in
                                guard !Task.isCancelled else { return }
                                progressTracker.increment()
                            }
                        }
                        Task { @MainActor in
                            guard !Task.isCancelled else { return }
                            appendLog(line)
                        }
                    }
                )
                
                // Check for cancellation before finalizing
                try Task.checkCancellation()
                
                // Finalize & notify
                let duration = Date().timeIntervalSince(runBegan)
                let summary = "Folders: \(result.scannedFolders), Converted: \(result.converted), Renamed: \(result.renamed), Already JPG: \(result.skipped)"
                
                await MainActor.run {
                    appendLog("✅ Convert-to-JPG complete. \(summary)")
                }
                
                // Only schedule a user notification if the app is NOT active (no focus)
                if !NSApp.isActive {
                    let center = UNUserNotificationCenter.current()
                    let content = UNMutableNotificationContent()
                    content.title = "Convert to JPEG complete"
                    content.body = String(format: "%@ (%.0fs)", summary, duration)
                    content.sound = .default
                    content.badge = 1
                    try? await center.add(
                        UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                    )
                    await MainActor.run {
                        NSApplication.shared.dockTile.badgeLabel = "✓"
                    }
                }
                
            } catch is CancellationError {
                await MainActor.run {
                    appendLog("ℹ️ Convert-to-JPG cancelled.")
                }
            } catch {
                await MainActor.run {
                    appendLog("❌ Convert-to-JPG failed: \(error.localizedDescription)")
                }
            }
            
            await MainActor.run {
                isProcessing = false
                progressTracker.finish()
            }
        }
    }
    
    @MainActor
    func convertHEICMenuAction() async {
        let leaves = leafFolders.map(\.url)
        guard !leaves.isEmpty else {
            appendLog("No leaf folders selected.")
            return
        }
        
        // Check HEIC support first
        guard HEICWriter.isHEICSupported else {
            appendLog("❌ HEIC format is not supported on this system (requires macOS 10.13+)")
            return
        }
        
        // Ensure badge clears on foreground & clear any stale badge
        ensureBadgeAutoClearInstalled()
        clearAppBadge()
        
        // Request permission for notifications (non-blocking)
        Task {
            try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        }
        
        isProcessing = true
        logLines.removeAll()
        appendLog("🖼️ Converting images to .heic…")
        
        let progressTracker = createProgressTracker(total: leaves.count)
        let runBegan = Date()
        
        // FIXED: Properly wrap in currentWork task for cancellation
        currentWork?.cancel()
        currentWork = Task(priority: .userInitiated) {
            do {
                // Use the ConvertToHEIC.run method
                let result = await ConvertToHEIC.run(
                    leaves: leaves,
                    ignoreFolderName: thumbnailFolderName,
                    quality: jpegQuality, // Reuse the JPEG quality setting
                    log: { line in
                        // Check for cancellation in the log callback
                        guard !Task.isCancelled else { return }
                        
                        // Update progress when we see folder processing messages
                        if line.hasPrefix("📂 Processing:") {
                            Task { @MainActor in
                                guard !Task.isCancelled else { return }
                                progressTracker.increment()
                            }
                        }
                        Task { @MainActor in
                            guard !Task.isCancelled else { return }
                            appendLog(line)
                        }
                    }
                )
                
                // Check for cancellation before finalizing
                try Task.checkCancellation()
                
                // Finalize & notify
                let duration = Date().timeIntervalSince(runBegan)
                let summary = "Folders: \(result.scannedFolders), Converted: \(result.converted), Already HEIC: \(result.skipped)"
                
                await MainActor.run {
                    appendLog("✅ Convert-to-HEIC complete. \(summary)")
                }
                
                if !NSApp.isActive {
                    // Send notification
                    let center = UNUserNotificationCenter.current()
                    let content = UNMutableNotificationContent()
                    content.title = "Convert to HEIC complete"
                    content.body = String(format: "%@ (%.0fs)", summary, duration)
                    content.sound = .default
                    content.badge = 1
                    
                    try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
                    await MainActor.run {
                        NSApplication.shared.dockTile.badgeLabel = "✓"
                    }
                }
                
            } catch is CancellationError {
                await MainActor.run {
                    appendLog("ℹ️ Convert-to-HEIC cancelled.")
                }
            } catch {
                await MainActor.run {
                    appendLog("❌ Convert-to-HEIC failed: \(error.localizedDescription)")
                }
            }
            
            await MainActor.run {
                isProcessing = false
                progressTracker.finish()
            }
        }
    }
    
    // ---
    
    @MainActor
    func identifyLowFilesMenuAction() {
        // No-op safety: nothing to scan
        guard !leafFolders.isEmpty else {
            appendLog("No folders selected.")
            return
        }
        
        logLines.removeAll()
        
        IdentityLowFiles.runScan(
            leafs: leafFolders.map(\.url),
            minCount: minImagesPerLeaf,
            ignoreFolderNames: [thumbnailFolderName],
            includeHidden: false,
            appendLog: { appendLog($0) }
        )
    }
    
    @MainActor
    func validatePhotoThumbsMenuAction() async {
        let leaves = leafFolders.map(\.url)
        guard !leaves.isEmpty else {
            appendLog("No leaf folders to validate. Select a folder first.")
            return
        }
        
        guard mode == .photos else {
            appendLog("Photo/thumb validation is only available in photo mode.")
            return
        }
        
        isProcessing = true
        logLines.removeAll()
        appendLog("🔍 Validating photo vs thumbnail counts...")
        
        let progressTracker = createProgressTracker(total: leaves.count)
        
        let results = await PhotoThumbValidator.validateLeafFolders(
            leafs: leaves,
            thumbFolderName: thumbnailFolderName,
            appendLog: { @Sendable line in
                Task { @MainActor in
                    appendLog(line)
                    // Update progress when we see validation messages
                    if line.hasPrefix("🔍 Validating:") {
                        progressTracker.increment()
                    }
                }
            }
        )
        
        // Generate summary
        let (_, mismatchCount, summaryText) = PhotoThumbValidator.generateSummary(from: results)
        
        appendLog("")
        appendLog("📋  Summary:")
        appendLog(summaryText)
        
        // Show detailed mismatches if any
        if mismatchCount > 0 {
            appendLog("")
            appendLog("Detailed mismatches:")
            let mismatches = results.filter { !$0.isMatch }
            for mismatch in mismatches {
                let diff = mismatch.photoCount - mismatch.thumbCount
                let diffText = diff > 0 ? "+\(diff)" : "\(diff)"
                appendLog("⚠️ \(mismatch.summaryLine) (diff: \(diffText))")
            }
        }
        
        isProcessing = false
        progressTracker.finish()
    }
    
    // ---
    
    @MainActor
    func deleteContactlessLeafs() {
        let leaves = leafFolders.map(\.url)
        guard !leaves.isEmpty else {
            appendLog("No leaf folders loaded. Select roots first.")
            return
        }
        
        logLines.removeAll()
        appendLog("🔍 Scanning for contactless leaf folders…")
        
        Task(priority: .userInitiated) {
            let victims = leafsMissingSheets(in: leaves)
            
            await MainActor.run {
                if victims.isEmpty {
                    appendLog("✅ All leaf folders have contact sheets. Nothing to delete.")
                    return
                }
                // Stage A: stash victims & ask user
                pendingContactlessVictims = victims
                showConfirmDeleteContactless = true
            }
        }
    }
    
    /// Stage B: called by the alert's destructive button for photo folders
    @MainActor
    func actuallyDeleteContactlessVictims() async {
        let victims = pendingContactlessVictims
        pendingContactlessVictims = []   // clear immediately so repeated clicks are safe
        
        appendLog("   🔍 Found \(victims.count) contactless leaf folder(s). Deleting…")
        
        // Run the trashing off the main actor - use the trash function from ContactlessPhotoRemover
        let (ok, fail) = await withCheckedContinuation { cont in
            Task(priority: .userInitiated) {
                let result = trash(victims) { msg in
                    Task { @MainActor in appendLog(msg) }
                }
                cont.resume(returning: result)
            }
        }
        
        appendLog("✅ Deleted: \(ok)    ❌ Failed: \(fail)")
        
        // In-place prune so UI updates immediately (no rescan / no race)
        let victimsSet = Set(victims.map { $0.standardizedFileURL })
        leafFolders.removeAll { victimsSet.contains($0.url.standardizedFileURL) }
        
        // Use lightweight mode update instead of heavy scanning
        updateModeAfterRemoval()
    }
    
}
