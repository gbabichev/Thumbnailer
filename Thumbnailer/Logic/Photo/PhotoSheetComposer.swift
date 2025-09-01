/*
 
 PhotoSheetComposer.swift
 Thumbnailer
 
 Creates the contact sheets from leafs of folders.
 
 George Babichev
 
 */

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Sheet output format
enum SheetOutputFormat {
    case jpeg
    case heic
    
    nonisolated var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .heic: return "heic"
        }
    }
}

/// Stateless helpers for building and writing photo contact sheets.
/// NOTE: This type is deliberately *not* @MainActor to avoid Swift 6 isolation issues.
/// All APIs are `nonisolated` static so you can call them freely from background tasks.
nonisolated enum PhotoSheetComposer {

    // MARK: - File Types

    /// Supported image file extensions (lowercased).
    static let allowedExts: Set<String> = [
        "jpg", "jpeg", "png", "heic", "tif", "tiff", "bmp", "gif", "webp"
    ]

    // MARK: - Content Mode

    /// How images are fitted into each cell.
    enum ContentMode {
        case stretch          // distort to fill cell
        case pad              // "Pad": aspect-fit, no crop
        case crop         // "Crop": aspect-fill, symmetrical crop
    }

    // MARK: - Public API: Loading (Downsampled)

    /// Loads images from `folder` (non-recursive) and creates orientation-correct,
    /// downsampled CGImages sized to **fit** `cellSize` (no crop).
    ///
    /// Use this for contact sheets to avoid pulling full‑resolution frames into RAM.
    /// - Parameters:
    ///   - folder: Folder to scan (hidden files skipped).
    ///   - cellSize: Target cell size in points/pixels for the sheet.
    ///   - scale: If you're producing a Retina (2x) sheet bitmap, pass `2.0`.
    /// - Returns: CGImages whose longer side is ≤ max(cellSize)×scale.
    nonisolated static func loadDownsampledCGImages(
        in folder: URL,
        fitting cellSize: CGSize,
        scale: CGFloat = 1.0
    ) -> [CGImage] {
        let maxDim = Int(ceil(max(cellSize.width, cellSize.height) * max(scale, 1)))
        return loadCGImages(in: folder, maxDimension: maxDim)
    }

    /// Loads images downsampled so the longer side is ≤ `maxDimension` pixels.
    /// Preserves EXIF orientation; avoids immediate caching to keep memory smooth.
    /// - Parameters:
    ///   - folder: Folder to scan (hidden files skipped).
    ///   - maxDimension: Max pixel size for the *longer* side (must be > 0).
    /// - Returns: Array of downsampled CGImages in filename order.
    nonisolated static func loadCGImages(in folder: URL, maxDimension: Int) -> [CGImage] {
        precondition(maxDimension > 0, "maxDimension must be > 0")

        let fm = FileManager.default
        let all = (try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        let imageFiles = all
            .filter { allowedExts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        var out: [CGImage] = []
        out.reserveCapacity(imageFiles.count)

        // ImageIO thumbnail options:
        // - Always build from the full image (not embedded preview).
        // - Apply EXIF orientation.
        // - Defer caching to avoid spikes.
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ]

        for url in imageFiles {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            else { continue }
            out.append(thumb)
        }
        return out
    }

    // MARK: - Public API: Compositing

    /// Composes a strict grid (columns × rows) where each cell is exactly `cellSize`.
    ///
    /// - Parameters:
    ///   - thumbnails: Pre-sized images (ideally downsampled via the helpers above).
    ///   - columns: Number of columns (≥ 1).
    ///   - cellSize: Cell size in pixels (or points if you want a 1x bitmap).
    ///   - background: Background color for the sheet and any letterboxing.
    ///   - contentMode: `.stretch` (default) or `.fit` (aspect‑fit, no crop).
    /// - Returns: The composed `CGImage` or `nil` if `thumbnails` is empty.
    nonisolated static func composeGrid(
        thumbnails: [CGImage],
        columns: Int,
        cellSize: CGSize,
        background: CGColor = CGColor(gray: 0, alpha: 1),
        contentMode: ContentMode = .stretch
    ) -> CGImage? {
        guard !thumbnails.isEmpty else { return nil }

        let cols = max(columns, 1)
        let cellW = Int(round(cellSize.width))
        let cellH = Int(round(cellSize.height))
        let rows = Int(ceil(Double(thumbnails.count) / Double(cols)))

        let sheetW = cellW * cols
        let sheetH = cellH * rows

        guard let ctx = CGContext(
            data: nil,
            width: sheetW, height: sheetH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Fill background & set scaling quality.
        ctx.setFillColor(background)
        ctx.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(false)
        // Draw row by row. CoreGraphics origin is bottom-left; flip rows to draw top-down.
        for (i, img) in thumbnails.enumerated() {
            let col = i % cols
            let row = i / cols
            let flippedRow = (rows - 1) - row

            let cellRect = CGRect(x: col * cellW, y: flippedRow * cellH, width: cellW, height: cellH)

            switch contentMode {
            case .stretch:
                ctx.draw(img, in: cellRect)
                
            case .pad:
                let imgSize = CGSize(width: img.width, height: img.height)
                let fit = aspectFitRect(imageSize: imgSize, in: cellRect.size)
                let drawRect = CGRect(
                    x: cellRect.origin.x + fit.origin.x,
                    y: cellRect.origin.y + fit.origin.y,
                    width: fit.width,
                    height: fit.height
                )
                ctx.draw(img, in: drawRect)
            case .crop:
                let imgSize = CGSize(width: img.width, height: img.height)
                let fill = aspectFillRect(imageSize: imgSize, in: cellRect.size)
                let drawRect = CGRect(
                    x: cellRect.origin.x + fill.origin.x,
                    y: cellRect.origin.y + fill.origin.y,
                    width: fill.width,
                    height: fill.height
                )
                ctx.saveGState()
                ctx.clip(to: cellRect)      // ensure overflow is cropped to the cell
                ctx.draw(img, in: drawRect)
                ctx.restoreGState()
            }
        }

        return ctx.makeImage()
    }

    // MARK: - Public API: Writing Contact Sheets
    
    /// Composes and writes a contact sheet to disk in the specified format
    ///
    /// - Parameters:
    ///   - thumbnails: Pre-sized images (ideally downsampled via the helpers above).
    ///   - columns: Number of columns (≥ 1).
    ///   - cellSize: Cell size in pixels (or points if you want a 1x bitmap).
    ///   - background: Background color for the sheet and any letterboxing.
    ///   - contentMode: How images are fitted into each cell.
    ///   - outputURL: Where to write the contact sheet (extension will be adjusted based on format).
    ///   - quality: Compression quality 0.0...1.0.
    ///   - format: Output format (.jpeg or .heic).
    /// - Returns: The final output URL that was written to.
    /// - Throws: Various errors from image composition or file writing.
    nonisolated static func composeAndWriteSheet(
        thumbnails: [CGImage],
        columns: Int,
        cellSize: CGSize,
        background: CGColor = CGColor(gray: 0, alpha: 1),
        contentMode: ContentMode = .stretch,
        to outputURL: URL,
        quality: Double,
        format: SheetOutputFormat
    ) async throws -> URL {
        // Compose the grid
        guard let composedImage = composeGrid(
            thumbnails: thumbnails,
            columns: columns,
            cellSize: cellSize,
            background: background,
            contentMode: contentMode
        ) else {
            throw NSError(
                domain: "PhotoSheetComposer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to compose contact sheet."]
            )
        }
        
        // Adjust output URL to have correct extension
        let finalOutputURL = outputURL.deletingPathExtension().appendingPathExtension(format.fileExtension)
        
        // Write using appropriate writer
        switch format {
        case .jpeg:
            try await JPEGWriter.write(
                image: composedImage,
                to: finalOutputURL,
                quality: quality,
                overwrite: true,
                progressive: false
            )
        case .heic:
            // Check HEIC support and fallback if necessary
            if HEICWriter.isHEICSupported {
                try await HEICWriter.write(
                    image: composedImage,
                    to: finalOutputURL,
                    quality: quality,
                    overwrite: true
                )
            } else {
                // Fallback to JPEG if HEIC is not supported
                let jpegURL = outputURL.deletingPathExtension().appendingPathExtension("jpg")
                try await JPEGWriter.write(
                    image: composedImage,
                    to: jpegURL,
                    quality: quality,
                    overwrite: true,
                    progressive: false
                )
                return jpegURL
            }
        }
        
        return finalOutputURL
    }

    // MARK: - Private Helpers

    /// Aspect-fit (no crop, no distortion) rectangle within `cellSize`.
    @inline(__always)
    nonisolated private static func aspectFitRect(imageSize: CGSize, in cellSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let sx = cellSize.width  / imageSize.width
        let sy = cellSize.height / imageSize.height
        let scale = min(sx, sy) // fit (no crop)
        let w = imageSize.width  * scale
        let h = imageSize.height * scale
        let x = (cellSize.width  - w) * 0.5
        let y = (cellSize.height - h) * 0.5
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Aspect-fill (crop edges) rectangle within `cellSize`.
    @inline(__always)
    nonisolated private static func aspectFillRect(imageSize: CGSize, in cellSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let sx = cellSize.width  / imageSize.width
        let sy = cellSize.height / imageSize.height
        let scale = max(sx, sy) // fill (will crop)
        let w = imageSize.width  * scale
        let h = imageSize.height * scale
        let x = (cellSize.width  - w) * 0.5
        let y = (cellSize.height - h) * 0.5
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
