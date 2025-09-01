/*
 
 HEICWriter.swift
 Thumbnailer
 
 Handles creating HEIC files.
 
 George Babichev
 
 */

@preconcurrency import Foundation
@preconcurrency import CoreGraphics
@preconcurrency import ImageIO
@preconcurrency import UniformTypeIdentifiers

enum HEICWriterError: Error {
    case destinationCreateFailed
    case finalizeFailed
    case heicNotSupported
}

enum HEICWriter {
    
    /// Serial queue with userInitiated QoS for ImageIO write operations to avoid priority inversions
    private static let writeQueue = DispatchQueue(
        label: "com.thumbnailer.heicwriter",
        qos: .utility,
        target: nil
    )
    
    /// Check if HEIC is supported on this system
    nonisolated static var isHEICSupported: Bool {
        if #available(macOS 10.13, *) {
            return UTType.heic.isDeclared
        } else {
            return false
        }
    }
    
    /// Atomically writes a HEIC next to `to` (forces `.heic`), creating folders as needed.
    /// - Parameters:
    ///   - image: CGImage to encode.
    ///   - to: Desired output URL (extension will be replaced with `.heic`).
    ///   - quality: 0.0...1.0 (recommended 0.7–0.95).
    ///   - overwrite: Remove existing file if present before move.
    ///   - metadata: Optional CGImageProperties-style dictionary (e.g., EXIF, orientation).
    static func write(
        image: CGImage,
        to url: URL,
        quality: Double,
        overwrite: Bool = true,
    ) async throws {
        // Check if HEIC is supported first
        guard isHEICSupported else {
            throw HEICWriterError.heicNotSupported
        }
        
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

                    // Normalize to .heic
                    let finalURL = url.deletingPathExtension().appendingPathExtension("heic")

                    // Write atomically via temp file, then move
                    let tmpURL = finalURL
                        .deletingLastPathComponent()
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension("heic")

                    guard let dest = CGImageDestinationCreateWithURL(tmpURL as CFURL,
                                                                     UTType.heic.identifier as CFString,
                                                                     1,
                                                                     nil) else {
                        continuation.resume(throwing: HEICWriterError.destinationCreateFailed)
                        return
                    }
                    
                    // Clamp the quality between 0-1
                    let q = max(0, min(1, quality))
                    
                    let props: [CFString: Any] = [
                        kCGImageDestinationLossyCompressionQuality: CGFloat(q)
                    ]

                    // Note: metadata parameter is ignored in async version to avoid Sendable issues
                    // Use writeSync if you need metadata support

                    CGImageDestinationAddImage(dest, image, props as CFDictionary)
                    guard CGImageDestinationFinalize(dest) else {
                        try? fm.removeItem(at: tmpURL)
                        continuation.resume(throwing: HEICWriterError.finalizeFailed)
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
