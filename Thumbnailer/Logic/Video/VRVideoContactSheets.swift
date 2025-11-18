/*

 VRVideoContactSheets.swift
 Thumbnailer

 Given a single VR video URL and a destination "thumbs" directory,
    extract representative frames, split them vertically (for VR side-by-side format),
    compose a contact sheet, and write in JPEG or HEIC format.

 George Babichev

 */

import Foundation
@preconcurrency import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Public API

enum VRVideoContactSheetProcessor {
    /// Process a single VR video and write a contact sheet in specified format.
    /// Extracts frames and splits them vertically to show VR content properly.
    /// - Parameters:
    ///   - videoURL: Source video (.mp4, .mov, etc. as supported by AVFoundation).
    ///   - thumbsDir: Destination directory where the contact sheet will be written (created if needed).
    ///   - options: Sheet layout and extraction options.
    ///   - jpegQuality: 0.0…1.0 (default best between 0.7—0.85 in most cases).
    ///   - format: Output format (.jpeg or .heic).
    ///   - maxTiles: Optional override for maximum thumbnails; if nil, uses UserDefaults key "videoSheetMaxTiles" (3…40, default 10).
    static func process(
        videoURL: URL,
        thumbsDir: URL,
        options: VideoSheetOptions,
        jpegQuality: Double,
        format: VideoSheetOutputFormat = .jpeg,
        maxTiles: Int? = nil
    ) async -> VideoContactSheetResult {
        do {
            try FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
        } catch {
            return .failure(videoURL)
        }

        do {
            // Resolve max tiles from parameter or UserDefaults (pairs with @AppStorage("videoSheetMaxTiles"))
            let stored = UserDefaults.standard.integer(forKey: "videoSheetMaxTiles")
            let defaultCap = 10
            let resolvedCap = max(3, min(40, (maxTiles ?? (stored > 0 ? stored : defaultCap))))

            try Task.checkCancellation()

            let asset = AVURLAsset(url: videoURL)

            // Validate duration early
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else {
                return .failure(videoURL)
            }

            // Heuristic step based on duration
            let step = max(options.minStepSeconds,
                           intervalStep(forDurationSeconds: duration,
                                        skipFirstSeconds: options.skipFirstSeconds,
                                        targetTiles: resolvedCap))

            // Request a modest max render size (2× target cell for quality)
            let maxSize = CGSize(
                width: max(2, options.cellSize.width * 2.0),
                height: max(2, options.cellSize.height * 2.0)
            )

            // Extract frames
            let frames = try await extractFrames(
                from: asset,
                skipFirstSeconds: options.skipFirstSeconds,
                every: step,
                maximumSize: maxSize,
                maxFrames: resolvedCap
            )

            guard !frames.isEmpty else {
                return .failure(videoURL)
            }

            try Task.checkCancellation()

            // Enforce hard cap in case inputs or future changes exceed it
            let limitedFrames = frames.count > resolvedCap ? Array(frames.prefix(resolvedCap)) : frames

            // Split each frame vertically to extract the left half (VR side-by-side format)
            let splitFrames = splitFramesVertically(limitedFrames)

            // Compose sheet with split frames
            let sheet = composeSheet(
                frames: splitFrames,
                columns: options.columns,
                cellSize: options.cellSize,
                spacing: options.spacing,
                background: options.background
            )

            // Output path with correct extension based on format
            let stem = videoURL.deletingPathExtension().lastPathComponent
            let outURL = thumbsDir.appendingPathComponent(stem).appendingPathExtension(format.fileExtension)

            // Write using appropriate writer based on format
            switch format {
            case .jpeg:
                try await JPEGWriter.write(
                    image: sheet,
                    to: outURL,
                    quality: jpegQuality,
                    overwrite: true,
                    progressive: false
                )
            case .heic:
                // Check HEIC support and fallback if necessary
                if HEICWriter.isHEICSupported {
                    try await HEICWriter.write(
                        image: sheet,
                        to: outURL,
                        quality: jpegQuality,
                        overwrite: true
                    )
                } else {
                    // Fallback to JPEG if HEIC is not supported
                    let jpegURL = thumbsDir.appendingPathComponent(stem).appendingPathExtension("jpg")
                    try await JPEGWriter.write(
                        image: sheet,
                        to: jpegURL,
                        quality: jpegQuality,
                        overwrite: true,
                        progressive: false
                    )
                    return .success(videoURL, jpegURL)
                }
            }

            return .success(videoURL, outURL)

        } catch is CancellationError {
            return .failure(videoURL)
        } catch {
            return .failure(videoURL)
        }
    }
}

// MARK: - Frame Extraction

private func extractFrames(
    from asset: AVURLAsset,
    skipFirstSeconds: Double,
    every intervalSeconds: Double,
    maximumSize: CGSize,
    maxFrames: Int? = nil
) async throws -> [CGImage] {
    let duration = try await asset.load(.duration).seconds
    guard duration.isFinite, duration > 0 else { return [] }

    // Build request times; fallback to t=0 if nothing valid
    var times: [CMTime] = []
    let step = max(0.0, intervalSeconds)
    var t = max(0.0, skipFirstSeconds)
    while t < duration {
        if let cap = maxFrames, times.count >= cap { break }
        times.append(CMTime(seconds: t, preferredTimescale: 600))
        t += step
    }
    if times.isEmpty { times = [CMTime(seconds: 0, preferredTimescale: 600)] }

    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
    generator.requestedTimeToleranceBefore = tolerance
    generator.requestedTimeToleranceAfter = tolerance
    generator.maximumSize = maximumSize

    // Use the callback-based API with TaskGroup for concurrency
    return await withTaskGroup(of: CGImage?.self) { group in
        var frames: [CGImage] = []
        frames.reserveCapacity(times.count)

        // Process all times concurrently (but with reasonable limit)
        let concurrentLimit = min(times.count, 4)
        var timeIterator = times.makeIterator()

        // Start initial batch
        for _ in 0..<concurrentLimit {
            if let time = timeIterator.next() {
                group.addTask {
                    await withCheckedContinuation { continuation in
                        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { requestedTime, image, actualTime, result, error in
                            continuation.resume(returning: image)
                        }
                    }
                }
            }
        }

        // Process results and start new tasks
        for await frame in group {
            if let image = frame {
                frames.append(image)
            }

            // Start next extraction if available
            if let nextTime = timeIterator.next() {
                group.addTask {
                    await withCheckedContinuation { continuation in
                        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: nextTime)]) { requestedTime, image, actualTime, result, error in
                            continuation.resume(returning: image)
                        }
                    }
                }
            }
        }

        return frames
    }
}

// MARK: - VR Frame Splitting

/// Splits each frame vertically in half, keeping only the left side.
/// This is useful for VR side-by-side videos where each frame contains two views.
private func splitFramesVertically(_ frames: [CGImage]) -> [CGImage] {
    frames.compactMap { frame in
        let width = frame.width
        let height = frame.height

        // Calculate the width of the left half
        let halfWidth = width / 2

        // Create a rect for the left half
        let leftRect = CGRect(x: 0, y: 0, width: halfWidth, height: height)

        // Crop the image to get the left half
        guard let leftHalf = frame.cropping(to: leftRect) else {
            return frame // Fallback to original if cropping fails
        }

        return leftHalf
    }
}

// MARK: - Compositing

private func composeSheet(
    frames: [CGImage],
    columns: Int,
    cellSize: CGSize,
    spacing: CGFloat,
    background: CGColor
) -> CGImage {
    guard !frames.isEmpty else {
        return createPlaceholderImage()
    }

    // Analyze actual frame aspect ratios to determine optimal layout
    let aspects: [CGFloat] = frames.map { frame in
        CGFloat(max(1, frame.width)) / CGFloat(max(1, frame.height))
    }

    // Use median aspect ratio for consistent cell sizing
    let targetAspect = medianAspect(aspects)

    let cols = max(1, columns)
    let rowH = max(1, Int(round(cellSize.height)))

    // Calculate cell width based on actual content aspect ratio
    let cellW = max(1, Int(round(CGFloat(rowH) * targetAspect)))

    // Adjust spacing based on content type (reduce gaps for portrait videos)
    let portraitShare = CGFloat(aspects.filter { $0 < 1 }.count) / CGFloat(max(1, aspects.count))
    let gapScale: CGFloat = 0.6 + 0.4 * (1.0 - min(1.0, portraitShare)) // 0.6…1.0
    let gap = max(0, Int(round(spacing * gapScale)))

    let rows = (frames.count + cols - 1) / cols // Ceiling division
    let sheetW = cols * cellW + gap * max(0, cols - 1)
    let sheetH = rows * rowH + gap * max(0, rows - 1)

    guard let ctx = CGContext(
        data: nil,
        width: sheetW, height: sheetH,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return frames[0] // Fallback
    }

    // Fill background
    ctx.setFillColor(background)
    ctx.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))
    ctx.interpolationQuality = .high

    // Draw frames with smart aspect-fit and gap elimination
    for (index, frame) in frames.enumerated() {
        let col = index % cols
        let row = index / cols
        let flippedRow = (rows - 1) - row // Flip for CoreGraphics coordinates

        let cellRect = CGRect(
            x: col * cellW + col * gap,
            y: flippedRow * rowH + flippedRow * gap,
            width: cellW,
            height: rowH
        )

        // Smart aspect-fit with gap elimination for tiny borders
        let drawRect = aspectFitWithGapElimination(
            imageSize: CGSize(width: frame.width, height: frame.height),
            in: cellRect
        )

        ctx.draw(frame, in: drawRect)
    }

    return ctx.makeImage() ?? frames[0]
}

// MARK: - Smart Layout Helpers

/// Calculate median aspect ratio for consistent cell sizing
private func medianAspect(_ aspects: [CGFloat]) -> CGFloat {
    guard !aspects.isEmpty else { return 16.0 / 9.0 }
    let sorted = aspects.sorted()
    let count = sorted.count
    let mid = count / 2
    return count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
}

/// Aspect-fit with elimination of tiny padding (< 2px) to minimize gaps
private func aspectFitWithGapElimination(imageSize: CGSize, in containerRect: CGRect) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0 else { return containerRect }

    let imageAspect = imageSize.width / imageSize.height
    let containerAspect = containerRect.width / containerRect.height

    var drawRect: CGRect
    if imageAspect > containerAspect {
        // Image is wider - fit to width
        let scale = containerRect.width / imageSize.width
        let scaledHeight = imageSize.height * scale
        drawRect = CGRect(
            x: containerRect.minX,
            y: containerRect.midY - scaledHeight / 2,
            width: containerRect.width,
            height: scaledHeight
        )
    } else {
        // Image is taller - fit to height
        let scale = containerRect.height / imageSize.height
        let scaledWidth = imageSize.width * scale
        drawRect = CGRect(
            x: containerRect.midX - scaledWidth / 2,
            y: containerRect.minY,
            width: scaledWidth,
            height: containerRect.height
        )
    }

    // Eliminate tiny gaps (≤2px) by expanding to fill the cell
    let maxGapTolerance: CGFloat = 2.0
    let horizontalGap = containerRect.width - drawRect.width
    let verticalGap = containerRect.height - drawRect.height

    if horizontalGap >= 0 && horizontalGap <= maxGapTolerance &&
       verticalGap >= 0 && verticalGap <= maxGapTolerance {
        // Tiny gaps - just fill the entire cell
        return containerRect
    }

    return drawRect
}

// MARK: - Helpers

private func intervalStep(forDurationSeconds s: Double,
                          skipFirstSeconds: Double = 10,
                          targetTiles: Int = 10,
                          minStep: Double = 0.5) -> Double {
    let usable = max(0, s - skipFirstSeconds)
    guard targetTiles > 0 else { return max(minStep, 3) }
    return max(minStep, usable / Double(targetTiles))
}

/// Creates a minimal placeholder image for empty frame sets
private func createPlaceholderImage() -> CGImage {
    let ctx = CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    return ctx.makeImage()!
}
