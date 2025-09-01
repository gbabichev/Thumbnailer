/*
 
 IdentifyShortVideos.swift
 Thumbnailer
 
 Identifies and logs short videos.
 
 George Babichev
 
 */

import Foundation
import AVFoundation

enum IdentifyShortVideos {
    
    /// Default video extensions (lowercased, no dot). Matches VideoContactSheets.
    static let defaultVideoExts = AppConstants.videoExts
    
    /// Kicks off a scan on a background thread, then logs results on the main actor.
    ///
    /// - Parameters:
    ///   - leafs: Array of leaf folder URLs to scan (non-recursive).
    ///   - maxDurationSeconds: Threshold; videos shorter than this duration are flagged. Default 120 (2 minutes).
    ///   - ignoreFolderNames: Optional set of folder names to ignore if you accidentally pass non-leafs.
    ///                         (e.g., your thumbs folder name). Default empty.
    ///   - includeHidden: Whether to scan hidden files (dotfiles). Default false.
    ///   - allowedExtensions: Video file extensions to scan. Default `defaultVideoExts`.
    ///   - appendLog: Your app's logger (e.g. `appendLog(_:)`).
    static func runScan(
        leafs: [URL],
        maxDurationSeconds: Double = 120.0,
        ignoreFolderNames: Set<String> = [],
        includeHidden: Bool = false,
        allowedExtensions: Set<String> = defaultVideoExts,
        appendLog: @escaping (String) -> Void
    ) {
        // Off-main work
        Task(priority: .userInitiated) {
            let shortVideos = await identifyShortVideos(
                leafs: leafs,
                maxDurationSeconds: maxDurationSeconds,
                ignoreFolderNames: ignoreFolderNames,
                includeHidden: includeHidden,
                allowedExtensions: allowedExtensions
            )
            
            // Back to main for UI/log
            await MainActor.run {
                let maxMinutes = maxDurationSeconds / 60.0
                appendLog("  ℹ️ Scanned videos, found \(shortVideos.count) videos shorter than \(String(format: "%.1f", maxMinutes)) minutes.")
                
                if shortVideos.isEmpty {
                    appendLog("No short videos found.")
                } else {
                    for videoInfo in shortVideos {
                        let durationStr = formatDuration(videoInfo.duration)
                        appendLog("     ⚠️\(videoInfo.url.path) (\(durationStr))")
                    }
                }
            }
        }
    }
    
    /// Pure function that returns video info for videos shorter than `maxDurationSeconds`.
    static func identifyShortVideos(
        leafs: [URL],
        maxDurationSeconds: Double,
        ignoreFolderNames: Set<String> = [],
        includeHidden: Bool = false,
        allowedExtensions: Set<String> = defaultVideoExts
    ) async -> [(url: URL, duration: Double)] {
        guard maxDurationSeconds > 0 else { return [] }
        
        let fm = FileManager.default
        var shortVideos: [(url: URL, duration: Double)] = []
        
        for leaf in leafs {
            // Skip by name if requested
            if ignoreFolderNames.contains(leaf.lastPathComponent) { continue }
            
            // Safety: only handle existing directories
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: leaf.path, isDirectory: &isDir), isDir.boolValue else { continue }
            
            let videos = findVideos(
                in: leaf,
                includeHidden: includeHidden,
                allowedExtensions: allowedExtensions
            )
            
            // Check duration for each video
            for videoURL in videos {
                if let duration = await getVideoDuration(videoURL) {
                    if duration < maxDurationSeconds {
                        shortVideos.append((url: videoURL, duration: duration))
                    }
                }
            }
        }
        
        // Sort by duration (shortest first)
        return shortVideos.sorted { $0.duration < $1.duration }
    }
    
    // MARK: - Private Helpers
    
    /// Find video files directly inside `folder` (non-recursive).
    private static func findVideos(
        in folder: URL,
        includeHidden: Bool,
        allowedExtensions: Set<String>
    ) -> [URL] {
        let fm = FileManager.default
        
        // Enumerator set to skip subfolders; we only care about immediate files in each leaf.
        var options: FileManager.DirectoryEnumerationOptions = [
            .skipsSubdirectoryDescendants,
            .skipsPackageDescendants
        ]
        if !includeHidden {
            options.insert(.skipsHiddenFiles)
        }
        
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isHiddenKey, .nameKey, .typeIdentifierKey]
        
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: options
        ) else {
            return []
        }
        
        var videos: [URL] = []
        for case let item as URL in enumerator {
            // We asked to skip subdirectories; still, double-check and only count regular files.
            if let isRegular = try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
               isRegular == true
            {
                if isAllowedVideo(url: item, allowedExtensions: allowedExtensions) {
                    videos.append(item)
                }
            }
        }
        return videos
    }
    
    /// Checks extension (case-insensitive) against allowed set.
    private static func isAllowedVideo(url: URL, allowedExtensions: Set<String>) -> Bool {
        let ext = url.pathExtension.lowercased()
        return allowedExtensions.contains(ext)
    }
    
    /// Get video duration using AVFoundation
    private static func getVideoDuration(_ url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            return seconds.isFinite && seconds > 0 ? seconds : nil
        } catch {
            return nil
        }
    }
    
    /// Format duration in seconds to a human-readable string
    private static func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        } else {
            let minutes = Int(seconds / 60)
            let remainingSeconds = seconds.truncatingRemainder(dividingBy: 60)
            return String(format: "%dm %.1fs", minutes, remainingSeconds)
        }
    }
}
