//
//  SWJNRecordingStore.swift
//  Paintbrush
//
//  Where recordings live: one log per recording in Application Support, so
//  saved images stay ordinary PNG, JPEG and so on. An image is linked to its
//  recording by an extended attribute on the file (follows renames and moves)
//  with a path index as a fallback for tools that strip attributes.
//

import Foundation

nonisolated enum SWJNRecordingStore {
    private static let attributeName = "com.soggywaffles.paintbrush.recording"
    private static let indexName = "index.plist"
    private static let fileExtension = "pbrec"

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Paintbrush/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func logURL(for id: String) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension(fileExtension)
    }

    static func newID() -> String { UUID().uuidString }

    /// The recording linked to the image at `url`, if its log still exists.
    static func recordingID(for url: URL) -> String? {
        let candidates = [readAttribute(at: url), index[url.resolvingSymlinksInPath().path]].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: logURL(for: $0).path) }
    }

    static func link(_ url: URL, to id: String) {
        writeAttribute(id, at: url)
        var entries = index
        entries[url.resolvingSymlinksInPath().path] = id
        index = entries
    }

    /// Copies a recording under a new id (Save As keeps the old file's history intact).
    static func fork(_ id: String) -> String? {
        let newID = newID()
        do {
            try FileManager.default.copyItem(at: logURL(for: id), to: logURL(for: newID))
            return newID
        } catch {
            return nil
        }
    }

    static func delete(_ id: String) {
        try? FileManager.default.removeItem(at: logURL(for: id))
    }

    /// Removes logs that were never linked to a saved image and are a day old
    /// (untitled documents that were thrown away or lost in a crash).
    static func removeOrphans() {
        let linked = Set(index.values)
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files where file.pathExtension == fileExtension {
            let id = file.deletingPathExtension().lastPathComponent
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if !linked.contains(id) && modified < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }

    // MARK: Index

    private static var indexURL: URL { directory.appendingPathComponent(indexName) }

    private static var index: [String: String] {
        get {
            guard let data = try? Data(contentsOf: indexURL),
                  let entries = try? PropertyListDecoder().decode([String: String].self, from: data) else { return [:] }
            return entries
        }
        set {
            if let data = try? PropertyListEncoder().encode(newValue) {
                try? data.write(to: indexURL, options: .atomic)
            }
        }
    }

    // MARK: Extended attribute

    private static func readAttribute(at url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path else { return nil }
            let size = getxattr(path, attributeName, nil, 0, 0, 0)
            guard size > 0, size < 256 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            guard getxattr(path, attributeName, &buffer, size, 0, 0) == size else { return nil }
            return String(bytes: buffer, encoding: .utf8)
        }
    }

    private static func writeAttribute(_ value: String, at url: URL) {
        let bytes = Array(value.utf8)
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            _ = setxattr(path, attributeName, bytes, bytes.count, 0, 0)
        }
    }
}
