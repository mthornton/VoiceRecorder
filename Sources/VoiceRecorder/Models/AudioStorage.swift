import Foundation

/// Owns the on-disk location of recorded audio.
///
/// Audio lives in Application Support rather than Documents so it isn't exposed
/// through file sharing, and it's explicitly excluded from backup — these files
/// are large and the user can always re-export what they care about.
enum AudioStorage {
    static let recordingsDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Recordings", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }()

    static func fileName(for id: UUID) -> String {
        "\(id.uuidString).\(RecordingFormat.fileExtension)"
    }

    static func url(forFileName name: String) -> URL {
        recordingsDirectory.appendingPathComponent(name)
    }

    static func delete(fileName: String) {
        try? FileManager.default.removeItem(at: url(forFileName: fileName))
    }

    /// Size on disk, for the detail view. Returns nil if the file is missing —
    /// which is itself worth surfacing rather than silently showing zero.
    static func fileSize(forFileName name: String) -> Int64? {
        let path = url(forFileName: name).path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.int64Value
    }
}
