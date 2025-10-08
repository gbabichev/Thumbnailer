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
    /// Convert all suitable images under the given leaf folders to `.heic`.
    /// Uses HEICWriter and AppStorage quality setting.
    static func run(
        leaves: [URL],
        ignoreFolderName: String,
        quality: Double,
        log: @escaping @Sendable (String) -> Void
    ) async -> ConvertToHEICResult {
        var scanned = 0, converted = 0, skipped = 0

        // Snapshot main-actor–isolated constants and compute concurrency
        let ignored: Set<String> = await MainActor.run { Set(AppConstants.ignoredFileNames.map { $0.lowercased() }) }
        let photoExts: Set<String> = await MainActor.run { AppConstants.photoExts }
        let cpuCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let maxLeafConcurrent = max(1, cpuCount)         // parallel leaves (folders)
        let maxFileConcurrent = max(2, cpuCount)         // parallel files per leaf

        // Process multiple leaves in parallel (bounded), and within each leaf process files in parallel
        var leafIter = leaves.makeIterator()
        await withTaskGroup(of: Void.self) { group in
            func submitLeaf(_ leaf: URL) {
                group.addTask { @Sendable in
                    if Task.isCancelled { return }

                    // Verify directory
                    guard (try? leaf.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return }

                    await MainActor.run { scanned += 1 }

                    // List children
                    guard let children = try? FileManager.default.contentsOfDirectory(
                        at: leaf,
                        includingPropertiesForKeys: [.isRegularFileKey],
                        options: [.skipsHiddenFiles]
                    ) else { return }

                    let files = children
                        .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                        .filter { $0.lastPathComponent != ignoreFolderName }
                        .filter { !ignored.contains($0.lastPathComponent.lowercased()) }
                        .filter { photoExts.contains($0.pathExtension.lowercased()) }
                        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

                    if files.isEmpty { return }

                    await MainActor.run { log("📂 Processing: \(leaf.lastPathComponent)") }

                    // Bounded parallelism across FILES in this leaf
                    var fileIter = files.makeIterator()
                    await withTaskGroup(of: Void.self) { fileGroup in
                        func submitFile(_ file: URL) {
                            fileGroup.addTask { @Sendable in
                                if Task.isCancelled { return }

                                let ext = file.pathExtension.lowercased()
                                let base = file.deletingPathExtension().lastPathComponent
                                let destination = leaf.appendingPathComponent("\(base).heic")

                                // Skip if already .heic
                                if ext == "heic" {
                                    await MainActor.run { skipped += 1 }
                                    return
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
                                    try? FileManager.default.removeItem(at: file) // Remove original
                                    await MainActor.run {
                                        converted += 1
                                        log("  ✅ Converted: \(destination.lastPathComponent)")
                                    }
                                } catch {
                                    await MainActor.run { log("  ❌ Convert failed: \(file.lastPathComponent)") }
                                }
                            }
                        }

                        // Prime file workers
                        for _ in 0..<maxFileConcurrent {
                            if let f = fileIter.next() { submitFile(f) } else { break }
                        }
                        // Drain & refill
                        while await fileGroup.next() != nil {
                            if let f = fileIter.next() { submitFile(f) }
                        }
                    }
                }
            }

            // Prime leaf workers
            for _ in 0..<maxLeafConcurrent {
                if let leaf = leafIter.next() { submitLeaf(leaf) }
            }
            // Drain & refill
            while await group.next() != nil {
                if let leaf = leafIter.next() { submitLeaf(leaf) }
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

    /// Load image using ImageIO (preserves original size and applies EXIF orientation)
    private static func loadImage(from url: URL) async throws -> CGImage {
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .utility) {
                if Task.isCancelled { continuation.resume(throwing: ConvertError.cannotRead); return }

                let result = autoreleasepool { () -> CGImage? in
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                        return nil
                    }

                    // Load image at full resolution WITH automatic orientation correction
                    let options: [CFString: Any] = [
                        kCGImageSourceShouldCache: false,
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: Int.max  // Full size
                    ]

                    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                }

                guard let image = result else {
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
