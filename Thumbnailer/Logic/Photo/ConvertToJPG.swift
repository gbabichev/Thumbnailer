/*
 
 ConvertToJPG.swift
 Thumbnailer
 
  - Walk each leaf folder
  - Skip .jpg files (already correct)
  - Rename .jpeg/.JPG to .jpg (no re-encode)
  - Convert everything else to JPEG using JPEGWriter
  - Use quality from AppStorage
 
 George Babichev
 
 */

import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
import Accelerate

struct ConvertToJPGResult {
    let scannedFolders: Int
    let converted: Int
    let renamed: Int
    let skipped: Int
}

struct ConvertToJPG {
   
    /// Dedicated queue for decoding/alpha-strip to avoid QoS inversions from ImageIO/CoreGraphics internals
    private static let decodeQueue = DispatchQueue(
        label: "com.thumbnailer.decode",
        qos: .utility,
        attributes: .concurrent
    )

    /// Convert all suitable images under the given leaf folders to `.jpg`.
    /// Uses your existing JPEGWriter and AppStorage quality setting.
    static func run(
        leaves: [URL],
        ignoreFolderName: String,
        quality: Double,
        log: @escaping @Sendable (String) -> Void
    ) async -> ConvertToJPGResult {
        var scanned = 0, converted = 0, renamed = 0, skipped = 0
        let fileManager = FileManager.default

        // Snapshot main-actor isolated constants for use in concurrent contexts
        let ignored: Set<String> = await MainActor.run { Set(AppConstants.ignoredFileNames.map { $0.lowercased() }) }
        let renameable: Set<String> = await MainActor.run { Set(AppConstants.renameableJPEGExts.map { $0.lowercased() }) }

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
                .filter { !ignored.contains($0.lastPathComponent.lowercased()) }
                .filter { isImageFile($0) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

            if files.isEmpty { continue }
            
            await MainActor.run {
                log("📂 Processing: \(leaf.lastPathComponent)")
            }

            // Bounded concurrency across FILES within this leaf
            let cpu = max(1, ProcessInfo.processInfo.activeProcessorCount)
            let maxConcurrentFiles = max(2, cpu / 2) // leave headroom for I/O

            var it = files.makeIterator()
            await withTaskGroup(of: Void.self) { group in
                // Worker submitter
                func submit(_ file: URL) {
                    group.addTask { @Sendable in
                        if Task.isCancelled { return }

                        let ext = file.pathExtension.lowercased()
                        let base = file.deletingPathExtension().lastPathComponent
                        let destination = leaf.appendingPathComponent("\(base).jpg")

                        // Skip if already .jpg
                        if ext == "jpg" {
                            await MainActor.run { skipped += 1 }
                            return
                        }

                        // Fast rename for JPEG variants (no re-encode)
                        if renameable.contains(ext) || file.pathExtension == "JPG" {
                            do {
                                if FileManager.default.fileExists(atPath: destination.path) {
                                    try? FileManager.default.removeItem(at: destination)
                                }
                                try FileManager.default.moveItem(at: file, to: destination)
                                await MainActor.run {
                                    renamed += 1
                                    log("  📤 Renamed: \(destination.lastPathComponent)")
                                }
                            } catch {
                                await MainActor.run { log("  ❌ Rename failed: \(file.lastPathComponent)") }
                            }
                            return
                        }

                        // Convert other formats using JPEGWriter
                        do {
                            let image = try await loadImageWithoutAlpha(from: file)
                            try await JPEGWriter.write(
                                image: image,
                                to: destination,
                                quality: quality,
                                overwrite: true,
                                progressive: false
                            )
                            try? FileManager.default.removeItem(at: file)
                            await MainActor.run {
                                converted += 1
                                log("  ✅ Converted: \(destination.lastPathComponent)")
                            }
                        } catch {
                            await MainActor.run { log("  ❌ Convert failed: \(file.lastPathComponent)") }
                        }
                    }
                }

                // Prime the group
                for _ in 0..<maxConcurrentFiles {
                    if let f = it.next() { submit(f) }
                }
                // Drain & refill
                while await group.next() != nil {
                    if Task.isCancelled { break }
                    if let f = it.next() { submit(f) }
                }
            }
        }

        // Summary
        if converted == 0 && renamed == 0 {
            await MainActor.run {
                log("✅ All files are JPEG images (ignores applied).")
            }
        }

        return ConvertToJPGResult(
            scannedFolders: scanned,
            converted: converted,
            renamed: renamed,
            skipped: skipped
        )
    }
    
    // MARK: - Helpers
    
    /// Check if file is a supported image format
    private static func isImageFile(_ url: URL) -> Bool {
        guard let utType = UTType(filenameExtension: url.pathExtension) else { return false }
        return utType.conforms(to: .image)
    }
    
    /// Load image using ImageIO and strip alpha channel for JPEG conversion
    private static func loadImageWithoutAlpha(from url: URL) async throws -> CGImage {
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CGImage, Error>) in
            decodeQueue.async {
                if Task.isCancelled { cont.resume(throwing: ConvertError.cannotRead); return }
                do {
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                        throw ConvertError.cannotRead
                    }
                    guard let originalImage = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                        throw ConvertError.cannotRead
                    }

                    // If no alpha, return as-is
                    let alphaInfo = originalImage.alphaInfo
                    if alphaInfo == .none || alphaInfo == .noneSkipFirst || alphaInfo == .noneSkipLast {
                        cont.resume(returning: originalImage)
                        return
                    }

                    // Image has alpha — use vImage to drop alpha without triggering CoreGraphics compositing
                    let width = originalImage.width
                    let height = originalImage.height
                    let colorSpace = originalImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()

                    // Source buffer (force to RGBA8888 for a predictable input pixel layout)
                    var srcFormat = vImage_CGImageFormat(
                        bitsPerComponent: 8,
                        bitsPerPixel: 32,
                        colorSpace: Unmanaged.passUnretained(colorSpace),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                        version: 0,
                        decode: nil,
                        renderingIntent: .defaultIntent
                    )
                    var srcBuffer = vImage_Buffer()
                    var error = vImageBuffer_InitWithCGImage(
                        &srcBuffer,
                        &srcFormat,
                        nil,
                        originalImage,
                        vImage_Flags(kvImageNoFlags)
                    )
                    if error != kvImageNoError { throw ConvertError.cannotCreateContext }
                    defer { free(srcBuffer.data) }

                    // Destination buffer (RGB888, no alpha)
                    var dstFormat = vImage_CGImageFormat(
                        bitsPerComponent: 8,
                        bitsPerPixel: 24,
                        colorSpace: Unmanaged.passUnretained(colorSpace),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                        version: 0,
                        decode: nil,
                        renderingIntent: .defaultIntent
                    )
                    var dstBuffer = vImage_Buffer()
                    error = vImageBuffer_Init(
                        &dstBuffer,
                        vImagePixelCount(height),
                        vImagePixelCount(width),
                        24,
                        vImage_Flags(kvImageNoFlags)
                    )
                    if error != kvImageNoError { throw ConvertError.cannotCreateContext }

                    var shouldFreeDst = true
                    defer { if shouldFreeDst { free(dstBuffer.data) } }

                    // Convert RGBA8888 → RGB888
                    error = vImageConvert_RGBA8888toRGB888(&srcBuffer, &dstBuffer, vImage_Flags(kvImageNoFlags))
                    if error != kvImageNoError { throw ConvertError.cannotCreateImage }

                    // Create CGImage from destination buffer without copying when possible
                    var createError: vImage_Error = kvImageNoError
                    let maybeCG = vImageCreateCGImageFromBuffer(
                        &dstBuffer,
                        &dstFormat,
                        nil,
                        nil,
                        vImage_Flags(kvImageNoAllocate),
                        &createError
                    )

                    if let cg = maybeCG?.takeRetainedValue(), createError == kvImageNoError {
                        shouldFreeDst = false
                        cont.resume(returning: cg)
                    } else {
                        // Fallback: allocate new image if no‑allocate path failed
                        let fallback = vImageCreateCGImageFromBuffer(
                            &dstBuffer,
                            &dstFormat,
                            nil,
                            nil,
                            vImage_Flags(kvImageNoFlags),
                            &createError
                        )
                        guard let cg = fallback?.takeRetainedValue(), createError == kvImageNoError else {
                            throw ConvertError.cannotCreateImage
                        }
                        cont.resume(returning: cg)
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}

// Simple error type
private enum ConvertError: Error {
    case cannotRead
    case cannotCreateContext
    case cannotCreateImage
}
    
