/*
 
 ContentView.swift
 Thumbnailer
 
 Main App UI
 
 George Babichev
 
 */

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

struct LeafFolder: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    var displayName: String { url.lastPathComponent }
}

enum ProcessingMode { case photos, videos }

// User-facing mode names for the UI
enum SheetFitMode: String, CaseIterable, Identifiable {
    case stretch = "Stretch"  // distort to fill
    case crop    = "Crop"     // aspect-fill, crop edges
    case pad     = "Pad"      // aspect-fit, letterbox/pillarbox
    
    var id: String { rawValue }
    
    // Map UI choice -> composer mode
    var composerMode: PhotoSheetComposer.ContentMode {
        switch self {
        case .stretch: return .stretch
        case .crop:    return .crop
        case .pad:     return .pad
        }
    }
}

// Thumbnail format selection
enum ThumbnailFormat: String, CaseIterable, Identifiable {
    case jpeg = "JPEG"
    case heic = "HEIC"
    
    var id: String { rawValue }
    
}

struct ContentView: View {
    
    // MARK: - State driving selection, discovery, and processing
    
    // Settings popover hover elements
    // in ContentView

    
    @State var hoveredLeafIdx: Int? = nil
    
    /// Root folders chosen by the user (via Open panel or drag & drop).
    @State var selectedRoots: [URL] = []
    /// Discovered leaf folders under the roots (units of work for processing).
    @State var leafFolders: [LeafFolder] = []
    
    /// True while any long‑running task (thumbnails, sheets, scans) is active.
    @State var isProcessing = false
    /// Optional overall progress 0.0–1.0; `nil` hides the progress view.
    @State var progress: Double? = nil
    
    /// When true, the UI hints that progress hasn’t moved recently.
    @State var isProgressStalled = false
    /// Last observed progress value used for stall detection.
    @State var lastProgressValue: Double = -1
    /// Timestamp of the last progress change (for stall heuristics).
    @State var lastProgressTimestamp = Date()
    
    /// Rolling in‑app log lines shown to the user.
    @State var logLines: [String] = []
    
    /// Indicates the drop target highlight during drag‑and‑drop.
    @State var isDropTargeted = false
    
    /// Cache of the last counted video leaf folders to avoid redundant work.
    @State var lastVideoLeafCount: Int = -1
    
    /// Controls the Settings popover visibility.
    @State var showSettingsPopover = false
    
    /// Handle to the currently running Task so it can be cancelled.
    @State var currentWork: Task<Void, Never>? = nil
    
    /// Controls the “delete contactless” confirmation alert.
    @State var showConfirmDeleteContactless = false
    /// Items pending deletion when removing folders/files without a sheet.
    @State var pendingContactlessVictims: [URL] = []
    
    /// Selected leaf folder IDs in the UI list.
    @State var selectedLeafIDs: Set<UUID> = []
    
    /// Bumped to refresh the log view (e.g., to auto‑scroll).
    @State var logDisplayEpoch: Int = 0
    
    /// Controls whether the in‑app log is visible in the UI.
    @State var showLog: Bool = true
    
    // MARK: - User Settings
    
    /// Number of max tiles for video contact sheets.
    @AppStorage("videoSheetMaxTiles") var videoSheetMaxTiles: Int = 10
    
    /// Seconds to trim from the **start** of videos when requested.
    @AppStorage("videoSecondsToTrim") var videoSecondsToTrim: Int = 10
    
    /// Minimum number of images required inside a leaf folder to be considered.
    @AppStorage("minImagesPerLeaf") var minImagesPerLeaf: Int = 5
    
    /// JPEG/HEIC export quality for thumbnails & contact sheets (0.1…1.0).
    @AppStorage("jpegQuality") var jpegQuality: Double = 0.70
    
    /// Default edge length of generated thumbnails for both photos and videos.
    @AppStorage("thumbnailSize") var thumbnailSize: Int = 150
    
    /// Name of the subfolder created within each leaf to store thumbnails.
    @AppStorage("thumbnailFolderName") var thumbnailFolderName: String = "thumb"
    
    /// Column count used when composing **photo** contact sheets.
    @AppStorage("photoSheetColumns") var photoSheetColumns: Int = 4
    
    /// Column count used when composing **video** contact sheets.
    @AppStorage("videoSheetColumns") var videoSheetColumns: Int = 10
    
    /// Persisted UI choice for how to fit images on **photo** contact sheets.
    /// Backed by `SheetFitMode.rawValue`.
    @AppStorage("photoSheetFitMode") var photoSheetFitModeRaw: String = SheetFitMode.stretch.rawValue
    
    /// If true, place video contact sheets next to the video; otherwise in `thumb`.
    @AppStorage("videoCreateInParent") var videoCreateInParent: Bool = false
    
    /// Threshold that defines a “short” video in seconds (used by filters/tools).
    @AppStorage("shortVideoDurationSeconds") var shortVideoDurationSeconds: Double = 120.0
    
    /// Persisted output format for thumbnails ("JPEG" or "HEIC").
    /// Backed by `ThumbnailFormat.rawValue`.
    @AppStorage("thumbnailFormat") var thumbnailFormatRaw: String = ThumbnailFormat.jpeg.rawValue

    
    /// Two‑way binding that converts the stored `photoSheetFitModeRaw` string
    /// into a typed `SheetFitMode` for the UI, and writes changes back.
    var sheetFitModeBinding: Binding<SheetFitMode> {
        Binding(
            get: { SheetFitMode(rawValue: photoSheetFitModeRaw) ?? .pad },
            set: { photoSheetFitModeRaw = $0.rawValue }
        )
    }
    
    /// Two‑way binding bridging the stored `thumbnailFormatRaw` string to
    /// the typed `ThumbnailFormat` enum used by UI controls.
    var thumbnailFormatBinding: Binding<ThumbnailFormat> {
        Binding(
            get: { ThumbnailFormat(rawValue: thumbnailFormatRaw) ?? .jpeg },
            set: { thumbnailFormatRaw = $0.rawValue }
        )
    }
    
    /// Current workspace mode; gates UI affordances for photos vs. videos.
    @State var mode: ProcessingMode? = nil
    
    /// Whether photo‑oriented actions should be enabled.
    /// Disabled while processing, when no leaf folders are loaded, or when the
    /// current mode is explicitly `.videos`.
    var photoActionsEnabled: Bool {
        mode != .videos && !isProcessing && !leafFolders.isEmpty
    }
    
    var body: some View {
        
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 150, ideal: 200, max: 600)
        } detail: {
            progressSection
            if showLog {
                applog
            }
            else {
                VStack(spacing: 12) {
                    Image(systemName: "eye.slash")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 48, height: 48)
                        .foregroundStyle(.secondary)
                    Text("Log hidden for performance")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Log file is still being written to disk.\nSelect Actions in the Menu Bar to view")
                        .font(.footnote)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .multilineTextAlignment(.center)
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .dropDestination(
            for: URL.self,
            action: { urls, _ in
                Task { await handleDrop(urls: urls) }
                return true
            },
            isTargeted: { over in
                isDropTargeted = over
            }
        )
        .toolbar { buildToolbar }
        .focusedSceneValue(\.appActions, AppActions(
            open: { selectFolders() },
            process: { startPhotoThumbnailProcessing() },
            delete: { deleteThumbFolders() },
            clear: { clearAll() },
            makeSheet: { makePhotoSheets() },
            
            // Log
            openLogFile: { openLogFile() },
            openLogFolder: { openLogFolder() },
            
            // Photo Tools
            scanJPG: { Task { await scanJPGMenuAction() } },
            scanHEIC: { Task { await scanHEICMenuAction() } },
            convertJPG: { Task { await convertJPGMenuAction() } },
            convertHEIC: { Task { await convertHEICMenuAction() } },
            identifyLowFiles: { identifyLowFilesMenuAction() },
            deleteContactlessLeafs: { deleteContactlessLeafs() },
            validatePhotoThumbs: {Task { await validatePhotoThumbsMenuAction()}},
            
            // Video Tools
            identifyShortVideos: { identifyShortVideosMenuAction() },
            scanNonMP4Videos: { scanNonMP4VideosMenuAction() },
            trimVideoIntros: { trimVideoFirstSeconds() },
            trimVideoOutros: { trimVideoLastSeconds() },
            deleteContactlessVideoLeafs: { deleteContactlessVideoFiles() },
            moveVideosToParent: { moveVideosToParentMenuAction() },
            makeVRContactSheet: { makeVRVideoSheets() },
            
            // Capability flags
            isProcessing: isProcessing,
            hasPhotoLeafs: !leafFolders.isEmpty && mode == .photos,
            hasVideoLeafs: !leafFolders.isEmpty && mode == .videos,
            logFileExists: logFileExists,
            logFolderExists: logFolderExists
        ))
        .alert("Delete contactless folders?", isPresented: $showConfirmDeleteContactless) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) {
                Task { await actuallyDeleteContactlessVictims() }
            }
        } message: {
            let mediaType = mode == .videos ? "video" : "photo"
            if mediaType == "video" {
                Text("This will move \(pendingContactlessVictims.count) \(mediaType)(s) without a matching contact sheet to the Trash.")
            }
            else {
                Text("This will move \(pendingContactlessVictims.count) \(mediaType) folder(s) without a matching contact sheet to the Trash.")
            }
        }
        .onChange(of: showLog) { oldValue, newValue in
            if newValue && !oldValue {
                // Log just became visible - refresh from disk
                refreshUILogFromDisk()
            }
        }
    }
}







