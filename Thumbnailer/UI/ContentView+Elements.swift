//
//  ContentView+Panels.swift
//  Thumbnailer
//
//  Created by George Babichev on 8/24/25.
//

import SwiftUI
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
                Text("\(Int((p * 100).rounded()))%")
                    .foregroundStyle(.secondary)
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
            videoSecondsToTrim: $videoSecondsToTrim,
            shortVideoDurationSeconds: $shortVideoDurationSeconds,
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
        @Binding var videoSecondsToTrim: Int
        @Binding var shortVideoDurationSeconds: Double
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
                        videoSecondsToTrim: $videoSecondsToTrim,
                        shortVideoDurationSeconds: $shortVideoDurationSeconds
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

                VStack(alignment: .leading) {
                    Text("JPEG / HEIC Quality: \(Int(jpegQuality * 100))%")
                        .bold()
                    Slider(value: $jpegQuality, in: 0.3...1.0, step: 0.05)
                        .help("Affects thumbnails and contact sheets for both JPEG and HEIC formats")
                    Text("HEIC is about 50% smaller than JPG at similar quality.\nRecommend setting slider to 40 for HEIC & 70 for JPG.")
                        .font(.footnote)
                }
                .padding(.vertical, 4)

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

                if thumbnailFormat.wrappedValue == .heic && !HEICWriter.isHEICSupported {
                    Text("⚠️ HEIC format is not supported on this system. Thumbnails will be created as JPEG instead.")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(.top, 4)
                }
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
        @Binding var videoSecondsToTrim: Int
        @Binding var shortVideoDurationSeconds: Double

        var body: some View {
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

                VStack(alignment: .leading) {
                    Text("Max Tiles: \(videoSheetMaxTiles)")
                    Slider(value: Binding(
                        get: { Double(videoSheetMaxTiles) },
                        set: { videoSheetMaxTiles = Int($0) }
                    ), in: 3...40, step: 1)
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading) {
                    Text("Columns: \(videoSheetColumns)")
                    Slider(value: Binding(
                        get: { Double(videoSheetColumns) },
                        set: { videoSheetColumns = Int($0) }
                    ), in: 1...20, step: 1)
                }
                .padding(.vertical, 4)

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

                VStack(alignment: .leading) {
                    let minutes = shortVideoDurationSeconds / 60.0
                    Text("Short Video Threshold: \(String(format: "%.1f", minutes)) min")

                    Slider(value: $shortVideoDurationSeconds, in: 30...600, step: 30)
                        .help("Videos shorter than this duration will be flagged as 'short videos'")

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
                .padding(.vertical, 4)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
    
    // MARK: - Toolbar
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
                    Label("Cancel", systemImage: "xmark.circle")
                }
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

