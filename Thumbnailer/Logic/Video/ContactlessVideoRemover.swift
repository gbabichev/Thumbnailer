/*
 
 ContactlessVideoFileRemover.swift
 Thumbnailer
 
 Deletes individual video files if there is no corresponding contact sheet in the thumb folder.
 
 George Babichev
 
 */

import Foundation

struct ContactlessVideoFileRemover {
    
    /// Finds video files that don't have corresponding contact sheets in the thumb folder
    static func findContactlessVideoFiles(
        in leafFolders: [URL],
        thumbFolderName: String,
        log: @escaping (String) -> Void
    ) -> [URL] {
        var contactlessVideos: [URL] = []
        let fm = FileManager.default
        
        for leafFolder in leafFolders {
            log("🔍 Scanning: \(leafFolder.lastPathComponent)")
            
            // Check if leaf folder exists and is a directory
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: leafFolder.path, isDirectory: &isDir), isDir.boolValue else {
                log("  ⚠️ Not a directory, skipping")
                continue
            }
            
            // Find all video files in the leaf folder
            let videoFiles = findVideoFiles(in: leafFolder, ignoringSubdir: thumbFolderName)
            if videoFiles.isEmpty {
                log("  ℹ️ No video files found")
                continue
            }
            
            log("  📹 Found \(videoFiles.count) video file(s)")
            
            // Check thumb folder
            let thumbFolder = leafFolder.appendingPathComponent(thumbFolderName, isDirectory: true)
            guard fm.fileExists(atPath: thumbFolder.path, isDirectory: &isDir), isDir.boolValue else {
                log("  ⚠️ No thumb folder found - all videos are contactless")
                contactlessVideos.append(contentsOf: videoFiles)
                continue
            }
            
            // Get all contact sheet files in thumb folder (should be .jpg files)
            let contactSheets = findContactSheets(in: thumbFolder)
            log("  🖼️ Found \(contactSheets.count) contact sheet(s) in thumb folder")
            
            // For each video file, check if there's a corresponding contact sheet
            for videoFile in videoFiles {
                let videoBaseName = videoFile.deletingPathExtension().lastPathComponent
                let hasContactSheet = contactSheets.contains { contactSheet in
                    let contactBaseName = contactSheet.deletingPathExtension().lastPathComponent
                    return contactBaseName == videoBaseName
                }
                
                if !hasContactSheet {
                    log("    ❌ No contact sheet for: \(videoFile.lastPathComponent)")
                    contactlessVideos.append(videoFile)
                } else {
                    log("    ✅ Has contact sheet: \(videoFile.lastPathComponent)")
                }
            }
        }
        
        return contactlessVideos.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }
    
    // MARK: - Private Helpers
    
    /// Find all video files in a folder, excluding a specific subdirectory
    private static func findVideoFiles(in folder: URL, ignoringSubdir: String) -> [URL] {
        let fm = FileManager.default
        
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        
        var videoFiles: [URL] = []
        
        while let url = enumerator.nextObject() as? URL {
            let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .nameKey])
            let isDirectory = resourceValues?.isDirectory ?? false
            let name = resourceValues?.name ?? url.lastPathComponent
            
            if isDirectory {
                // Skip the thumb folder
                if name.caseInsensitiveCompare(ignoringSubdir) == .orderedSame {
                    enumerator.skipDescendants()
                }
                continue
            }
            
            // Check if it's a video file
            let ext = url.pathExtension.lowercased()
            if AppConstants.allVideoExts.contains(ext) {
                videoFiles.append(url)
            }
        }
        
        return videoFiles.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }
    
    /// Find all contact sheet files (typically .jpg) in the thumb folder
    private static func findContactSheets(in thumbFolder: URL) -> [URL] {
        let fm = FileManager.default
        
        guard let items = try? fm.contentsOfDirectory(
            at: thumbFolder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        
        return items.filter { item in
            // Only include regular files
            guard (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return false
            }
            
            // Check for image extensions (contact sheets should be images)
            let ext = item.pathExtension.lowercased()
            return ["jpg", "jpeg", "png", "heic"].contains(ext)
        }
    }
}
