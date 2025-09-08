/*
 
 ContentView+Actions.swift
 Thumbnailer
 
 Generic App Actions - Fixed compilation errors
 
 George Babichev
 
 */

import SwiftUI
import Foundation

// MARK: - Log Session Marker (file-scoped)
fileprivate let _logSessionID: String = UUID().uuidString
fileprivate let _sessionMarkerPrefix: String = "=== SESSION START ==="
fileprivate let _processStartDate: Date = Date()

// Use a class to hold mutable state
fileprivate class SessionState {
    static let shared = SessionState()
    var wroteLogSessionMarker: Bool = false
    private init() {}
}

// Try to parse a timestamp from a log line
fileprivate func _parseLogTimestamp(_ line: String) -> Date? {
    let head: String
    if let range = line.range(of: ":::") {
        head = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
    } else {
        head = line.trimmingCharacters(in: .whitespaces)
    }
    
    let iso = ISO8601DateFormatter()
    if let d = iso.date(from: head) { return d }
    
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone(secondsFromGMT: 0)
    df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    if let d = df.date(from: head) { return d }
    df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    if let d = df.date(from: head) { return d }
    return nil
}

fileprivate func _ensureLogSessionMarker() {
    if !SessionState.shared.wroteLogSessionMarker {
        let ts = ISO8601DateFormatter().string(from: Date())
        AppLogWriter.appendToFile("\(_sessionMarkerPrefix) \(_logSessionID) @ \(ts)")
        SessionState.shared.wroteLogSessionMarker = true
    }
}

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
                folders.append(u) // FIXED: was "appendappend"
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
                        if (leaves.count > 500){
                            appendLog("!!!!!!!!!!")
                            appendLog("WARNING: LOTS OF FOLDERS FOUND! Hide the log during processing for increased performance!")
                            appendLog("!!!!!!!!!!")
                        }
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

        // Cancel any previously running delete task
        currentWork?.cancel()

        // Stable snapshots to avoid races with UI changes
        let leafsSnapshot = leafFolders
        let thumbName = thumbnailFolderName

        // Precompute immutable, Sendable inputs for tasks
        let thumbPaths: [String] = leafsSnapshot.map {
            $0.url.appendingPathComponent(thumbName, isDirectory: true).path
        }
        let total = thumbPaths.count

        // Choose a sensible parallelism: I/O-bound, 4–8 is a good range
        let maxParallel = min(max(4, ProcessInfo.processInfo.processorCount / 2), 8)

        enum DeletionResult: Sendable {
            case removed
            case missing
            case failed(path: String, error: String)
        }

        currentWork = Task(priority: .userInitiated) {
            let progressTracker = await MainActor.run { createProgressTracker(total: total) }

            // Early cancel
            if Task.isCancelled {
                await MainActor.run {
                    appendLog("ℹ️ Delete cancelled")
                    isProcessing = false
                    progressTracker.finish()
                }
                return
            }

            var removedCount = 0
            var missingCount = 0
            var failed: [(String, String)] = []
            var submitted = 0
            var completed = 0

            await MainActor.run { appendLog("ℹ️ Starting deletion of thumbnail folders...") }
            
            await withTaskGroup(of: DeletionResult.self) { group in
                // Prime up to maxParallel
                let initial = min(maxParallel, total)
                while submitted < initial {
                    let path = thumbPaths[submitted]
                    group.addTask { @Sendable in
                        let fm = FileManager.default
                        if fm.fileExists(atPath: path) {
                            do {
                                try fm.removeItem(atPath: path)
                                return .removed
                            } catch {
                                return .failed(path: path, error: error.localizedDescription)
                            }
                        } else {
                            return .missing
                        }
                    }
                    submitted += 1
                }

                // As each task finishes, submit one more until all are enqueued
                while let result = await group.next() {
                    if Task.isCancelled { break }

                    // Tally on the main actor (no cross-thread mutation)
                    await MainActor.run {
                        switch result {
                        case .removed: removedCount += 1
                        case .missing: missingCount += 1
                        case .failed(let path, let err): failed.append((path, err))
                        }
                        completed += 1
                        progressTracker.increment()
                        if completed % 50 == 0 {
                            appendLog("… \(completed)/\(total) checked")
                        }
                    }

                    if submitted < total {
                        let path = thumbPaths[submitted]
                        group.addTask { @Sendable in
                            let fm = FileManager.default
                            if fm.fileExists(atPath: path) {
                                do {
                                    try fm.removeItem(atPath: path)
                                    return .removed
                                } catch {
                                    return .failed(path: path, error: error.localizedDescription)
                                }
                            } else {
                                return .missing
                            }
                        }
                        submitted += 1
                    }
                }
            }

            // Final cancel check
            if Task.isCancelled {
                await MainActor.run {
                    appendLog("ℹ️ Delete cancelled")
                    isProcessing = false
                    progressTracker.finish()
                }
                return
            }

            // Summarize
            await MainActor.run {
                if removedCount > 0 { appendLog("🗑️ Removed \(removedCount) \"\(thumbName)\" folder(s)") }
                if missingCount > 0 { appendLog("ℹ️ No \"\(thumbName)\" folder found for \(missingCount) item(s)") }
                if !failed.isEmpty {
                    appendLog("❌ Failed to remove \(failed.count) folder(s):")
                    for (i, entry) in failed.prefix(10).enumerated() {
                        appendLog("  \(i+1). \(entry.0) — \(entry.1)")
                    }
                    if failed.count > 10 {
                        appendLog("  …and \(failed.count - 10) more")
                    }
                }

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
        _ensureLogSessionMarker()
        
        // Always write to disk, regardless of UI state
        AppLogWriter.appendToFile(line)

        // Update UI only when the log is visible
        guard showLog else { return }

        // Append to in-memory UI log
        logLines.append(line)

        // Aggressive memory management while updating UI
        let maxLines = isProcessing ? 200 : 500
        if logLines.count > maxLines {
            let toRemove = logLines.count - (maxLines - 50)
            logLines.removeFirst(toRemove)
        }

        // Emergency safety
        if logLines.count > maxLines * 2 {
            logLines = Array(logLines.suffix(100))
            logLines.append("⚠️ Log trimmed due to size - showing last 100 entries")
        }
    }

    // MARK: - Add refreshUILogFromDisk method
    
    @MainActor
    func refreshUILogFromDisk() {
        guard showLog else { return }
        
        var recent: [String] = []
        if let tail = AppLogWriter.readTail(400), !tail.isEmpty {
            recent = tail
        } else if let all = AppLogWriter.readAll(), !all.isEmpty {
            recent = Array(all.suffix(2000))
        } else {
            logLines = []
            return
        }

        // Find the latest session marker for this launch
        let marker = "\(_sessionMarkerPrefix) \(_logSessionID)"
        var startIdx: Int? = nil
        for (idx, line) in recent.enumerated().reversed() {
            if line.contains(marker) {
                startIdx = idx + 1
                break
            }
        }

        // Build candidate lines for this launch
        var sessionLines: [String] = []
        if let idx = startIdx, idx < recent.count {
            sessionLines = Array(recent.suffix(from: idx))
        } else {
            // Fallback: filter by timestamp
            let cutoff = _processStartDate.addingTimeInterval(-30)
            sessionLines = recent.filter { line in
                if let d = _parseLogTimestamp(line) {
                    return d >= cutoff
                }
                return false
            }

            // Final fallback
            if sessionLines.isEmpty {
                if let mod = _logFileModificationDate(),
                   mod >= _processStartDate.addingTimeInterval(-60) {
                    sessionLines = Array(recent.suffix(100))
                }
            }
        }

        // Clean up the lines
        let cleaned = sessionLines.filter { line in
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return !t.isEmpty
        }
        logLines = Array(cleaned.suffix(100))

        // Apply safety trimming
        let maxLines = isProcessing ? 200 : 500
        if logLines.count > maxLines * 2 {
            logLines = Array(logLines.suffix(100))
            logLines.append("⚠️ Log trimmed due to size - showing last 100 entries")
        }
    }

    // MARK: - Helper method
    
    private func _logFileModificationDate() -> Date? {
        let path = logFileURL().path
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let m = attrs[.modificationDate] as? Date {
            return m
        }
        return nil
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
