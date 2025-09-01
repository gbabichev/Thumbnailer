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
        // Resolve <AppName> dynamically and sanitize it for use in a path segment
        let info = Bundle.main.infoDictionary
        let appName =
            (info?["CFBundleDisplayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (info?["CFBundleName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ProcessInfo.processInfo.processName
        let safeAppName = appName.replacingOccurrences(of: "/", with: "-")

        // Build: ~/Library/Logs/<AppName>/latest.txt
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let logURL = base
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(safeAppName, isDirectory: true)
            .appendingPathComponent("latest.txt")

        do {
            let fm = FileManager.default
            let dir = logURL.deletingLastPathComponent()

            // Ensure the Logs/<AppName> folder exists
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }

            // Ensure the log file exists
            if !fm.fileExists(atPath: logURL.path) {
                fm.createFile(atPath: logURL.path, contents: nil)
            }

            // Append all lines in one write operation
            let fh = try FileHandle(forWritingTo: logURL)
            defer { try? fh.close() }
            try fh.seekToEnd()

            let combined = lines.joined(separator: "\n") + "\n"
            if let data = combined.data(using: .utf8) {
                try fh.write(contentsOf: data)
            }
        } catch {
            // Failsafe: log to Console so failures are visible during development
            NSLog("AppLog writeLinesToDisk failed: %@", String(describing: error))
        }
    }
}
