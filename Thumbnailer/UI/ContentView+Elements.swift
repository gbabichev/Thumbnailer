//
//  ContentView+Panels.swift
//  Thumbnailer
//
//  Created by George Babichev on 8/24/25.
//

import SwiftUI
import AppKit
import Combine

extension ContentView {
    
    // MARK: - Subviews
    
    var progressSection: some View {
        VStack(spacing: 6) {
            if let raw = progress {
                // Clamp and sanitize
                let p = raw.isFinite ? max(0, min(raw, 1)) : 0
                HStack(spacing: 8) {
                    ProgressView(value: p, total: 1)
                        .frame(maxWidth: .infinity)
                    // If progress hasn't changed for a bit, show a small spinner
                    if isProgressStalled {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.9)
                            .help("Workingâ€¦")
                    }
                }
                HStack {
                    Text("\(Int((p * 100).rounded()))%")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let eta = progressETASeconds, let etaText = formatProgressETA(eta) {
                        Text("ETA \(etaText)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .padding(.top, 6)
        .padding(.leading, 50)
        .padding(.trailing, 50)
        // Stall detector: if progress value hasn't changed for ~1.2s, show the spinner.
        .onChange(of: progress) { _, newVal in
            lastProgressTimestamp = Date()
            if let v = newVal {
                if v != lastProgressValue {
                    isProgressStalled = false
                    lastProgressValue = v
                }
            } else {
                // When progress disappears, clear stall state
                isProgressStalled = false
                lastProgressValue = -1
                progressETASeconds = nil
            }
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            guard progress != nil else {
                isProgressStalled = false
                return
            }
            if Date().timeIntervalSince(lastProgressTimestamp) > 1.2 {
                isProgressStalled = true
            }
        }
    }

    private func formatProgressETA(_ eta: TimeInterval) -> String? {
        guard eta.isFinite, eta > 0 else { return nil }

        let rounded = Int(eta.rounded())
        let hours = rounded / 3600
        let minutes = (rounded % 3600) / 60
        let seconds = rounded % 60

        if hours > 0 {
            return String(format: "%dh %02dm", hours, minutes)
        }
        if minutes > 0 {
            return String(format: "%dm %02ds", minutes, seconds)
        }
        return String(format: "%ds", seconds)
    }
    
    @ViewBuilder
    var sidebar: some View {
        if !leafFolders.isEmpty {
            List(){
                Section(
                    header:
                        HStack {
                            Text("Selected Folders")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 10)
                ) {
                    ForEach(leafFolders.indices, id: \.self) { idx in
                        let leaf = leafFolders[idx]
                        let parentName = leaf.url.deletingLastPathComponent().lastPathComponent
                        let leafName = leaf.url.lastPathComponent
                        let rowID = leaf.id
                        
                        HStack {
                            let displayPath = "\(parentName)\\\(leafName)"
                            Image(systemName: "folder")
                                .imageScale(.medium)
                                .foregroundStyle(.secondary)
                            Text(displayPath)
                                .font(.callout)
                                .lineLimit(1)
                            
                            Spacer()
                            
                            if hoveredLeafIdx == idx {
                                Button {
                                    removeLeaf(leaf)
                                    
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .imageScale(.small)
                                        .foregroundStyle(.tertiary)
                                        .accessibilityLabel("Remove folder")
                                }
                                .buttonStyle(.borderless)
                                
                            }
                            
                        }
                        .onHover { inside in
                            hoveredLeafIdx = inside ? idx : (hoveredLeafIdx == idx ? nil : hoveredLeafIdx)
                        }
                        .padding(.vertical, 1)
                        .tag(rowID)
                    }
                    
                }
            }
            .listStyle(.sidebar)
            .listSectionSeparator(.automatic)
            .listRowSeparator(.automatic)
            .contextMenu(forSelectionType: UUID.self) { selectedIDs in
                if !selectedIDs.isEmpty && !isProcessing {
                    Button("Remove Selected (\(selectedIDs.count))") {
                        removeLeafs(withIDs: selectedIDs)
                    }
                    
                    Divider()
                    
                    Button("Select All") {
                        selectedLeafIDs = Set(leafFolders.map(\.id))
                    }
                    .disabled(selectedLeafIDs.count == leafFolders.count)
                    
                    Button("Deselect All") {
                        selectedLeafIDs.removeAll()
                    }
                    .disabled(selectedLeafIDs.isEmpty)
                } else if !isProcessing {
                    Button("Select All") {
                        selectedLeafIDs = Set(leafFolders.map(\.id))
                    }
                }
            }
            .onDeleteCommand {
                if !selectedLeafIDs.isEmpty && !isProcessing {
                    removeSelectedLeafs()
                }
            }
            
        } else {
            VStack(spacing: 12) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                
                Text("Drop folders here to start!")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                
                Button("Open Folder") {
                    selectFolders()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    var applog: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !logLines.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Label("Tip: Hide the log for faster performance", systemImage: "lightbulb")
                        .font(.footnote)

                    Spacer()
                    
                    Text("Log")
                    
                }
                Divider()
            }
            
            ZStack(alignment: .topLeading) {
                // Placeholder when empty (prevents collapse + nice UX)
                if logLines.isEmpty {
                    VStack(spacing: 12) {
                        Text("Welcome!")
                            .foregroundStyle(.secondary)
                            .font(.title2)
                        Image(systemName: "hand.wave.fill")
                            .imageScale(.large)
                        Text("This app is compatible with most image formats.\nFor video processing, only MP4 is supported.")
                            .foregroundStyle(.tertiary)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 40)
                    .padding(.horizontal, 20)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(logLines.enumerated()), id: \.offset) { index, line in
                                    Text(line)
                                        .font(.system(.footnote, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 1)
                                        .padding(.horizontal, 2)
                                        .id("log-line-\(index)")
                                }
                            }
                            .padding(.vertical, 4)
                            .id("log-bottom")
                        }
                        .onChange(of: logLines.count) { oldCount, newCount in
                            if newCount > oldCount {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        proxy.scrollTo("log-bottom", anchor: .bottom)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 180, maxHeight: .infinity)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding([.leading, .trailing], 40)
        .padding(.bottom, 20)
        .frame(minWidth: 300, maxWidth: .infinity, minHeight: 200, maxHeight: .infinity, alignment: .topLeading)
        .layoutPriority(1)
    }
    
    // MARK: - Settings Popover Content
    
    private var settingsPopoverContent: some View {
        SettingsPopoverContent(
            thumbnailSize: $thumbnailSize,
            thumbnailFolderName: $thumbnailFolderName,
            jpegQuality: $jpegQuality,
            thumbnailFormat: thumbnailFormatBinding,
            sheetFitMode: sheetFitModeBinding,
            photoSheetColumns: $photoSheetColumns,
            minImagesPerLeaf: $minImagesPerLeaf,
            videoCreateInParent: $videoCreateInParent,
            videoSheetMaxTiles: $videoSheetMaxTiles,
            videoSheetColumns: $videoSheetColumns,
            videoSheetOptimizePortraitLayout: $videoSheetOptimizePortraitLayout,
            videoSheetShowDurationOverlay: $videoSheetShowDurationOverlay,
            videoSecondsToTrim: $videoSecondsToTrim,
            onResetToDefaults: resetSettingsToDefaults,
            showSettingsPopover: $showSettingsPopover
        )
    }

    // MARK: - Settings: Wrapper Content
    private struct SettingsPopoverContent: View {
        @Binding var thumbnailSize: Int
        @Binding var thumbnailFolderName: String
        @Binding var jpegQuality: Double
        var thumbnailFormat: Binding<ThumbnailFormat>
        var sheetFitMode: Binding<SheetFitMode>
        @Binding var photoSheetColumns: Int
        @Binding var minImagesPerLeaf: Int
        @Binding var videoCreateInParent: Bool
        @Binding var videoSheetMaxTiles: Int
        @Binding var videoSheetColumns: Int
        @Binding var videoSheetOptimizePortraitLayout: Bool
        @Binding var videoSheetShowDurationOverlay: Bool
        @Binding var videoSecondsToTrim: Int
        let onResetToDefaults: () -> Void
        @Binding var showSettingsPopover: Bool

        var body: some View {
            let isBlank = thumbnailFolderName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty

            VStack(alignment: .leading, spacing: 0) {
                TabView {
                    GeneralSettingsTab(
                        thumbnailSize: $thumbnailSize,
                        thumbnailFolderName: $thumbnailFolderName,
                        jpegQuality: $jpegQuality,
                        thumbnailFormat: thumbnailFormat,
                        onResetToDefaults: onResetToDefaults,
                        showSettingsPopover: $showSettingsPopover
                    )
                    .tabItem { Label("General", systemImage: "gear") }

                    PhotoSettingsTab(
                        sheetFitMode: sheetFitMode,
                        photoSheetColumns: $photoSheetColumns,
                        minImagesPerLeaf: $minImagesPerLeaf
                    )
                    .tabItem { Label("Photos", systemImage: "photo") }

                    VideoSettingsTab(
                        videoCreateInParent: $videoCreateInParent,
                        videoSheetMaxTiles: $videoSheetMaxTiles,
                        videoSheetColumns: $videoSheetColumns,
                        videoSheetOptimizePortraitLayout: $videoSheetOptimizePortraitLayout,
                        videoSheetShowDurationOverlay: $videoSheetShowDurationOverlay,
                        videoSecondsToTrim: $videoSecondsToTrim
                    )
                    .tabItem { Label("Videos", systemImage: "video") }
                }
                .frame(height: 500) // Fixed height to prevent jumping

                Spacer()

                HStack {
                    Spacer()
                    Button("Done") {
                        if !isBlank { showSettingsPopover = false }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBlank)
                }
                .padding(.top, 16)
            }
            .padding(20)
            .frame(width: 400) // Slightly wider to accommodate tabs
        }
    }

    // MARK: - Settings: General Tab
    private struct GeneralSettingsTab: View {
        @Binding var thumbnailSize: Int
        @Binding var thumbnailFolderName: String
        @Binding var jpegQuality: Double
        var thumbnailFormat: Binding<ThumbnailFormat>
        let onResetToDefaults: () -> Void
        @Binding var showSettingsPopover: Bool

        @FocusState private var thumbSizeFocused: Bool
        @FocusState private var folderNameFocused: Bool

        var body: some View {
            let isBlank = thumbnailFolderName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading) {
                        Text("Thumbnail Size (Height):")
                            .bold()

                        Text("This sets the height thumbnails.\nApplies to photo thumbnails & contact sheets.")
                            .font(.footnote)
                    }

                    TextField("Thumbnail Size", value: $thumbnailSize, format: .number)
                        .frame(width: 60)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .focused($thumbSizeFocused)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1))
                        .overlay(
                            Capsule().stroke(
                                thumbSizeFocused ? Color.accentColor.opacity(0.9) : .clear,
                                lineWidth: thumbSizeFocused ? 2 : 0
                            )
                        )
                        .animation(.snappy(duration: 0.18), value: thumbSizeFocused)
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading) {
                        Text("Thumbnail Folder:")
                            .foregroundStyle(isBlank ? .red : .primary)
                            .bold()

                        Text("Sets the thumbnail folder for Photo thumbnails and video contact sheets. Photo contact sheets are always stored in the parent folder.")
                            .font(.footnote)
                    }

                    TextField("Folder name", text: $thumbnailFolderName)
                        .frame(width: 120)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .focused($folderNameFocused)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1))
                        .overlay(
                            Capsule().stroke(
                                (!isBlank && folderNameFocused) ? Color.accentColor.opacity(0.9) : .clear,
                                lineWidth: (!isBlank && folderNameFocused) ? 2 : 0
                            )
                        )
                        .overlay(Capsule().stroke(isBlank ? .red : .clear, lineWidth: 2))
                        .animation(.snappy(duration: 0.18), value: folderNameFocused)
                        .onSubmit {
                            if !isBlank { showSettingsPopover = false }
                        }
                }

                if isBlank {
                    Text("Folder name is required")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.leading, 116)
                }

                // Thumbnail Format Selection
                HStack {
                    VStack(alignment: .leading) {
                        Text("Thumbnail Format")
                            .bold()

                        Text("Choose the output format for generated thumbnails and contact sheets. JPEG is more compatible, HEIC offers better compression but requires newer systems.")
                            .font(.footnote)
                    }

                    Picker("", selection: thumbnailFormat) {
                        ForEach(ThumbnailFormat.allCases) { format in
                            HStack {
                                Text(format.rawValue)
                                if format == .heic && !HEICWriter.isHEICSupported {
                                    Text("(Not Supported)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.extraLarge)
                    .frame(maxWidth: .infinity)
                }
                
                VStack(alignment: .leading) {
                    Text("JPEG / HEIC Quality: \(Int(jpegQuality * 100))%")
                        .bold()
                    Slider(value: $jpegQuality, in: 0.3...1.0, step: 0.05)
                        .help("Affects thumbnails and contact sheets for both JPEG and HEIC formats")
                    Text("HEIC is about 50% smaller than JPG at similar quality.\nRecommend setting slider to 40 for HEIC & 70 for JPG.")
                        .font(.footnote)
                }
                .padding(.vertical, 4)

                if thumbnailFormat.wrappedValue == .heic && !HEICWriter.isHEICSupported {
                    Text("⚠️ HEIC format is not supported on this system. Thumbnails will be created as JPEG instead.")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(.top, 4)
                }

                Divider()
                    .padding(.top, 4)

                Button("Reset to Defaults") {
                    onResetToDefaults()
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: - Settings: Photo Tab
    private struct PhotoSettingsTab: View {
        var sheetFitMode: Binding<SheetFitMode>
        @Binding var photoSheetColumns: Int
        @Binding var minImagesPerLeaf: Int

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading) {
                    Text("Photo Contact Sheets")
                        .bold()

                    Text("Stretch - Stretch images to fit.\nCrop - Crop images to make them fit.\nPad - Create padding between images to fit. \nColumns - How many columns in a contact sheet image.")
                        .font(.footnote)
                }

                Picker("", selection: sheetFitMode) {
                    ForEach(SheetFitMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.extraLarge)
                .frame(minWidth: 200, alignment: .leading)

                VStack(alignment: .leading) {
                    Text("Columns: \(photoSheetColumns)")

                    Slider(value: Binding(
                        get: { Double(photoSheetColumns) },
                        set: { photoSheetColumns = Int($0) }
                    ), in: 1...20, step: 1)
                }
                .padding(.vertical, 4)

                Divider()

                VStack(alignment: .leading) {
                    Text("Low-Count Detector")
                        .bold()

                    Text("""
                        Photo Tools → Identify Low-Count Folders.
                        Any folder with fewer than this many images will be listed.
                        """)
                    .font(.footnote)
                }

                VStack(alignment: .leading) {
                    Text("Minimum images per folder: \(minImagesPerLeaf)")

                    Slider(
                        value: Binding(
                            get: { Double(minImagesPerLeaf) },
                            set: { minImagesPerLeaf = Int($0) }
                        ),
                        in: 1...20,
                        step: 1
                    )
                    .help("Folders with fewer than this many images will be flagged.")
                }
                .padding(.vertical, 4)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: - Settings: Video Tab
    private struct VideoSettingsTab: View {
        @Binding var videoCreateInParent: Bool
        @Binding var videoSheetMaxTiles: Int
        @Binding var videoSheetColumns: Int
        @Binding var videoSheetOptimizePortraitLayout: Bool
        @Binding var videoSheetShowDurationOverlay: Bool
        @Binding var videoSecondsToTrim: Int

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Video Contact Sheets")
                        .bold()

                    VStack(alignment: .leading) {
                        Toggle("Create in Parent", isOn: $videoCreateInParent)
                            .toggleStyle(.switch)
                        
                        Text("""
                            If enabled, video contact sheets will be created in the parent folder of each video subfolder. If disabled, they will be created in the thumbnail subfolder.
                            """)
                        .font(.footnote)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                    }
                    .padding(.vertical, 2)
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Show Video Length", isOn: $videoSheetShowDurationOverlay)
                            .toggleStyle(.switch)

                        Text("Adds the full video duration in mm:ss to the bottom-right corner of generated video contact sheets.")
                            .font(.footnote)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                    

                    VStack(alignment: .leading) {
                        Text("Max Tiles: \(videoSheetMaxTiles)")
                        Slider(value: Binding(
                            get: { Double(videoSheetMaxTiles) },
                            set: { videoSheetMaxTiles = Int($0) }
                        ), in: 3...40, step: 1)
                        Text("Higher values show more moments from the video. Some videos may use fewer tiles to keep the sheet looking clean.")
                            .font(.footnote)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading) {
                        Text("Max Columns: \(videoSheetColumns)")
                        Slider(value: Binding(
                            get: { Double(videoSheetColumns) },
                            set: { videoSheetColumns = Int($0) }
                        ), in: 1...20, step: 1)
                        Text("Controls how wide the contact sheet can be. Lower values make it taller, higher values make it wider.")
                            .font(.footnote)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Optimize Portrait Layout", isOn: $videoSheetOptimizePortraitLayout)
                            .toggleStyle(.switch)

                        Text("Makes portrait video sheets less tall by allowing more columns when needed.")
                            .font(.footnote)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)

                    Divider()

                    HStack {
                        Text("Trimming")
                            .bold()

                        Image(systemName: "info.circle")
                            .foregroundColor(.accentColor)
                            .help("Sets how many seconds to remove from the beginning / end of videos when using 'Trim First N Seconds' tool.")
                    }

                    VStack(alignment: .leading) {
                        Text("Seconds to Trim: \(videoSecondsToTrim)")

                        Slider(
                            value: Binding(
                                get: { Double(videoSecondsToTrim) },
                                set: { videoSecondsToTrim = Int($0) }
                            ),
                            in: 1...60,
                            step: 1
                        )
                        .help("Choose how many seconds to trim from the beginning or end of videos (1-60 seconds).")
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.trailing, 14)
                .padding(.bottom, 8)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
    
    // MARK: - Toolbar
    var shortVideoManagerSheet: some View {
        ShortVideoManagerView(
            thresholdSeconds: $shortVideoDurationSeconds,
            results: shortVideoResults,
            selection: $selectedShortVideoIDs,
            isScanning: isScanningShortVideos,
            showDeleteConfirmation: $showConfirmDeleteShortVideos,
            pendingDeleteCount: pendingShortVideoDeletion.count,
            onScan: { scanShortVideos() },
            onDeleteSelected: { confirmDeleteSelectedShortVideos() },
            onDeleteAll: { confirmDeleteAllShortVideos() },
            onDeleteSingle: { deleteSingleShortVideo($0) },
            onConfirmDelete: { Task { await actuallyDeleteShortVideos() } },
            onClose: { showShortVideoManager = false }
        )
        .frame(minWidth: 760, minHeight: 520)
    }

    private struct ShortVideoManagerView: View {
        @Binding var thresholdSeconds: Double
        let results: [ShortVideoItem]
        @Binding var selection: Set<URL>
        let isScanning: Bool
        @Binding var showDeleteConfirmation: Bool
        let pendingDeleteCount: Int
        let onScan: () -> Void
        let onDeleteSelected: () -> Void
        let onDeleteAll: () -> Void
        let onDeleteSingle: (ShortVideoItem) -> Void
        let onConfirmDelete: () -> Void
        let onClose: () -> Void

        private var thresholdMinutes: String {
            String(format: "%.1f", thresholdSeconds / 60.0)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Short Videos")
                            .font(.title2.weight(.semibold))
                        Text("Scan loaded video folders, review clips under the threshold, then delete the ones you don't want.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Done") {
                        onClose()
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Threshold: \(thresholdMinutes) min")
                            .font(.headline)
                        Spacer()
                        if isScanning {
                            ProgressView()
                                .controlSize(.small)
                            Text("Scanning…")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(results.count) match\(results.count == 1 ? "" : "es")")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Slider(value: $thresholdSeconds, in: 30...600, step: 30)
                        .disabled(isScanning)

                    HStack {
                        Text("30s")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("10min")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                HStack {
                    Button {
                        onScan()
                    } label: {
                        Label(isScanning ? "Scanning" : "Scan Short Videos", systemImage: "magnifyingglass")
                    }
                    .disabled(isScanning)

                    Button(role: .destructive) {
                        onDeleteSelected()
                    } label: {
                        Label("Delete Selected", systemImage: "trash")
                    }
                    .disabled(isScanning || selection.isEmpty)

                    Button(role: .destructive) {
                        onDeleteAll()
                    } label: {
                        Label("Delete All", systemImage: "trash.slash")
                    }
                    .disabled(isScanning || results.isEmpty)

                    Spacer()

                    if !selection.isEmpty {
                        Text("\(selection.count) selected")
                            .foregroundStyle(.secondary)
                    }
                }

                List(selection: $selection) {
                    ForEach(results) { item in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.url.lastPathComponent)
                                    .font(.headline)
                                    .lineLimit(1)
                                Text(item.url.deletingLastPathComponent().path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Text(shortVideoDurationText(item.duration))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)

                            Button("Reveal") {
                                NSWorkspace.shared.activateFileViewerSelecting([item.url])
                            }
                            .buttonStyle(.borderless)

                            Button(role: .destructive) {
                                onDeleteSingle(item)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .tag(item.id)
                    }
                }
                .overlay {
                    if !isScanning && results.isEmpty {
                        ContentUnavailableView(
                            "No Short Videos",
                            systemImage: "film",
                            description: Text("Run a scan to populate this list.")
                        )
                    }
                }
            }
            .padding(20)
            .alert("Delete short videos?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Move to Trash", role: .destructive) {
                    onConfirmDelete()
                }
            } message: {
                Text("This will move \(pendingDeleteCount) short video(s) to the Trash.")
            }
        }

        private func shortVideoDurationText(_ seconds: Double) -> String {
            if seconds < 60 {
                return String(format: "%.1fs", seconds)
            }

            let minutes = Int(seconds / 60)
            let remainingSeconds = seconds.truncatingRemainder(dividingBy: 60)
            return String(format: "%dm %.1fs", minutes, remainingSeconds)
        }
    }

    @ToolbarContentBuilder
    var buildToolbar: some ToolbarContent {
        // LEFT: Open (folder picker), Reset (clear UI), Settings (popover)
        ToolbarItemGroup(placement: .navigation) {
            Button {
                selectFolders()
            } label: {
                Label("Open Folder", systemImage: "folder")
            }
            .disabled(isProcessing)
            .keyboardShortcut("o", modifiers: [.command])
            
            Button {
                clearAll()
            } label: {
                Label("Clear View", systemImage: "arrow.counterclockwise")
            }
            .disabled(isProcessing)
            .help("Clear selections and logs (does not delete files).")
            
            Button {
                showSettingsPopover = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .disabled(isProcessing)
            .popover(isPresented: $showSettingsPopover) {
                settingsPopoverContent
                    .interactiveDismissDisabled(thumbnailFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Button {
                showLog.toggle()
                appendLog("Log Shown")
            } label: {
                Label(showLog ? "Hide Log" : "Show Log",
                      systemImage: showLog ? "eye" : "eye.slash")
            }
            .help(showLog ? "Hide the in‑app log" : "Show the in‑app log")
        }
        
        ToolbarItem(placement: .principal){
            Spacer()
        }
        
        // RIGHT: Primary actions.
        ToolbarItemGroup(placement: .primaryAction) {
            if isProcessing {
                Button(role: .cancel) { cancelCurrentWork() } label: {
                    Label("Cancel", systemImage: "xmark.circle.fill")
                        .symbolRenderingMode(.multicolor)
                }
                .tint(.red)
                .keyboardShortcut(".", modifiers: [.command]) // Cmd+.
                .help("Stop the current job")
            } else {
                Button { startPhotoThumbnailProcessing() } label: {
                    Label("Process Thumbnails", systemImage: "photo.on.rectangle")
                }
                .disabled(!photoActionsEnabled)
                
                Button { makePhotoSheets() } label: {
                    Label("Create Contact Sheets", systemImage: "tablecells")
                }
                .disabled(leafFolders.isEmpty)
                .help("Creates Contact Sheets for photos or videos.")
                
                Button(role: .destructive) { deleteThumbFolders() } label: {
                    Label("Delete Thumbnails", systemImage: "trash")
                }
                .disabled(leafFolders.isEmpty)
            }
        }
    }
    
}
