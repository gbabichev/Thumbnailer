/*
 
 MediaScan.swift - Enhanced Version
 Thumbnailer
 
 Scans leafs, determins if they are photo or video.
 Threaded, reports progress to UI. 
 
 George Babichev
 
 */

import Foundation

enum MediaScan {
    // MARK: - Extension sets
    static let photoExts = AppConstants.photoExts
    static let videoExts = AppConstants.allVideoExts

    // MARK: - Enhanced capability probe with better yielding
    /// Recursively scan folders to determine if they contain photos, videos, or both
    /// Enhanced with frequent yielding to prevent UI freezing on large datasets
    static func scanMediaFlags(
        roots: [URL],
        ignoreThumbFolderName: String,
        progressCallback: ((Double) -> Void)? = nil
    ) async throws -> (photos: Bool, videos: Bool) {
        var foundPhotos = false
        var foundVideos = false
        
        let ignoreName = ignoreThumbFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        
        for (index, root) in roots.enumerated() {
            try Task.checkCancellation()
            
            let (hasPhotos, hasVideos) = try await scanSingleRootEnhanced(
                root,
                ignoreFolderName: ignoreName,
                progressCallback: { processed, total in
                    let rootProgress = total > 0 ? Double(processed) / Double(total) : 1.0
                    let baseProgress = Double(index) / Double(roots.count)
                    let rootWeight = 1.0 / Double(roots.count)
                    let overallProgress = baseProgress + (rootWeight * rootProgress)
                    
                    if let mainCallback = progressCallback {
                        Task { @MainActor in
                            mainCallback(overallProgress)
                        }
                    }
                }
            )
            
            if hasPhotos { foundPhotos = true }
            if hasVideos { foundVideos = true }
            
            // Update progress after each root
            if let callback = progressCallback {
                let progress = Double(index + 1) / Double(roots.count)
                callback(progress)
            }
            
            // Early exit if we found both types
            if foundPhotos && foundVideos {
                progressCallback?(1.0)
                break
            }
        }
        
        return (foundPhotos, foundVideos)
    }

    // MARK: - Enhanced leaf folder discovery
    /// Find folders that directly contain photos with enhanced yielding
    static func scanPhotoLeafFolders(
        roots: [URL],
        ignoreThumbFolderName: String?,
        progressCallback: ((Double) -> Void)? = nil
    ) async throws -> [URL] {
        return try await findLeafFoldersEnhanced(
            in: roots,
            containing: photoExts,
            ignoreFolderName: ignoreThumbFolderName,
            progressCallback: progressCallback
        )
    }

    /// Find folders that directly contain videos with enhanced yielding
    static func scanVideoLeafFolders(
        roots: [URL],
        ignoreThumbFolderName: String? = nil,
        progressCallback: ((Double) -> Void)? = nil
    ) async throws -> [URL] {
        return try await findLeafFoldersEnhanced(
            in: roots,
            containing: videoExts,
            ignoreFolderName: ignoreThumbFolderName,
            progressCallback: progressCallback
        )
    }
    
    // MARK: - Enhanced private implementation
    
    /// Enhanced single root scanning with seamless progress (no pause/reset)
    private static func scanSingleRootEnhanced(
        _ root: URL,
        ignoreFolderName: String,
        progressCallback: ((Int, Int) -> Void)? = nil
    ) async throws -> (photos: Bool, videos: Bool) {
        var foundPhotos = false
        var foundVideos = false
        
        // Phase 1a: Quick count (but don't show progress to avoid fake numbers)
        guard let countEnumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return (false, false)
        }
        
        var totalFileCount = 0
        while let url = countEnumerator.nextObject() as? URL {
            try Task.checkCancellation()
            
            if !ignoreFolderName.isEmpty && url.lastPathComponent == ignoreFolderName {
                countEnumerator.skipDescendants()
                continue
            }
            
            totalFileCount += 1
            
            // Just yield occasionally, no progress reporting during counting
            if totalFileCount % 100 == 0 {
                await Task.yield()
            }
        }
        
        // Phase 1b: Scan with accurate progress (seamless start)
        guard let scanEnumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (false, false)
        }
        
        var processedCount = 0
        let yieldFrequency = 5
        
        while let url = scanEnumerator.nextObject() as? URL {
            try Task.checkCancellation()
            
            processedCount += 1
            
            if !ignoreFolderName.isEmpty && url.lastPathComponent == ignoreFolderName {
                scanEnumerator.skipDescendants()
                progressCallback?(processedCount, totalFileCount)
                continue
            }
            
            if let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]),
               resourceValues.isRegularFile == true {
                
                let ext = url.pathExtension.lowercased()
                if photoExts.contains(ext) { foundPhotos = true }
                if videoExts.contains(ext) { foundVideos = true }
                
                if foundPhotos && foundVideos {
                    progressCallback?(totalFileCount, totalFileCount)
                    break
                }
            }
            
            if processedCount % 5 == 0 || processedCount == totalFileCount {
                progressCallback?(processedCount, totalFileCount)
            }
            
            if processedCount % yieldFrequency == 0 {
                await Task.yield()
            }
        }
        
        progressCallback?(processedCount, totalFileCount)
        return (foundPhotos, foundVideos)
    }
    
    /// Enhanced leaf folder discovery with micro-yielding
    private static func findLeafFoldersEnhanced(
        in roots: [URL],
        containing targetExts: Set<String>,
        ignoreFolderName: String?,
        progressCallback: ((Double) -> Void)? = nil
    ) async throws -> [URL] {
        var leafFolders: [URL] = []
        let ignoreName = ignoreFolderName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        leafFolders.reserveCapacity(roots.count * 10)
        
        for (rootIndex, root) in roots.enumerated() {
            try Task.checkCancellation()
            
            let leaves = try await findLeavesInRootEnhanced(
                root,
                containing: targetExts,
                ignoreFolderName: ignoreName,
                progressCallback: { processed, total in
                    let rootProgress = total > 0 ? Double(processed) / Double(total) : 1.0
                    let baseProgress = Double(rootIndex) / Double(roots.count)
                    let rootWeight = 1.0 / Double(roots.count)
                    let overallProgress = baseProgress + (rootWeight * rootProgress)
                    
                    Task { @MainActor in
                        progressCallback?(overallProgress)
                    }
                }
            )
            leafFolders.append(contentsOf: leaves)
            
            // Update progress after each root is complete
            if let callback = progressCallback {
                let progress = Double(rootIndex + 1) / Double(roots.count)
                callback(progress)
            }
        }
        
        return leafFolders.sorted { url1, url2 in
            let path1 = url1.path
            let path2 = url2.path
            return path1.localizedStandardCompare(path2) == .orderedAscending
        }
    }
    
    /// Enhanced breadth-first search with stable progress estimates
    private static func findLeavesInRootEnhanced(
        _ root: URL,
        containing targetExts: Set<String>,
        ignoreFolderName: String,
        progressCallback: ((Int, Int) -> Void)? = nil
    ) async throws -> [URL] {
        var leafFolders: [URL] = []
        var foldersToCheck: [URL] = [root]
        var processedCount = 0
        var totalEstimate = 20 // Start with reasonable minimum
        var maxSeenTotal = 20
        
        while !foldersToCheck.isEmpty {
            try Task.checkCancellation()
            
            let currentFolder = foldersToCheck.removeFirst()
            processedCount += 1
            
            // Skip thumb folders
            if !ignoreFolderName.isEmpty && currentFolder.lastPathComponent == ignoreFolderName {
                let stableTotal = max(maxSeenTotal, processedCount + 5)
                progressCallback?(processedCount, stableTotal)
                await Task.yield()
                continue
            }
            
            // Yield before each potentially expensive file system operation
            await Task.yield()
            
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: currentFolder,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                let stableTotal = max(maxSeenTotal, processedCount + 5)
                progressCallback?(processedCount, stableTotal)
                await Task.yield()
                continue
            }
            
            var hasTargetFiles = false
            var subfolders: [URL] = []
            subfolders.reserveCapacity(items.count / 4)
            
            // Check what this folder contains with yielding
            var itemCount = 0
            for item in items {
                itemCount += 1
                
                if let resourceValues = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) {
                    if resourceValues.isDirectory == true {
                        if ignoreFolderName.isEmpty || item.lastPathComponent != ignoreFolderName {
                            subfolders.append(item)
                        }
                    } else if resourceValues.isRegularFile == true {
                        if targetExts.contains(item.pathExtension.lowercased()) {
                            hasTargetFiles = true
                        }
                    }
                }
                
                // Yield every few items even within a single folder scan
                if itemCount % 10 == 0 {
                    await Task.yield()
                }
            }
            
            if hasTargetFiles {
                leafFolders.append(currentFolder)
            }
            
            // Sort subfolders before adding (this can be expensive for large folders)
            if subfolders.count > 50 {
                // For large subfolder lists, yield before sorting
                await Task.yield()
            }
            
            let sortedSubfolders = subfolders.sorted { url1, url2 in
                url1.lastPathComponent.localizedStandardCompare(url2.lastPathComponent) == .orderedAscending
            }
            foldersToCheck.append(contentsOf: sortedSubfolders)
            
            // Update estimate with stable growth pattern
            if processedCount % 3 == 0 || foldersToCheck.isEmpty {
                let currentTotal = processedCount + foldersToCheck.count
                
                // Conservative growth - only increase estimate significantly when we're sure
                if currentTotal > maxSeenTotal {
                    maxSeenTotal = currentTotal
                    // Grow estimate conservatively to avoid wild swings
                    totalEstimate = max(totalEstimate, currentTotal + min(10, currentTotal / 10))
                }
            }
            
            // Report progress with stable, non-shrinking estimate
            let stableTotal = max(totalEstimate, maxSeenTotal, processedCount + 3)
            progressCallback?(processedCount, stableTotal)
            
            // Ultra-frequent yielding - yield after every single folder
            await Task.yield()
        }
        
        return leafFolders
    }
}
