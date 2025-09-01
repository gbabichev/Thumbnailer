//
//  VideoParentMover.swift
//  Thumbnailer
//
//  Created by George Babichev on 8/18/25.
//


/*
 
 VideoParentMover.swift
 Thumbnailer
 
 Moves video files from leaf folders to their parent directories.
 Useful for flattening nested video folder structures.
 
 George Babichev
 
 */

import Foundation

struct VideoParentMover {
    
    /// Result of moving videos to parent directories
    struct MoveResult: Sendable {
        let scannedLeafFolders: Int
        let totalVideoFiles: Int
        let successfullyMoved: Int
        let skippedDuplicates: Int
        let failedMoves: Int
        let failedPaths: [String]
        let emptyFoldersRemoved: Int
        
    }
    
    /// Moves video files from leaf folders to their parent directories
    /// - Parameters:
    ///   - leafFolders: Array of leaf folder URLs containing videos
    ///   - thumbFolderName: Name of thumbnail folder to ignore/preserve
    ///   - removeEmptyFolders: Whether to remove leaf folders if they become empty after moving videos
    ///   - log: Logging callback for progress updates
    /// - Returns: Detailed results of the move operation
    static func moveVideosToParent(
        in leafFolders: [URL],
        thumbFolderName: String,
        removeEmptyFolders: Bool = false,
        log: @escaping (String) -> Void
    ) -> MoveResult
    {
        var totalVideoFiles = 0
        var successfullyMoved = 0
        var skippedDuplicates = 0
        var failedMoves = 0
        var failedPaths: [String] = []
        var emptyFoldersRemoved = 0
        
        let fm = FileManager.default
        
        log("🎬 Starting video move operation...")
        
        for leafFolder in leafFolders {
            log("📁 Processing: \(leafFolder.lastPathComponent)")
            
            // Check if leaf folder exists and is a directory
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: leafFolder.path, isDirectory: &isDir), isDir.boolValue else {
                log("  ⚠️ Not a directory, skipping")
                continue
            }
            
            // Get parent directory
            let parentFolder = leafFolder.deletingLastPathComponent()
            guard parentFolder != leafFolder else {
                log("  ⚠️ Cannot move to parent (already at root), skipping")
                continue
            }
            
            // Find all video files in the leaf folder
            let videoFiles = findVideoFiles(in: leafFolder)
            if videoFiles.isEmpty {
                log("  ℹ️ No video files found")
                continue
            }
            
            log("  🎥 Found \(videoFiles.count) video file(s)")
            totalVideoFiles += videoFiles.count
            
            var movedFromThisFolder = 0
            
            // Move each video file to parent
            for videoFile in videoFiles {
                let fileName = videoFile.lastPathComponent
                let destination = parentFolder.appendingPathComponent(fileName)
                
                // Check if destination already exists
                if fm.fileExists(atPath: destination.path) {
                    log("    ⚠️ Skipped (destination exists): \(fileName)")
                    skippedDuplicates += 1
                    continue
                }
                
                // Attempt to move the file
                do {
                    try fm.moveItem(at: videoFile, to: destination)
                    log("    ✅ Moved: \(fileName)")
                    successfullyMoved += 1
                    movedFromThisFolder += 1
                } catch {
                    log("    ❌ Failed to move: \(fileName) — \(error.localizedDescription)")
                    failedMoves += 1
                    failedPaths.append(videoFile.path)
                }
            }
            
            // Check if we should remove empty folder
            if removeEmptyFolders && movedFromThisFolder > 0 {
                let remainingItems = findRemainingItems(in: leafFolder, ignoringSubdir: thumbFolderName)
                if remainingItems.isEmpty {
                    do {
                        try fm.removeItem(at: leafFolder)
                        log("    🗑️ Removed empty folder: \(leafFolder.lastPathComponent)")
                        emptyFoldersRemoved += 1
                    } catch {
                        log("    ⚠️ Failed to remove empty folder: \(error.localizedDescription)")
                    }
                } else {
                    log("    ℹ️ Folder not empty (\(remainingItems.count) items remain), keeping")
                }
            }
        }
        
        return MoveResult(
            scannedLeafFolders: leafFolders.count,
            totalVideoFiles: totalVideoFiles,
            successfullyMoved: successfullyMoved,
            skippedDuplicates: skippedDuplicates,
            failedMoves: failedMoves,
            failedPaths: failedPaths,
            emptyFoldersRemoved: emptyFoldersRemoved
        )
    }
    
    // MARK: - Private Helpers
    
    /// Find all video files in a folder, excluding a specific subdirectory
    private static func findVideoFiles(in folder: URL) -> [URL] {
        let fm = FileManager.default
        
        guard let items = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        
        var videoFiles: [URL] = []
        
        for item in items {
            // Skip directories (including thumb folder)
            if let resourceValues = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) {
                if resourceValues.isDirectory == true {
                    continue // Skip all subdirectories for this operation
                }
                
                if resourceValues.isRegularFile == true {
                    // Check if it's a video file
                    let ext = item.pathExtension.lowercased()
                    if AppConstants.allVideoExts.contains(ext) {
                        videoFiles.append(item)
                    }
                }
            }
        }
        
        return videoFiles.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }
    
    /// Find remaining items in folder (for empty folder detection)
    private static func findRemainingItems(in folder: URL, ignoringSubdir: String) -> [URL] {
        let fm = FileManager.default
        
        guard let items = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        
        var remainingItems: [URL] = []
        
        for item in items {
            // Skip the thumb folder when counting remaining items
            if item.lastPathComponent.caseInsensitiveCompare(ignoringSubdir) == .orderedSame {
                continue
            }
            
            // Count all other files and folders
            if let resourceValues = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) {
                if resourceValues.isDirectory == true || resourceValues.isRegularFile == true {
                    remainingItems.append(item)
                }
            }
        }
        
        return remainingItems
    }
}
