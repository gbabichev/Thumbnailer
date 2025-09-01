/*
 
 ContactlessPhotoRemover.swift
 Thumbnailer
 
   Finds photo leaf folders that do NOT have a sibling "<leaf>.jpg" or "<leaf>.jpeg"
   in the parent folder, and moves those leaf folders to the Trash.
 
   Assumptions: Your photo contact sheets live in the parent like:
       /parent/leaf1/         <-- folder (leaf)
       /parent/leaf1.jpg      <-- contact sheet (sibling)
 
 George Babichev
 
 */

import Foundation

let contactSheetExts: Set<String> = ["jpg", "jpeg", "heic"]

func hasSiblingContactSheet(for leafURL: URL, fm: FileManager) -> Bool {
    let parent = leafURL.deletingLastPathComponent()
    let base   = leafURL.lastPathComponent

    for ext in contactSheetExts {
        let p = parent.appendingPathComponent(base).appendingPathExtension(ext)
        if fm.fileExists(atPath: p.path) { return true }
    }
    return false
}

func leafsMissingSheets(in leaves: [URL]) -> [URL] {
    let fm = FileManager.default
    var victims: [URL] = []
    victims.reserveCapacity(leaves.count)

    for leaf in leaves {
        // Only consider directories
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: leaf.path, isDirectory: &isDir), isDir.boolValue else { continue }

        if !hasSiblingContactSheet(for: leaf, fm: fm) {
            victims.append(leaf)
        }
    }
    // Human-friendly sort (like natsort-lite)
    victims.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    return victims
}

func trash(_ urls: [URL], log: @escaping (String) -> Void) -> (ok: Int, fail: Int) {
    let fm = FileManager.default
    var ok = 0, fail = 0

    for url in urls {
        do {
            var trashedURL: NSURL?
            try fm.trashItem(at: url, resultingItemURL: &trashedURL)
            ok += 1
            log("     🗑️ Trashed: \(url.path)")
        } catch {
            fail += 1
            log("     ❌  Failed to trash: \(url.lastPathComponent) — \(error.localizedDescription)")
        }
    }
    return (ok, fail)
}
