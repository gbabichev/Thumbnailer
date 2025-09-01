/*
 
 AppMenuCommands.swift
 Thumbnailer
 
 Menu Bar Actions
 
 George Babichev
 
 */

import SwiftUI

struct AppActions {
    var open: () -> Void
    var process: () -> Void
    var delete: () -> Void
    var clear: () -> Void
    var makeSheet: () -> Void

    // Log-related actions
    var openLogFile: () -> Void
    var openLogFolder: () -> Void

    // Photo Tools
    var scanJPG: () -> Void
    let scanHEIC: () -> Void
    var convertJPG: () -> Void
    var convertHEIC: () -> Void
    var identifyLowFiles: () -> Void
    var deleteContactlessLeafs: () -> Void
    var validatePhotoThumbs: () -> Void

    // Video Tools
    var identifyShortVideos: () -> Void
    var scanNonMP4Videos: () -> Void
    var trimVideoIntros: () -> Void
    var trimVideoOutros: () -> Void
    var deleteContactlessVideoLeafs: () -> Void
    var moveVideosToParent: () -> Void
    
    // Simplified capability flags
    var isProcessing: Bool = false
    var hasPhotoLeafs: Bool = false
    var hasVideoLeafs: Bool = false
    var logFileExists: Bool = false
    var logFolderExists: Bool = false
    
    // Computed properties for menu enablement
    var canDoPhotoActions: Bool { hasPhotoLeafs && !isProcessing }
    var canDoVideoActions: Bool { hasVideoLeafs && !isProcessing }
    var canDelete: Bool { !isProcessing && (hasPhotoLeafs || hasVideoLeafs) }
    var canMakeSheets: Bool { (hasPhotoLeafs || hasVideoLeafs) && !isProcessing }
}

private struct AppActionsKey: FocusedValueKey {
    typealias Value = AppActions
}

extension FocusedValues {
    var appActions: AppActions? {
        get { self[AppActionsKey.self] }
        set { self[AppActionsKey.self] = newValue }
    }
}

struct AppMenuCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.appActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button {
                actions?.open()
            } label: {
                Label("Open…", systemImage: "folder")
            }
            .keyboardShortcut("o", modifiers: [.command])
        }

        CommandMenu("Actions") {
            Button {
                actions?.process()
            } label: {
                Label("Create Thumbnails", systemImage: "photo.on.rectangle")
            }
            .keyboardShortcut("p", modifiers: [.command])
            .disabled(!(actions?.canDoPhotoActions ?? false))

            Button {
                actions?.makeSheet()
            } label: {
                Label("Create Contact Sheets", systemImage: "tablecells")
            }
            .keyboardShortcut("m", modifiers: [.command])
            .disabled(!(actions?.canMakeSheets ?? false))

            Button {
                actions?.delete()
            } label: {
                Label("Delete Thumbnail Folder", systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(!(actions?.canDelete ?? false))
            
            Divider()

            Button {
                actions?.clear()
            } label: {
                Label("Clear View", systemImage: "arrow.counterclockwise")
            }
            .keyboardShortcut("l", modifiers: [.command])
            .disabled(actions?.isProcessing ?? true)

            Divider()

            // Log Section
            Button {
                actions?.openLogFile()
            } label: {
                Label("Open Log File", systemImage: "doc.text")
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(!(actions?.logFileExists ?? false))

            Button {
                actions?.openLogFolder()
            } label: {
                Label("Open Log File Folder", systemImage: "folder")
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(!(actions?.logFolderExists ?? false))
        }

        CommandMenu("Photo Tools") {
            Button {
                actions?.scanJPG()
            } label: {
                Label("Scan for Non-JPG", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("j", modifiers: [.command, .shift]) // ⌘⇧J
            .disabled(!(actions?.canDoPhotoActions ?? false))
            
            Button {
                actions?.scanHEIC()
            } label: {
                Label("Scan for Non-HEIC", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("e", modifiers: [.command, .shift]) // ⌘⇧E
            .disabled(!(actions?.canDoPhotoActions ?? false))
            
            Divider()
            
            Button {
                actions?.convertJPG()
            } label: {
                Label("Convert to JPG", systemImage: "arrow.2.circlepath")
            }
            .keyboardShortcut("k", modifiers: [.command, .shift]) // ⌘ ⇧ K
            .disabled(!(actions?.canDoPhotoActions ?? false))
            
            Button {
                actions?.convertHEIC()
            } label: {
                Label("Convert to HEIC", systemImage: "arrow.2.circlepath")
            }
            .keyboardShortcut("h", modifiers: [.command, .shift]) // ⌘ ⇧ H
            .disabled(!(actions?.canDoPhotoActions ?? false))
            
            Divider()
            
            Button {
                actions?.identifyLowFiles()
            } label: {
                Label("Identify Low-Count Folders", systemImage: "exclamationmark.triangle")
            }
            .keyboardShortcut("i", modifiers: [.command, .shift]) // ⌘⇧I
            .disabled(!(actions?.canDoPhotoActions ?? false))
            
            Button {
                actions?.validatePhotoThumbs()
            } label: {
                Label("Validate Photo/Thumb Counts", systemImage: "checkmark.seal")
            }
            .keyboardShortcut("v", modifiers: [.command, .shift]) // ⌘⇧V
            .disabled(!(actions?.canDoPhotoActions ?? false))
            
            Divider()
            
            Button {
                actions?.deleteContactlessLeafs()
            } label: {
                Label("Delete Contactless Leafs", systemImage: "trash.slash")
            }
            .keyboardShortcut("d", modifiers: [.command, .shift]) // ⌘⇧D
            .disabled(!(actions?.canDoPhotoActions ?? false))
            

        }

        CommandMenu("Video Tools") {
            Button {
                actions?.scanNonMP4Videos()
            } label: {
                Label("Scan for Non-MP4", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("4", modifiers: [.command, .shift]) // ⌘⇧4
            //.keyboardShortcut("m", modifiers: [.command, .shift]) // ⌘⇧M
            .disabled(!(actions?.canDoVideoActions ?? false))
            .help("Scans and logs videos that are not MP4.")
            
            Button {
                actions?.identifyShortVideos()
            } label: {
                Label("Identify Short Videos", systemImage: "film")
            }
            .keyboardShortcut("v", modifiers: [.command, .shift]) // ⌘⇧V
            .disabled(!(actions?.canDoVideoActions ?? false))

            Divider()
            
            Button {
                actions?.trimVideoIntros()
            } label: {
                Label("Trim Video Intros", systemImage: "scissors")
            }
            .keyboardShortcut("i", modifiers: [.command, .option]) // ⌘⌥I
            .disabled(!(actions?.canDoVideoActions ?? false))
            .help("Remove the first few seconds from all videos")

            Button {
                actions?.trimVideoOutros()
            } label: {
                Label("Trim Video Outros", systemImage: "scissors")
            }
            .keyboardShortcut("o", modifiers: [.command, .option]) // ⌘⌥O
            .disabled(!(actions?.canDoVideoActions ?? false))
            .help("Remove the last few seconds from all videos")
            
            Divider()
            
            Button {
                actions?.moveVideosToParent()
            } label: {
                Label("Move Videos to Parent", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .keyboardShortcut("m", modifiers: [.command, .shift]) // ⌘⇧M
            .disabled(!(actions?.canDoVideoActions ?? false))
            .help("Move video files from leaf folders to their parent directories")
            
            Divider()
            
            Button {
                actions?.deleteContactlessVideoLeafs()
            } label: {
                Label("Delete Contactless Videos", systemImage: "trash.slash")
            }
            .keyboardShortcut("r", modifiers: [.command, .shift]) // ⌘⇧R (changed from V since V is taken)
            .disabled(!(actions?.canDoVideoActions ?? false))
            .help("Delete video files without mathching sheets in a thumbnail folder.")
        }
        
        CommandGroup(replacing: .appInfo) {
            Button {
                openWindow(id: "AboutWindow")
            } label: {
                Label("About Thumbnailer", systemImage: "info.circle")
            }
        }
        
        CommandGroup(replacing: .help) {
            Button {
                if let url = URL(string: "https://github.com/gbabichev/Thumbnailer") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Thumbnailer Help", systemImage: "questionmark.circle")
            }
            .keyboardShortcut("?", modifiers: [.command])
        }
    }
}
