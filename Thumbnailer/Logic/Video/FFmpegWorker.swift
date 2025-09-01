/*
 
 FFmpegWorker.swift
 Thumbnailer
 
 FFMPEG processor.
 
 George Babichev
 
 */

import Foundation
import AVFoundation

struct FFmpegTrimOptions: Sendable {
    /// Seconds to trim from the beginning
    var trimStartSeconds: Double = 0.0
    
    /// Seconds to trim from the end
    var trimEndSeconds: Double = 0.0
    
    /// Whether to replace original files
    var replaceOriginals: Bool = true
    
    /// Suffix for new files when not replacing
    var outputSuffix: String = "_trimmed"
    
    /// Path to ffmpeg binary (auto-detected if nil)
    var ffmpegPath: String? = nil
    
    init() {}
}

struct FFmpegTrimResult: Sendable {
    let originalURL: URL
    let isSuccess: Bool
    let originalSize: Int64
    let newSize: Int64
    let processingTime: TimeInterval
    
    static func success(
        original: URL,
        originalSize: Int64,
        newSize: Int64,
        time: TimeInterval
    ) -> Self {
        .init(
            originalURL: original,
            isSuccess: true,
            originalSize: originalSize,
            newSize: newSize,
            processingTime: time
        )
    }
    
    static func failure(original: URL, time: TimeInterval = 0) -> Self {
        .init(
            originalURL: original,
            isSuccess: false,
            originalSize: 0,
            newSize: 0,
            processingTime: time
        )
    }
    
}

struct FFmpegInfo: Sendable {
    let path: String
    let source: FFmpegSource
    
    enum FFmpegSource: String, Sendable {
        case appBundle = "App Bundle"
        case homebrew = "Homebrew"
        case system = "System"
        case custom = "Custom Path"
        case which = "System PATH"
    }
    
    var displayDescription: String {
        switch source {
        case .appBundle:
            return "Using built-in FFmpeg from app bundle"
        case .homebrew:
            return "Using FFmpeg from Homebrew (\(path))"
        case .system:
            return "Using system FFmpeg (\(path))"
        case .custom:
            return "Using custom FFmpeg path (\(path))"
        case .which:
            return "Using FFmpeg found in PATH (\(path))"
        }
    }
}

enum FFmpegVideoTrimmer {
    
    // MARK: - Private Implementation
    
    /// Find ffmpeg binary and return info about which one we're using
    static func findFFmpegWithInfo(customPath: String?) async -> FFmpegInfo? {
        // If custom path provided, verify it exists
        if let path = customPath {
            if FileManager.default.fileExists(atPath: path) {
                return FFmpegInfo(path: path, source: .custom)
            }
        }
        
        // First priority: Check app bundle
        if let bundlePath = Bundle.main.path(forResource: "ffmpeg", ofType: nil) {
            if FileManager.default.fileExists(atPath: bundlePath) {
                // Make sure it's executable
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: bundlePath
                )
                return FFmpegInfo(path: bundlePath, source: .appBundle)
            }
        }
        
        // Check Homebrew locations
        let homebrewPaths = [
            "/opt/homebrew/bin/ffmpeg",  // Apple Silicon Homebrew
            "/usr/local/bin/ffmpeg"      // Intel Homebrew
        ]
        
        for path in homebrewPaths {
            if FileManager.default.fileExists(atPath: path) {
                return FFmpegInfo(path: path, source: .homebrew)
            }
        }
        
        // Check system location
        if FileManager.default.fileExists(atPath: "/usr/bin/ffmpeg") {
            return FFmpegInfo(path: "/usr/bin/ffmpeg", source: .system)
        }
        
        // Last resort: Try using 'which' command
        if let whichPath = await runCommand("/usr/bin/which", args: ["ffmpeg"])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !whichPath.isEmpty {
            return FFmpegInfo(path: whichPath, source: .which)
        }
        
        return nil
    }
    
    // Removed unused findFFmpeg(customPath:) per Periphery warning
    
    /// Trim a single video using ffmpeg with support for both start and end trimming
    static func trimVideoWithFFmpeg(
        _ videoURL: URL,
        ffmpegPath: String,
        options: FFmpegTrimOptions
    ) async -> FFmpegTrimResult {
        let startTime = Date()
        
        do {
            // Get video duration first for end trimming calculations
            let duration = await getVideoDuration(videoURL)
            let originalSize = try FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? Int64 ?? 0
            let outputURL = buildOutputURL(for: videoURL, options: options)
            
            // Ensure output directory exists
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            
            // Remove existing output file if it exists
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            
            // Build ffmpeg command based on trim type
            var args: [String] = []
            
            if options.trimStartSeconds > 0 && options.trimEndSeconds > 0 {
                // Trim both start and end
                let outputDuration = duration - options.trimStartSeconds - options.trimEndSeconds
                args = [
                    "-ss", String(options.trimStartSeconds),
                    "-i", videoURL.path,
                    "-t", String(outputDuration),
                    "-c", "copy",
                    //"-avoid_negative_ts", "make_zero",
                    "-map_metadata", "0",
                    "-movflags", "+faststart",
                    "-y",
                    outputURL.path
                ]
                
            } else if options.trimStartSeconds > 0 {
                // Trim only start
                args = [
                    "-ss", String(options.trimStartSeconds),
                    "-i", videoURL.path,
                    "-c", "copy",
                    //"-avoid_negative_ts", "make_zero",
                    "-map_metadata", "0",
                    "-movflags", "+faststart",
                    "-y",
                    outputURL.path
                ]
                
            } else if options.trimEndSeconds > 0 {
                // Trim only end
                let outputDuration = duration - options.trimEndSeconds
                args = [
                    "-i", videoURL.path,
                    "-t", String(outputDuration),
                    "-c", "copy",
                    "-avoid_negative_ts", "make_zero",
                    "-map_metadata", "0",
                    "-movflags", "+faststart",
                    "-y",
                    outputURL.path
                ]
                
            } else {
                // No trimming specified
                return .failure(original: videoURL, time: Date().timeIntervalSince(startTime))
            }
            
            // Run ffmpeg
            _ = await runCommand(ffmpegPath, args: args)
            
            // Check if output file was created
            guard FileManager.default.fileExists(atPath: outputURL.path) else {
                return .failure(original: videoURL, time: Date().timeIntervalSince(startTime))
            }
            
            // Get new file size
            let newSize = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64 ?? 0
            
            // Handle file replacement vs. creating new file
            if options.replaceOriginals {
                do {
                    // Step 1: Remove the original file
                    try FileManager.default.removeItem(at: videoURL)
                    
                    // Step 2: Move temp file to original location
                    try FileManager.default.moveItem(at: outputURL, to: videoURL)
                    
                    return .success(
                        original: videoURL,
                        originalSize: originalSize,
                        newSize: newSize,
                        time: Date().timeIntervalSince(startTime)
                    )
                    
                } catch {
                    try? FileManager.default.removeItem(at: outputURL)
                    return .failure(original: videoURL, time: Date().timeIntervalSince(startTime))
                }
                
            } else {
                return .success(
                    original: videoURL,
                    originalSize: originalSize,
                    newSize: newSize,
                    time: Date().timeIntervalSince(startTime)
                )
            }
            
        } catch {
            let outputURL = buildOutputURL(for: videoURL, options: options)
            try? FileManager.default.removeItem(at: outputURL)
            return .failure(original: videoURL, time: Date().timeIntervalSince(startTime))
        }
    }
    
    /// Get video duration using AVFoundation
    private static func getVideoDuration(_ videoURL: URL) async -> Double {
        let asset = AVURLAsset(url: videoURL)
        
        do {
            let duration = try await asset.load(.duration)
            guard duration.isValid && !duration.isIndefinite else {
                return 0.0
            }
            let seconds = duration.seconds
            return seconds
        } catch {
            // If loading fails, return 0 to trigger skip
            return 0.0
        }
    }
    
    /// Run a shell command and return its output
    private static func runCommand(_ command: String, args: [String]) async -> String? {
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = args
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            
            do {
                try process.run()
                process.waitUntilExit()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)
                continuation.resume(returning: output)
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
    
    /// Build output URL
    private static func buildOutputURL(for videoURL: URL, options: FFmpegTrimOptions) -> URL {
        if options.replaceOriginals {
            // Create temp file in the same directory as the original
            // This ensures we're on the same filesystem for atomic moves
            let directory = videoURL.deletingLastPathComponent()
            let originalName = videoURL.deletingPathExtension().lastPathComponent
            let tempName = ".\(originalName)_trimming_\(UUID().uuidString.prefix(8)).tmp.mp4"
            return directory.appendingPathComponent(tempName)
        } else {
            // Create new file with suffix
            let directory = videoURL.deletingLastPathComponent()
            let filename = videoURL.deletingPathExtension().lastPathComponent
            return directory
                .appendingPathComponent("\(filename)\(options.outputSuffix)")
                .appendingPathExtension("mp4")
        }
    }
    
}

func getVideoDuration(_ videoURL: URL) async -> Double {
    let asset = AVURLAsset(url: videoURL)
    
    do {
        let duration = try await asset.load(.duration)
        guard duration.isValid && !duration.isIndefinite else {
            return 0.0
        }
        return duration.seconds
    } catch {
        return 0.0
    }
}

func trimVideoWithFFmpeg(_ videoURL: URL, ffmpegPath: String, options: FFmpegTrimOptions) async -> FFmpegTrimResult {
    // This should use your existing FFmpegVideoTrimmer.trimVideoWithFFmpeg method
    // For now, I'll reference the method that should exist in your FFmpegVideoTrimmer
    return await FFmpegVideoTrimmer.trimVideoWithFFmpeg(videoURL, ffmpegPath: ffmpegPath, options: options)    }

func findVideos(in folder: URL, ignoringSubdirNamed ignore: String) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: folder,
        includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }
    
    var videos: [URL] = []
    
    while let url = enumerator.nextObject() as? URL {
        let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .nameKey])
        let isDirectory = resourceValues?.isDirectory ?? false
        let name = resourceValues?.name ?? url.lastPathComponent
        
        if isDirectory {
            if name.caseInsensitiveCompare(ignore) == .orderedSame {
                enumerator.skipDescendants()
            }
            continue
        }
        
        if AppConstants.allVideoExts.contains(url.pathExtension.lowercased()) {
            videos.append(url)
        }
    }
    
    return videos.sorted {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
    }
}


