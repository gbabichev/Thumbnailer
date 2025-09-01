/*
 
 IdentifyLowFiles.swift
 Thumbnailer
 
  Scans photo leaf folders and identifies those with fewer than N images.

 George Babichev
 
 */

import Foundation

enum IdentityLowFiles {

    /// Allowed image extensions (lowercased, no dot). Tweak as needed.
    static let defaultImageExts: Set<String> = [
        "jpg", "jpeg", "png", "heic", "tif", "tiff", "gif", "bmp", "webp"
    ]

    /// Kicks off a scan on a background thread, then logs results on the main actor.
    ///
    /// - Parameters:
    ///   - leafs: Array of leaf folder URLs to scan (non-recursive).
    ///   - minCount: Threshold; folders with fewer than this number of images are flagged. Default 5.
    ///   - ignoreFolderNames: Optional set of folder names to ignore if you accidentally pass non-leafs.
    ///                         (e.g., your thumbs folder name). Default empty.
    ///   - includeHidden: Whether to count hidden files (dotfiles). Default false.
    ///   - allowedExtensions: Image file extensions to count. Default `defaultImageExts`.
    ///   - appendLog: Your app’s logger (e.g. `appendLog(_:)`).
    static func runScan(
        leafs: [URL],
        minCount: Int = 5,
        ignoreFolderNames: Set<String> = [],
        includeHidden: Bool = false,
        allowedExtensions: Set<String> = defaultImageExts,
        appendLog: @escaping (String) -> Void
    ) {
        // Off-main work
        Task(priority: .userInitiated) {
            let lowLeafs = identifyLowImageLeafs(
                leafs: leafs,
                minCount: minCount,
                ignoreFolderNames: ignoreFolderNames,
                includeHidden: includeHidden,
                allowedExtensions: allowedExtensions
            )

            // Back to main for UI/log
            await MainActor.run {
                appendLog("ℹ️ Scanned leafs, found \(lowLeafs.count) folders with less than \(minCount) images.")
                for url in lowLeafs {
                    appendLog("     ⚠️ \(url.path)")
                }
            }
        }
    }

    /// Pure function that returns the subset of leaf URLs with fewer than `minCount` images.
    static func identifyLowImageLeafs(
        leafs: [URL],
        minCount: Int,
        ignoreFolderNames: Set<String> = [],
        includeHidden: Bool = false,
        allowedExtensions: Set<String> = defaultImageExts
    ) -> [URL] {
        guard minCount > 0 else { return [] }

        let fm = FileManager.default
        var flagged: [URL] = []
        flagged.reserveCapacity(leafs.count / 4)

        for leaf in leafs {
            // Skip by name if requested
            if ignoreFolderNames.contains(leaf.lastPathComponent) { continue }

            // Safety: only handle existing directories
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: leaf.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let count = imageCount(
                in: leaf,
                includeHidden: includeHidden,
                allowedExtensions: allowedExtensions
            )

            if count < minCount {
                flagged.append(leaf)
            }
        }

        return flagged
    }

    /// Counts image files directly inside `folder` (non-recursive).
    private static func imageCount(
        in folder: URL,
        includeHidden: Bool,
        allowedExtensions: Set<String>
    ) -> Int {
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
            return 0
        }

        var total = 0
        for case let item as URL in enumerator {
            // We asked to skip subdirectories; still, double-check and only count regular files.
            if let isRegular = try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
               isRegular == true
            {
                if isAllowedImage(url: item, allowedExtensions: allowedExtensions) {
                    total &+= 1
                }
            }
        }
        return total
    }

    /// Checks extension (case-insensitive) against allowed set.
    private static func isAllowedImage(url: URL, allowedExtensions: Set<String>) -> Bool {
        let ext = url.pathExtension.lowercased()
        return allowedExtensions.contains(ext)
    }
}
