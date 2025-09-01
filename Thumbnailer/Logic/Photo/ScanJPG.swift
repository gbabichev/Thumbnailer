//  ScanJPG.swift
//  Thumbnail Generator — Tools ▸ Scan JPG
//
//  Created 2025-08-13
//
//  Purpose: Recursively scan a directory (or each “leaf” folder in the app)
//  and report any files that are NOT JPEG images, while honoring an ignore list.
//  Mirrors the behavior of the provided Python script but in Swift.
//
//  Notes
//  - JPEG detection by extension: .jpg/.jpeg (case-insensitive)
//  - Optional header (“magic”) check: first two bytes 0xFF 0xD8
//  - Exposes small, pure functions plus a convenience UI hook you can call
//    from your SwiftUI view (scanJPGAction).
//

import Foundation
import UniformTypeIdentifiers
import SwiftUI

enum ScanJPG {
    /// Default ignored file names (case-sensitive, like the Python version).

    static let defaultIgnore = AppConstants.ignoredFileNames

    //nonisolated public static let defaultIgnore: Set<String> = [".DS_Store", ".dump"]

    /// Return true if the URL has a JPEG-like extension.
    @inline(__always)
    static func isJpegByExtension(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "jpg" || ext == "jpeg"
    }

    /// Return true if the file begins with JPEG SOI marker (0xFF 0xD8).
    static func isJpegByMagic(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        do {
            if #available(macOS 13.0, *) {
                let data = try fh.read(upToCount: 2) ?? Data()
                return data.count == 2 && data[0] == 0xFF && data[1] == 0xD8
            } else {
                let data = fh.readData(ofLength: 2)
                return data.count == 2 && data[0] == 0xFF && data[1] == 0xD8
            }
        } catch {
            return false
        }
    }

    /// Recursively walk `root` and return files that are not JPEGs (and not ignored).
    /// - Parameters:
    ///   - root: Folder to scan.
    ///   - ignore: Set of exact file names to always skip.
    ///   - checkMagic: If true, verify JPEG by header bytes in addition to extension.
    ///   - skipHiddenDirectories: If true, skip directories beginning with ".".
    static func scan(
        root: URL,
        ignore: Set<String> = defaultIgnore,
        checkMagic: Bool = false,
        skipHiddenDirectories: Bool = false
    ) -> [URL] {
        var nonJpegs: [URL] = []
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

            if !isJpegByExtension(url) {
                nonJpegs.append(url)
                continue
            }

            if checkMagic && !isJpegByMagic(url) {
                nonJpegs.append(url)
            }
        }

        return nonJpegs
    }
}
