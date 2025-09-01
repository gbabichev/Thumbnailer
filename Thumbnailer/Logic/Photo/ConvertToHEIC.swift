/*
 
 ConvertToHEIC.swift
 Thumbnailer
 
  - Walk each leaf folder
  - Skip .heic files (already correct)
  - Convert everything else to HEIC using HEICWriter
  - Use quality from AppStorage
 
 George Babichev
 
 */

import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

struct ConvertToHEICResult {
    let scannedFolders: Int
    let converted: Int
    let skipped: Int
}

struct ConvertToHEIC {
    /// Filenames to ignore (case-insensitive)
    private static let ignoredNames = AppConstants.ignoredFileNames
    
    /// Convert all suitable images under the given leaf folders to `.heic`.
    /// Uses HEICWriter and AppStorage quality setting.
    static func run(
        leaves: [URL],
        ignoreFolderName: String,
        quality: Double,
        log: @escaping (String) -> Void
    ) async -> ConvertToHEICResult {
        var scanned = 0, converted = 0, skipped = 0
        let fileManager = FileManager.default

        for leaf in leaves {
            guard (try? leaf.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            scanned += 1
            
            guard let children = try? fileManager.contentsOfDirectory(
                at: leaf,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            let files = children
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .filter { $0.lastPathComponent != ignoreFolderName }
                .filter { !ignoredNames.contains($0.lastPathComponent.lowercased()) }
                .filter { isImageFile($0) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

            if files.isEmpty { continue }
            
            await MainActor.run {
                log("📂 Processing: \(leaf.lastPathComponent)")
            }

            for file in files {
                let ext = file.pathExtension.lowercased()
                let base = file.deletingPathExtension().lastPathComponent
                let destination = leaf.appendingPathComponent("\(base).heic")

                // Skip if already .heic
                if ext == "heic" {
                    skipped += 1
                    continue
                }

                // Convert to HEIC using HEICWriter
                do {
                    let image = try await loadImage(from: file)
                    try await HEICWriter.write(
                        image: image,
                        to: destination,
                        quality: quality,
                        overwrite: true
                    )
                    try? fileManager.removeItem(at: file) // Remove original
                    converted += 1
                    await MainActor.run {
                        log("  ✅ Converted: \(destination.lastPathComponent)")
                    }
                } catch {
                    await MainActor.run {
                        log("  ❌ Convert failed: \(file.lastPathComponent)")
                    }
                }
            }
        }

        // Summary
        if converted == 0 {
            await MainActor.run {
                log("✅ All files are HEIC images (ignores applied).")
            }
        }

        return ConvertToHEICResult(
            scannedFolders: scanned,
            converted: converted,
            skipped: skipped
        )
    }
    
    // MARK: - Helpers
    
    /// Check if file is a supported image format
    private static func isImageFile(_ url: URL) -> Bool {
        guard let utType = UTType(filenameExtension: url.pathExtension) else { return false }
        return utType.conforms(to: .image)
    }
    
    /// Load image using ImageIO (preserves original size)
    private static func loadImage(from url: URL) async throws -> CGImage {
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    continuation.resume(throwing: ConvertError.cannotRead)
                    return
                }
                
                // Load image at full resolution
                guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                    continuation.resume(throwing: ConvertError.cannotRead)
                    return
                }
                
                continuation.resume(returning: image)
            }
        }
    }
}

// Simple error type
private enum ConvertError: Error {
    case cannotRead
}
