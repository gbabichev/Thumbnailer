/*
 
 IdentifySilentVideos.swift
 Thumbnailer
 
 Identifies videos with no audio tracks.
 
 George Babichev
 
 */

import Foundation
import AVFoundation

enum IdentifySilentVideos {
    static let defaultVideoExts = AppConstants.videoExts

    static func identifySilentVideos(
        leafs: [URL],
        ignoreFolderNames: Set<String> = [],
        includeHidden: Bool = false,
        allowedExtensions: Set<String> = defaultVideoExts
    ) async -> [URL] {
        let fm = FileManager.default
        var silentVideos: [URL] = []

        for leaf in leafs {
            if ignoreFolderNames.contains(leaf.lastPathComponent) { continue }

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: leaf.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let videos = findVideos(in: leaf, includeHidden: includeHidden, allowedExtensions: allowedExtensions)
            for videoURL in videos {
                if !(await videoHasAudioTrack(videoURL)) {
                    silentVideos.append(videoURL)
                }
            }
        }

        return silentVideos.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func findVideos(
        in folder: URL,
        includeHidden: Bool,
        allowedExtensions: Set<String>
    ) -> [URL] {
        let fm = FileManager.default
        var options: FileManager.DirectoryEnumerationOptions = [
            .skipsSubdirectoryDescendants,
            .skipsPackageDescendants
        ]
        if !includeHidden {
            options.insert(.skipsHiddenFiles)
        }

        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: options
        ) else {
            return []
        }

        var videos: [URL] = []
        for case let item as URL in enumerator {
            if let isRegular = try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
               isRegular == true,
               allowedExtensions.contains(item.pathExtension.lowercased()) {
                videos.append(item)
            }
        }
        return videos
    }

    private static func videoHasAudioTrack(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            return !tracks.isEmpty
        } catch {
            return false
        }
    }
}
