//
//  IdentifyNonMP4Videos.swift
//  Thumbnailer
//
//  Created by George Babichev on 8/18/25.
//


/*
 
 IdentifyNonMP4Videos.swift
 Thumbnailer
 
 Identifies video files that are NOT in MP4 format.
 Useful for finding videos that might need conversion or special handling.
 
 George Babichev
 
 */

import Foundation

enum IdentifyNonMP4Videos {
    
    /// Default video extensions (includes both supported and unsupported formats)
    static let allVideoExts = AppConstants.allVideoExts
    
    /// Video information structure
    struct VideoInfo: Sendable {
        let url: URL
        let fileExtension: String
        let isSupported: Bool
        let fileSizeBytes: Int64
        
        init(url: URL) {
            self.url = url
            self.fileExtension = url.pathExtension.lowercased()
            self.isSupported = AppConstants.videoExts.contains(self.fileExtension)
            
            // Get file size
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                self.fileSizeBytes = attributes[.size] as? Int64 ?? 0
            } catch {
                self.fileSizeBytes = 0
            }
        }
        
        var fileSizeString: String {
            if fileSizeBytes < 1024 {
                return "\(fileSizeBytes) bytes"
            } else if fileSizeBytes < 1024 * 1024 {
                return String(format: "%.1f KB", Double(fileSizeBytes) / 1024.0)
            } else if fileSizeBytes < 1024 * 1024 * 1024 {
                return String(format: "%.1f MB", Double(fileSizeBytes) / (1024.0 * 1024.0))
            } else {
                return String(format: "%.1f GB", Double(fileSizeBytes) / (1024.0 * 1024.0 * 1024.0))
            }
        }
    }
    
    /// Kicks off a scan on a background thread, then logs results on the main actor.
    ///
    /// - Parameters:
    ///   - leafs: Array of leaf folder URLs to scan (non-recursive).
    ///   - ignoreFolderNames: Optional set of folder names to ignore if you accidentally pass non-leafs.
    ///                         (e.g., your thumbs folder name). Default empty.
    ///   - includeHidden: Whether to scan hidden files (dotfiles). Default false.
    ///   - allowedExtensions: Video file extensions to scan. Default `allVideoExts`.
    ///   - appendLog: Your app's logger (e.g. `appendLog(_:)`).
    static func runScan(
        leafs: [URL],
        ignoreFolderNames: Set<String> = [],
        includeHidden: Bool = false,
        allowedExtensions: Set<String> = allVideoExts,
        appendLog: @escaping (String) -> Void
    ) {
        // Off-main work
        Task(priority: .userInitiated) {
            let nonMP4Videos = await identifyNonMP4Videos(
                leafs: leafs,
                ignoreFolderNames: ignoreFolderNames,
                includeHidden: includeHidden,
                allowedExtensions: allowedExtensions
            )
            
            // Back to main for UI/log
            await MainActor.run {
                appendLog("🎬 Scanned videos, found \(nonMP4Videos.count) non-MP4 video files.")
                
                if nonMP4Videos.isEmpty {
                    appendLog("✅ All video files are in MP4 format.")
                } else {
                    // Group by extension for better organization
                    let groupedByExt = Dictionary(grouping: nonMP4Videos) { $0.fileExtension }
                    let sortedExtensions = groupedByExt.keys.sorted()
                    
                    for ext in sortedExtensions {
                        let videos = groupedByExt[ext]!.sorted { $0.url.path < $1.url.path }
                        let supportedMarker = AppConstants.videoExts.contains(ext) ? "✅" : "❌"
                        
                        appendLog("")
                        appendLog("\(supportedMarker) .\(ext.uppercased()) files (\(videos.count)):")
                        
                        for videoInfo in videos {
                            let sizeInfo = videoInfo.fileSizeBytes > 0 ? " (\(videoInfo.fileSizeString))" : ""
                            appendLog("     📹 \(videoInfo.url.path)\(sizeInfo)")
                        }
                    }
                    
                    // Summary
                    let totalSize = nonMP4Videos.reduce(0) { $0 + $1.fileSizeBytes }
                    let totalSizeString = formatFileSize(totalSize)
                    
                    appendLog("")
                    appendLog("📊 Summary:")
                    appendLog("   • Total non-MP4 videos: \(nonMP4Videos.count)")
                    appendLog("   • Total size: \(totalSizeString)")
                    
                    // Show breakdown by support status
                    let supported = nonMP4Videos.filter { $0.isSupported }
                    let unsupported = nonMP4Videos.filter { !$0.isSupported }
                    
                    if !supported.isEmpty {
                        appendLog("   • Supported formats: \(supported.count) files")
                    }
                    if !unsupported.isEmpty {
                        appendLog("   • Unsupported formats: \(unsupported.count) files")
                        appendLog("   • Supported formats: \(AppConstants.supportedVideoFormatsString)")
                    }
                }
            }
        }
    }
    
    /// Pure function that returns video info for videos that are NOT in MP4 format.
    static func identifyNonMP4Videos(
        leafs: [URL],
        ignoreFolderNames: Set<String> = [],
        includeHidden: Bool = false,
        allowedExtensions: Set<String> = allVideoExts
    ) async -> [VideoInfo] {
        let fm = FileManager.default
        var nonMP4Videos: [VideoInfo] = []
        
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
            
            // Filter for non-MP4 videos
            for videoURL in videos {
                let ext = videoURL.pathExtension.lowercased()
                if ext != "mp4" {
                    let videoInfo = VideoInfo(url: videoURL)
                    nonMP4Videos.append(videoInfo)
                }
            }
        }
        
        // Sort by path for consistent ordering
        return nonMP4Videos.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
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
    
    /// Format file size in human-readable format
    private static func formatFileSize(_ bytes: Int64) -> String {
        if bytes < 1024 {
            return "\(bytes) bytes"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else if bytes < 1024 * 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
        } else {
            return String(format: "%.1f GB", Double(bytes) / (1024.0 * 1024.0 * 1024.0))
        }
    }
}
