/*
 
 MediaScan.swift
 Thumbnailer
 
   AppLogWriter.swift — buffered logger with batch writes
   Appends batches to ~/Library/Logs/<AppName>/latest.txt
 
 George Babichev
 
 */

import Foundation

actor AppLogWriter {
    private var buffer: [String] = []
    private var flushTask: Task<Void, Never>?
    private static let maxLogFileSizeBytes = 1_048_576
    private static let maxRotatedLogFiles = 5
    
    // DateFormatter is expensive to create, so we keep one per actor
    private let timestampFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()
    
    private static let shared = AppLogWriter()
    
    /// Adds a line to the buffer. Writes are batched and flushed periodically.
    static func appendToFile(_ line: String) {
        Task {
            await shared.addToBuffer(line)
        }
    }
    
    // MARK: - Private Implementation
    
    private func addToBuffer(_ line: String) {
        let timestamp = timestampFormatter.string(from: Date())
        buffer.append("\(timestamp)::: \(line)")
        
        // Schedule a flush if we don't have one pending
        if flushTask == nil {
            scheduleFlush()
        }
        
        // Emergency flush if buffer gets too large
        if buffer.count >= 100 {
            Task { flushBuffer() }
        }
    }
    
    private func scheduleFlush() {
        flushTask = Task {
            // Wait a bit to batch multiple log entries
            try? await Task.sleep(for: .seconds(2))
            flushBuffer()
        }
    }
    
    private func flushBuffer() {
        guard !buffer.isEmpty else { return }
        
        let linesToWrite = buffer
        buffer.removeAll()
        flushTask = nil
        
        // Write in background
        Task.detached(priority: .utility) {
            await Self.writeLinesToDisk(linesToWrite)
        }
    }
    
    private static func writeLinesToDisk(_ lines: [String]) async {
        do {
            let fm = FileManager.default
            let logURL = logFileURL()
            let dir = logURL.deletingLastPathComponent()

            // Ensure the Logs/<AppName> folder exists
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }

            // Ensure the log file exists
            if !fm.fileExists(atPath: logURL.path) {
                fm.createFile(atPath: logURL.path, contents: nil)
            }

            let pendingData = Data((lines.joined(separator: "\n") + "\n").utf8)
            try rotateIfNeeded(
                at: logURL,
                directory: dir,
                incomingBytes: pendingData.count,
                fileManager: fm
            )

            // Append all lines in one write operation
            let fh = try FileHandle(forWritingTo: logURL)
            defer { try? fh.close() }
            try fh.seekToEnd()

            try fh.write(contentsOf: pendingData)
        } catch {
            // Failsafe: log to Console so failures are visible during development
            NSLog("AppLog writeLinesToDisk failed: %@", String(describing: error))
        }
    }
    
    // Add these methods to your AppLogWriter actor in LogWriter.swift

    // MARK: - Read Helpers
    private static func logFileURL() -> URL {
        let info = Bundle.main.infoDictionary
        let appName =
            (info?["CFBundleDisplayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (info?["CFBundleName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ProcessInfo.processInfo.processName
        let safeAppName = appName.replacingOccurrences(of: "/", with: "-")
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(safeAppName, isDirectory: true)
            .appendingPathComponent("latest.txt")
    }

    private static func rotateIfNeeded(
        at logURL: URL,
        directory: URL,
        incomingBytes: Int,
        fileManager: FileManager
    ) throws {
        let currentSize = (try? fileManager.attributesOfItem(atPath: logURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard currentSize > 0,
              currentSize + incomingBytes > maxLogFileSizeBytes else {
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())
        let rotatedURL = directory.appendingPathComponent("latest-\(stamp).txt")

        if fileManager.fileExists(atPath: rotatedURL.path) {
            try? fileManager.removeItem(at: rotatedURL)
        }
        try fileManager.moveItem(at: logURL, to: rotatedURL)
        fileManager.createFile(atPath: logURL.path, contents: nil)

        try pruneRotatedLogs(in: directory, fileManager: fileManager)
    }

    private static func pruneRotatedLogs(in directory: URL, fileManager: FileManager) throws {
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        let rotatedLogs = files
            .filter { $0.lastPathComponent.hasPrefix("latest-") && $0.pathExtension == "txt" }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }

        guard rotatedLogs.count > maxRotatedLogFiles else { return }
        for url in rotatedLogs.dropFirst(maxRotatedLogFiles) {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Read the entire log file and return lines (without trailing empty line)
    nonisolated static func readAll() -> [String]? {
        let url = logFileURL()
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var lines = text.components(separatedBy: "\n")
        if let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines
    }

    /// Read the last N lines of the log file efficiently (fallback to full read)
    nonisolated static func readTail(_ count: Int) -> [String]? {
        let url = logFileURL()
        guard let fh = try? FileHandle(forReadingFrom: url) else {
            return []
        }
        defer { try? fh.close() }

        // Try to read a chunk from the end to avoid loading the whole file
        let chunkSize = 512 * 1024 // 512 KB
        let fileSize = (try? fh.seekToEnd()) ?? 0
        let start = fileSize > chunkSize ? fileSize - UInt64(chunkSize) : 0
        if start > 0 {
            try? fh.seek(toOffset: start)
        } else {
            try? fh.seek(toOffset: 0)
        }

        let data = try? fh.readToEnd()
        guard let data, !data.isEmpty else { return [] }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var lines = text.components(separatedBy: "\n")
        if let last = lines.last, last.isEmpty { lines.removeLast() }
        if lines.count > count {
            lines = Array(lines.suffix(count))
        }
        return lines
    }
    
}
