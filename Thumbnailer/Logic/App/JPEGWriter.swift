/*
 
 JPEGWriter.swift
 Thumbnailer
 
 Handles creating JPG files.
 
 George Babichev
 
 */

@preconcurrency import Foundation
@preconcurrency import CoreGraphics
@preconcurrency import ImageIO
@preconcurrency import UniformTypeIdentifiers

enum JPEGWriterError: Error {
    case destinationCreateFailed
    case finalizeFailed
}

enum JPEGWriter {
    
    /// Serial queue with userInitiated QoS for ImageIO write operations to avoid priority inversions
    private static let writeQueue = DispatchQueue(
        label: "com.thumbnailer.jpegwriter",
        qos: .utility,
        target: nil
    )
    
    /// Atomically writes a JPEG next to `to` (forces `.jpg`), creating folders as needed.
    /// - Parameters:
    ///   - image: CGImage to encode.
    ///   - to: Desired output URL (extension will be replaced with `.jpg`).
    ///   - quality: 0.0...1.0 (recommended 0.7–0.95).
    ///   - overwrite: Remove existing file if present before move.
    ///   - progressive: Set true for progressive JPEGs (slightly larger, nicer over slow loads).
    ///   - metadata: Optional CGImageProperties-style dictionary (e.g., EXIF, orientation).
    static func write(
        image: CGImage,
        to url: URL,
        quality: Double,
        overwrite: Bool = true,
        progressive: Bool = false,
    ) async throws {
        // For now, ignore metadata in async version to avoid Sendable issues
        // Can be added back when Swift Concurrency is more mature for CF types
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async {
                do {
                    // Ensure parent dir exists
                    let fm = FileManager.default
                    if !fm.fileExists(atPath: url.deletingLastPathComponent().path) {
                        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    }

                    // Normalize to .jpg
                    let finalURL = url.deletingPathExtension().appendingPathExtension("jpg")

                    // Write atomically via temp file, then move
                    let tmpURL = finalURL
                        .deletingLastPathComponent()
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension("jpg")

                    guard let dest = CGImageDestinationCreateWithURL(tmpURL as CFURL,
                                                                     UTType.jpeg.identifier as CFString,
                                                                     1,
                                                                     nil) else {
                        continuation.resume(throwing: JPEGWriterError.destinationCreateFailed)
                        return
                    }
                    
                    // Clamp the quality between 0-1
                    let q = max(0, min(1, quality))
                    
                    var props: [CFString: Any] = [
                        kCGImageDestinationLossyCompressionQuality: CGFloat(q)
                    ]

                    if progressive {
                        props[kCGImagePropertyJFIFDictionary] = [
                            kCGImagePropertyJFIFIsProgressive: true
                        ] as CFDictionary
                    }

                    // Note: metadata parameter is ignored in async version to avoid Sendable issues
                    // Use writeSync if you need metadata support

                    CGImageDestinationAddImage(dest, image, props as CFDictionary)
                    guard CGImageDestinationFinalize(dest) else {
                        try? fm.removeItem(at: tmpURL)
                        continuation.resume(throwing: JPEGWriterError.finalizeFailed)
                        return
                    }

                    if overwrite, fm.fileExists(atPath: finalURL.path) {
                        try? fm.removeItem(at: finalURL)
                    }
                    
                    try fm.moveItem(at: tmpURL, to: finalURL)
                    continuation.resume(returning: ())
                    
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
