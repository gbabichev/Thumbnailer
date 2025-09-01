/*
 
 ContentView+Actions.swift
 Thumbnailer
 
 Generic App Actions - Cleaned up epoch system
 
 George Babichev
 
 */

import SwiftUI
import Foundation

extension ContentView {
    
    // MARK: - Folder Selection & Drop Handling

    /// Normalize any incoming URLs to **folders**, resolving symlinks and replacing files with their parent directories.
    private func normalizeToFolders(_ urls: [URL]) -> [URL] {
        let fm = FileManager.default
        var folders: [URL] = []
        for raw in urls {
            guard raw.isFileURL else { continue }
            let u = raw.resolvingSymlinksInPath()
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                folders.append(u)
            } else {
                folders.append(u.deletingLastPathComponent())
            }
        }
        // De-dupe and stable sort for a predictable UI order
        let unique = Array(Set(folders)).sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        return unique
    }

    @MainActor
    /// Opens an NSOpenPanel allowing the user to pick root or leaf folders.
    func selectFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.title = "Select root or leaf folder(s)"
        if panel.runModal() == .OK {
            let folders = normalizeToFolders(panel.urls)
            handleFolderSelection(folders)
        }
    }

    @MainActor
    /// Handle dropping files/folders into the UI.
    func handleDrop(urls: [URL]) async {
        let folders = normalizeToFolders(urls)
        handleFolderSelection(folders)
    }

    @MainActor
    /// Unified folder selection handler with smart scanning
    private func handleFolderSelection(_ folders: [URL]) {
        guard !folders.isEmpty else { return }
        
        // Merge new folders with existing selection
        var addedAny = false
        for folder in folders where !selectedRoots.contains(folder) {
            selectedRoots.append(folder)
            addedAny = true
        }
        
        if addedAny {
            Task { await performSmartScan() }
        }
    }
    
    // MARK: - Smart Content Scanning
    
    @MainActor
    /// Smart scanning that determines content type first, then scans appropriately.
    /// This prevents double-scanning and eliminates beach balling.
    func performSmartScan() async {
        // Clear state immediately
        logLines.removeAll()
        leafFolders.removeAll()
        lastVideoLeafCount = -1
        mode = nil
        
        guard !selectedRoots.isEmpty else {
            appendLog("No folders selected.")
            return
        }

        // Cancel any previous work
        currentWork?.cancel()
        
        isProcessing = true
        
        currentWork = Task(priority: .userInitiated) {
            let ignoreName = thumbnailFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
            
            do {
                // Phase 1: Content type detection (0-50%)
                await MainActor.run {
                    appendLog("🔍 Phase 1: Detecting content type... (0-50%)")
                }
                let progressTracker = await MainActor.run { createProgressTracker(total: 100) }
                
                let flags = try await MediaScan.scanMediaFlags(
                    roots: selectedRoots,
                    ignoreThumbFolderName: ignoreName,
                    progressCallback: { scanProgress in
                        Task { @MainActor in
                            let adjustedProgress = Int(scanProgress * 50)
                            progressTracker.updateTo(adjustedProgress)
                        }
                    }
                )
                
                // Check if task was cancelled
                guard !Task.isCancelled else {
                    await MainActor.run {
                        appendLog("ℹ️ Content scanning cancelled")
                        isProcessing = false
                        progressTracker.finish()
                    }
                    return
                }
                
                // Determine scanning strategy based on detected content
                let (targetMode, modeMessage): (ProcessingMode?, String) = {
                    switch (flags.photos, flags.videos) {
                    case (true, false):
                        return (.photos, "📸 Detected photos - scanning photo folders...")
                    case (false, true):
                        return (.videos, "🎬 Detected videos - scanning video folders...")
                    case (true, true):
                        return (.photos, "ℹ️ Detected mixed content - defaulting to photo mode...")
                    default:
                        return (nil, "ℹ️ No media files detected")
                    }
                }()
                
                await MainActor.run {
                    appendLog(modeMessage)
                    mode = targetMode
                    progressTracker.updateTo(50)
                    
                    // Smooth transition to phase 2 - show we're starting immediately
                    if targetMode != nil {
                        appendLog("🔍 Phase 2: Scanning leaf folders... (51-100%)")
                        progressTracker.updateTo(51) // Small bump to show phase 2 started
                    }
                }

                // Phase 2: Targeted leaf scanning (51-100%)
                if let scanMode = targetMode {
                    // Small async delay to ensure UI updates before starting heavy work
                    try? await Task.sleep(for: .milliseconds(25))
                    
                    // Check if task was cancelled before starting heavy work
                    guard !Task.isCancelled else {
                        await MainActor.run {
                            appendLog("ℹ️ Content scanning cancelled")
                            isProcessing = false
                            progressTracker.finish()
                        }
                        return
                    }
                    
                    let leaves: [URL]
                    switch scanMode {
                    case .photos:
                        leaves = try await MediaScan.scanPhotoLeafFolders(
                            roots: selectedRoots,
                            ignoreThumbFolderName: ignoreName.isEmpty ? nil : ignoreName,
                            progressCallback: { scanProgress in
                                Task { @MainActor in
                                    let adjustedProgress = 51 + Int(scanProgress * 49) // 51-100
                                    progressTracker.updateTo(adjustedProgress)
                                }
                            }
                        )
                        
                    case .videos:
                        leaves = try await MediaScan.scanVideoLeafFolders(
                            roots: selectedRoots,
                            ignoreThumbFolderName: ignoreName.isEmpty ? nil : ignoreName,
                            progressCallback: { scanProgress in
                                Task { @MainActor in
                                    let adjustedProgress = 51 + Int(scanProgress * 49) // 51-100
                                    progressTracker.updateTo(adjustedProgress)
                                }
                            }
                        )
                    }
                    
                    // Check if task was cancelled after scanning
                    guard !Task.isCancelled else {
                        await MainActor.run {
                            appendLog("ℹ️ Content scanning cancelled")
                            isProcessing = false
                            progressTracker.finish()
                        }
                        return
                    }
                    
                    await MainActor.run {
                        leafFolders = leaves.map { LeafFolder(url: $0) }
                        let mediaType = scanMode == .photos ? "photo" : "video"
                        appendLog("\(scanMode == .photos ? "📸" : "🎬") Found \(leaves.count) \(mediaType) folder(s)")
                        
                        if scanMode == .videos {
                            lastVideoLeafCount = leaves.count
                        }
                    }
                }
                
                await MainActor.run {
                    progressTracker.updateTo(100)
                    
                    // Brief delay to show completion, then cleanup
                    Task {
                        try? await Task.sleep(for: .milliseconds(200))
                        await MainActor.run {
                            progressTracker.finish()
                            isProcessing = false
                        }
                    }
                }
                
            } catch is CancellationError {
                await MainActor.run {
                    appendLog("ℹ️ Content scanning cancelled")
                    isProcessing = false
                }
            } catch {
                await MainActor.run {
                    appendLog("❌ Content scanning failed: \(error.localizedDescription)")
                    isProcessing = false
                }
            }
        }
    }
    
    // MARK: - Processing Actions

    @MainActor
    func deleteThumbFolders() {
        guard !isProcessing else { return }
        isProcessing = true
        logLines.removeAll()
        
        currentWork?.cancel()
        currentWork = Task(priority: .userInitiated) {
            let progressTracker = createProgressTracker(total: leafFolders.count)
            
            for leaf in leafFolders {
                await MainActor.run { appendLog("🔍 Checking \(leaf.url.path)") }
                let thumb = leaf.url.appendingPathComponent(thumbnailFolderName, isDirectory: true)
                let fileExists = FileManager.default.fileExists(atPath: thumb.path)
                if fileExists {
                    do {
                        try FileManager.default.removeItem(at: thumb)
                        await MainActor.run { appendLog("  🗑️ Removed \(thumbnailFolderName) folder") }
                    } catch {
                        await MainActor.run { appendLog("  ❌  Failed to remove: \(error.localizedDescription)") }
                    }
                } else {
                    await MainActor.run { appendLog("  ℹ️ No \(thumbnailFolderName) folder found") }
                }
                
                await MainActor.run { progressTracker.increment() }
            }
            
            await MainActor.run {
                appendLog("ℹ️ Clean operation finished.")
                isProcessing = false
                progressTracker.finish()
            }
        }
    }

    @MainActor
    func clearAll() {
        // Cancel any running work first
        currentWork?.cancel()
        currentWork = nil
        
        isProcessing = false
        progress = nil
        mode = nil

        selectedRoots.removeAll()
        leafFolders.removeAll()
        lastVideoLeafCount = -1

        logLines.removeAll()

        // Clear Dock/app badge when user clears the view
        clearAppBadge()
        clearDeliveredNotifications()
    }
    
    @MainActor
    func cancelCurrentWork() {
        currentWork?.cancel()
        currentWork = nil
        isProcessing = false
        progress = nil
        appendLog("ℹ️ Cancelled.")
        
        // Ensure UI is properly reset after cancellation
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            isProcessing = false
            progress = nil
        }
    }
    
    // MARK: - Leaf Folder Management
    
    @MainActor
    func removeSelectedLeafs() {
        guard !isProcessing, !selectedLeafIDs.isEmpty else { return }
      
        let selectedLeafs = leafFolders.filter { selectedLeafIDs.contains($0.id) }
        let count = selectedLeafs.count
        
        // Remove from leafFolders
        leafFolders.removeAll { selectedLeafIDs.contains($0.id) }
        
        // Remove from selectedRoots - check both the leaf URLs and their parents
        let leafURLs = Set(selectedLeafs.map { $0.url.standardizedFileURL })
        let parentURLs = Set(selectedLeafs.map { $0.url.deletingLastPathComponent().standardizedFileURL })
        
        selectedRoots.removeAll { root in
            let rootStandard = root.standardizedFileURL
            return leafURLs.contains(rootStandard) || parentURLs.contains(rootStandard)
        }
        
        // Clear selection and update mode
        selectedLeafIDs.removeAll()
        updateModeAfterRemoval()
        
        appendLog("🗑️ Removed \(count) selected folder(s).")
        
        if leafFolders.isEmpty {
            mode = nil
            appendLog("ℹ️ No folders remaining.")
        }
    }
      
    @MainActor
    func removeLeafs(withIDs ids: Set<UUID>) {
        guard !isProcessing, !ids.isEmpty else { return }
        
        let leafsToRemove = leafFolders.filter { ids.contains($0.id) }
        let count = leafsToRemove.count
        
        // Remove from leafFolders
        leafFolders.removeAll { ids.contains($0.id) }
        
        // Remove from selectedRoots - check both the leaf URLs and their parents
        let leafURLs = Set(leafsToRemove.map { $0.url.standardizedFileURL })
        let parentURLs = Set(leafsToRemove.map { $0.url.deletingLastPathComponent().standardizedFileURL })
        
        selectedRoots.removeAll { root in
            let rootStandard = root.standardizedFileURL
            return leafURLs.contains(rootStandard) || parentURLs.contains(rootStandard)
        }
        
        // Clear selection for removed items and update mode
        selectedLeafIDs.subtract(ids)
        updateModeAfterRemoval()
        
        appendLog("🗑️ Removed \(count) folder(s).")
        
        if leafFolders.isEmpty {
            mode = nil
            selectedLeafIDs.removeAll()
            appendLog("ℹ️ No folders remaining.")
        }
    }
      
    @MainActor
    func removeLeaf(_ leaf: LeafFolder) {
        guard !isProcessing else { return }
        
        // Remove from selection first
        selectedLeafIDs.remove(leaf.id)
        
        // Remove from leafFolders
        leafFolders.removeAll { $0.id == leaf.id }
        
        // Remove from selectedRoots - check both the leaf URL and its parent
        let leafURL = leaf.url.standardizedFileURL
        let parentURL = leaf.url.deletingLastPathComponent().standardizedFileURL
        
        selectedRoots.removeAll { root in
            let rootStandard = root.standardizedFileURL
            return rootStandard == leafURL || rootStandard == parentURL
        }
        
        updateModeAfterRemoval()
        appendLog("🗑️ Removed folder: \(leaf.displayName)")
        
        if leafFolders.isEmpty {
            mode = nil
            selectedLeafIDs.removeAll()
            appendLog("ℹ️ No folders remaining.")
        }
    }
    
    @MainActor
    /// Lightweight mode update after removing folders
    func updateModeAfterRemoval() {
        guard !leafFolders.isEmpty else {
            mode = nil
            return
        }
        
        // Quick validation of current mode based on remaining folders
        // This is lightweight since we're only checking existing leaf folders
        let hasPhotos = leafFolders.contains { folder in
            // Quick check for any photo files in the folder
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: folder.url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return false }
            
            return items.prefix(10).contains { item in // Check only first 10 files for speed
                guard (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return false }
                return AppConstants.photoExts.contains(item.pathExtension.lowercased())
            }
        }
        
        let hasVideos = leafFolders.contains { folder in
            // Quick check for any video files in the folder
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: folder.url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return false }
            
            return items.prefix(10).contains { item in // Check only first 10 files for speed
                guard (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return false }
                return AppConstants.allVideoExts.contains(item.pathExtension.lowercased())
            }
        }
        
        // Update mode based on what remains
        switch (hasPhotos, hasVideos) {
        case (true, false):
            mode = .photos
        case (false, true):
            mode = .videos
        case (true, true):
            // Keep current mode if mixed content
            break
        default:
            mode = nil
        }
    }
    
    // MARK: - Logging
    
    @MainActor
    func appendLog(_ line: String) {
        // UI log with aggressive memory management
        logLines.append(line)
        
        // More aggressive memory management during heavy operations
        let maxLines = isProcessing ? 200 : 500
        if logLines.count > maxLines {
            let toRemove = logLines.count - (maxLines - 50) // Remove more at once
            logLines.removeFirst(toRemove)
        }
        
        // Buffered disk log (batched writes) - but throttle during heavy processing
        if !isProcessing || logLines.count % 5 == 0 {
            AppLogWriter.appendToFile(line)
        }
        
        // Emergency safety: if we somehow get too many lines, trim aggressively
        if logLines.count > maxLines * 2 {
            logLines = Array(logLines.suffix(100)) // Keep only last 100 lines
            logLines.append("⚠️ Log trimmed due to size - showing last 100 entries")
        }
    }
    
    // MARK: - Log File Management
    
    private var _safeAppName: String {
        let info = Bundle.main.infoDictionary
        let raw =
            (info?["CFBundleDisplayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (info?["CFBundleName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ProcessInfo.processInfo.processName
        return raw.replacingOccurrences(of: "/", with: "-")
    }

    func logsDirURL() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let dir  = base.appendingPathComponent("Logs/\(_safeAppName)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func logFileURL() -> URL {
        logsDirURL().appendingPathComponent("latest.txt")
    }

    var logFolderExists: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: logsDirURL().path, isDirectory: &isDir) && isDir.boolValue
    }

    var logFileExists: Bool {
        FileManager.default.fileExists(atPath: logFileURL().path)
    }

    func openLogFile() {
        let url = logFileURL()
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.deletingLastPathComponent().path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        NSWorkspace.shared.open(url)
    }
    
    func openLogFolder() {
        let dir = logsDirURL()
        NSWorkspace.shared.open(dir)
    }
}
