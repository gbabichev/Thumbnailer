/*
 
 AppConstants.swift
 Thumbnailer
 
 Cross function constants. 
 
 George Babichev
 
 */

import Foundation

enum AppConstants {
    // MARK: - File Processing
    
    /// Filenames to ignore across all file scanning operations
    static let ignoredFileNames: Set<String> = [
        ".DS_Store", "Thumbs.db", ".dump"
    ]
    
    // MARK: - Image Extensions
    
    /// Extensions that can be renamed to .jpg without re-encoding
    static let renameableJPEGExts: Set<String> = [
        "jpeg", "jpe"
    ]
    
    /// Supported photo file extensions (lowercased, no dot)
    static let photoExts: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp", "gif", "webp"
    ]
    
    // MARK: - Video Extensions
    
    /// Supported video file extensions for processing (lowercased, no dot)
    /// These formats can be processed by FFmpeg and AVFoundation
    static let videoExts: Set<String> = [
        "mp4"
    ]
    
    /// Common unsupported video file extensions (lowercased, no dot)
    /// These are detected but skipped with informative messages
    static let unsupportedVideoExts: Set<String> = [
        "mkv", "wmv", "flv", "webm", "ogv", "3gp", "mpg", "mpeg", "ts", "mts", "asf", "rm", "rmvb", "vob", "divx", "xvid", "mov", "avi", "m4v"
    ]
    
    /// All video file extensions (supported + unsupported) for detection
    static let allVideoExts: Set<String> = {
        return videoExts.union(unsupportedVideoExts)
    }()
    
    /// Human-readable list of supported video formats for user messages
    static let supportedVideoFormatsString: String = {
        return videoExts.sorted().joined(separator: ", ")
    }()
}
