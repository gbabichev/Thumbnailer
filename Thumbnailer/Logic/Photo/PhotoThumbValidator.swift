/*
 
 PhotoThumbValidator.swift
 Thumbnailer
 
   Purpose: Compare photo counts vs thumbnail counts in leaf folders
   to identify sync issues between originals and generated thumbnails.

 George Babichev
 
 */

import Foundation

struct PhotoThumbValidationResult: Sendable {
    let leafURL: URL
    let photoCount: Int
    let thumbCount: Int
    let isMatch: Bool
    
    nonisolated init(leafURL: URL, photoCount: Int, thumbCount: Int) {
        self.leafURL = leafURL
        self.photoCount = photoCount
        self.thumbCount = thumbCount
        self.isMatch = (photoCount == thumbCount)
    }
    
    var displayName: String {
        leafURL.lastPathComponent
    }
    
    var summaryLine: String {
        "\(displayName): \(photoCount) images, \(thumbCount) thumbs"
    }
}

enum PhotoThumbValidator {
    /// Default photo extensions to count (matches PhotoSheetComposer)
    static let defaultPhotoExts: Set<String> = [
        "jpg", "jpeg", "png", "heic", "tif", "tiff", "bmp", "gif", "webp"
    ]
    
    /// Skipped filenames (case-insensitive, matches PhotoThumbnailer)
    static let defaultSkipSubstrings: [String] = ["db", "DS_Store", "dump"]
    
    /// Validates photo vs thumb counts for multiple leaf folders
    /// - Parameters:
    ///   - leafs: Array of leaf folder URLs to validate
    ///   - thumbFolderName: Name of the thumbnail subfolder (e.g., "thumb")
    ///   - photoExtensions: Photo file extensions to count
    ///   - skipSubstrings: Filename substrings to ignore (case-insensitive)
    ///   - appendLog: Logging callback for progress updates
    /// - Returns: Array of validation results
    static func validateLeafFolders(
        leafs: [URL],
        thumbFolderName: String,
        photoExtensions: Set<String> = defaultPhotoExts,
        skipSubstrings: [String] = defaultSkipSubstrings,
        appendLog: @escaping @Sendable (String) -> Void
    ) async -> [PhotoThumbValidationResult] {
        var results: [PhotoThumbValidationResult] = []
        results.reserveCapacity(leafs.count)

        // Precompute lowercase skips for faster checks in workers
        let lowerSkips = skipSubstrings.map { $0.lowercased() }

        // Bounded concurrency across leaf folders
        let cpuCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let maxConcurrent = max(2, cpuCount) // I/O-bound: allow up to CPU count

        // Iterator over leafs so we can window the concurrency
        var it = Array(leafs.enumerated()).makeIterator()

        await withTaskGroup(of: Void.self) { group in
            // Submit a single leaf for validation
            func submit(index: Int, leaf: URL) {
                group.addTask { @Sendable in
                    if Task.isCancelled { return }
                    // Log start
                    await MainActor.run { appendLog("🔍 Validating: \(leaf.lastPathComponent)") }

                    // Perform counts (sync, fast I/O)
                    let photoCount = countPhotos(
                        in: leaf,
                        extensions: photoExtensions,
                        skipSubstrings: lowerSkips
                    )
                    let thumbCount = countThumbnails(
                        in: leaf,
                        thumbFolderName: thumbFolderName
                    )
                    if Task.isCancelled { return }

                    let result = PhotoThumbValidationResult(
                        leafURL: leaf,
                        photoCount: photoCount,
                        thumbCount: thumbCount
                    )

                    // Append result and log summary on MainActor to avoid data races
                    await MainActor.run {
                        results.append(result)
                        let status = result.isMatch ? "✅" : "⚠️"
                        appendLog("  \(status) \(result.summaryLine)")
                    }
                }
            }

            // Prime the group
            for _ in 0..<maxConcurrent {
                if Task.isCancelled { break } else if let (i, leaf) = it.next() { submit(index: i, leaf: leaf) } else { break }
            }
            // Drain & refill
            while await group.next() != nil {
                if Task.isCancelled { break }
                if Task.isCancelled { break } else if let (i, leaf) = it.next() { submit(index: i, leaf: leaf) }
            }
        }

        return results
    }
    
    /// Count photo files in the leaf folder (excluding thumb subfolder)
    nonisolated private static func countPhotos(
        in leafURL: URL,
        extensions: Set<String>,
        skipSubstrings: [String]
    ) -> Int {
        let fm = FileManager.default
        
        guard let items = try? fm.contentsOfDirectory(
            at: leafURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        
        var count = 0
        for item in items {
            // Skip non-regular files
            guard (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            
            // Skip files with ignored substrings (case-insensitive)
            let filename = item.lastPathComponent
            if skipSubstrings.contains(where: { filename.localizedCaseInsensitiveContains($0) }) {
                continue
            }
            
            // Check if it's a photo by extension
            let ext = item.pathExtension.lowercased()
            if extensions.contains(ext) {
                count += 1
            }
        }
        
        return count
    }
    
    /// Count thumbnail files in the thumb subfolder
    nonisolated private static func countThumbnails(
        in leafURL: URL,
        thumbFolderName: String
    ) -> Int {
        let fm = FileManager.default
        let thumbURL = leafURL.appendingPathComponent(thumbFolderName, isDirectory: true)
        
        // Check if thumb folder exists
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: thumbURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return 0
        }
        
        guard let items = try? fm.contentsOfDirectory(
            at: thumbURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        
        // Count all regular files in thumb folder (should be JPEGs)
        var count = 0
        for item in items {
            if (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                count += 1
            }
        }
        
        return count
    }
    
    /// Generate a summary report from validation results
    static func generateSummary(
        from results: [PhotoThumbValidationResult]
    ) -> (goodCount: Int, mismatchCount: Int, summaryText: String) {
        let goodCount = results.filter(\.isMatch).count
        let mismatchCount = results.count - goodCount
        
        let summaryText: String
        if mismatchCount == 0 {
            summaryText = "All \(goodCount) folders have matching photo/thumbnail counts! 🎉"
        } else {
            summaryText = "\(goodCount) good folders, \(mismatchCount) mismatch\(mismatchCount == 1 ? "" : "es")"
        }
        
        return (goodCount, mismatchCount, summaryText)
    }
}
