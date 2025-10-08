//
//  ScanHEIC.swift
//  Thumbnailer
//
//  Created by George Babichev on 8/23/25.
//


//  ScanHEIC.swift
//  Thumbnail Generator — Tools ▸ Scan HEIC
//
//  Created 2025-01-XX
//
//  Purpose: Recursively scan a directory (or each "leaf" folder in the app)
//  and report any files that are NOT HEIC images, while honoring an ignore list.
//  Mirrors the behavior of ScanJPG but for HEIC format detection.
//
//  Notes
//  - HEIC detection by extension: .heic/.heif (case-insensitive)
//  - Optional header ("magic") check: HEIC files start with specific ftyp box signatures
//  - Exposes small, pure functions plus a convenience UI hook you can call
//    from your SwiftUI view (scanHEICAction).
//

import Foundation
import UniformTypeIdentifiers
import SwiftUI

enum ScanHEIC {
    /// Default ignored file names (case-sensitive, like the Python version).
    static let defaultIgnore = AppConstants.ignoredFileNames

    /// Return true if the URL has a HEIC-like extension.
    @inline(__always)
    static func isHeicByExtension(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "heic" || ext == "heif"
    }

    /// Return true if the file begins with HEIC file signature.
    /// HEIC files are ISO Base Media File Format containers that start with:
    /// - 4 bytes: box size
    /// - 4 bytes: "ftyp" (file type box)
    /// - 4 bytes: major brand (e.g., "heic", "mif1")
    static func isHeicByMagic(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        
        do {
            let data: Data
            if #available(macOS 13.0, *) {
                data = try fh.read(upToCount: 12) ?? Data()
            } else {
                data = fh.readData(ofLength: 12)
            }
            
            // Need at least 12 bytes to check HEIC signature
            guard data.count >= 12 else { return false }
            
            // Check for "ftyp" at bytes 4-7
            let ftypBytes = data.subdata(in: 4..<8)
            guard String(data: ftypBytes, encoding: .ascii) == "ftyp" else { return false }
            
            // Check for HEIC-related major brands at bytes 8-11
            let majorBrand = data.subdata(in: 8..<12)
            if let brandString = String(data: majorBrand, encoding: .ascii) {
                let heicBrands = ["heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs", "mif1", "msf1"]
                return heicBrands.contains(brandString)
            }
            
            return false
        } catch {
            return false
        }
    }

    /// Recursively walk `root` and return files that are not HEIC images (and not ignored).
    /// - Parameters:
    ///   - root: Folder to scan.
    ///   - ignore: Set of exact file names to always skip.
    ///   - checkMagic: If true, verify HEIC by header bytes in addition to extension.
    ///   - skipHiddenDirectories: If true, skip directories beginning with ".".
    static func scan(
        root: URL,
        ignore: Set<String> = defaultIgnore,
        checkMagic: Bool = false,
        skipHiddenDirectories: Bool = false
    ) -> [URL] {
        var nonHeics: [URL] = []
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isHiddenKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        for case let url as URL in enumerator {
            if skipHiddenDirectories,
               let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey]),
               vals.isDirectory == true,
               vals.isHidden == true,
               url != root {
                enumerator.skipDescendants()
                continue
            }

            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile != true { continue }

            if ignore.contains(url.lastPathComponent) { continue }

            // Only check image files to avoid reporting non-image files as "non-HEIC"
            if !looksLikeImageFile(url) { continue }

            if !isHeicByExtension(url) {
                nonHeics.append(url)
                continue
            }

            if checkMagic && !isHeicByMagic(url) {
                nonHeics.append(url)
            }
        }

        return nonHeics
    }

    /// Check if a file looks like an image file based on extension
    private static func looksLikeImageFile(_ url: URL) -> Bool {
        return AppConstants.photoExts.contains(url.pathExtension.lowercased())
    }

    /// Scan multiple leaf folders. Returns a mapping of leaf -> non-HEIC list.
    static func scanLeafFolders(
        _ leaves: [URL],
        ignore: Set<String> = defaultIgnore,
        checkMagic: Bool = false
    ) async -> [URL: [URL]] {
        var out: [URL: [URL]] = [:]
        for leaf in leaves {
            let bad = await Task(priority: .userInitiated) {
                ScanHEIC.scan(root: leaf, ignore: ignore, checkMagic: checkMagic)
            }.value
            out[leaf] = bad
        }
        return out
    }
}
