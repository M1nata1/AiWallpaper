import CoreGraphics
import Foundation

/// A decoded cursor bound to a macOS role.
public struct CursorAssignment {
    public let role: CursorRole
    public let sourceURL: URL
    public let decoded: DecodedCursor
}

/// A set of cursors ready to apply to the system, built from a folder of Windows cursor files.
public struct CursorTheme {
    public var name: String
    public var assignments: [CursorAssignment]
    /// Files found that no macOS role matched (e.g. Pin, Person, Handwriting).
    public var unmatchedFiles: [URL]
    /// Whether the mapping came from a Windows install.inf rather than from file names.
    public var usedInf: Bool = false

    public static let cursorExtensions: Set<String> = ["ani", "cur", "ico", "png", "tiff", "tif"]

    /// Builds a theme from a folder. If it contains a Windows install.inf, the roles are taken
    /// from it (authoritative); otherwise cursors are matched to roles by file name.
    public static func load(fromFolder folder: URL) -> CursorTheme {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []

        if let infURL = WindowsCursorInf.find(in: folder),
           let text = WindowsCursorInf.readText(infURL) {
            let entries = WindowsCursorInf.parse(text)
            if !entries.isEmpty {
                return loadFromScheme(entries, folder: folder, name: folder.lastPathComponent)
            }
        }
        return loadByFileName(files, name: folder.lastPathComponent)
    }

    // MARK: - From install.inf

    private static func loadFromScheme(_ entries: [WindowsCursorInf.Entry], folder: URL, name: String) -> CursorTheme {
        var assignments: [CursorRole: CursorAssignment] = [:]
        var unmatched: [URL] = []
        var cache: [String: DecodedCursor?] = [:]

        func decoded(_ fileName: String) -> DecodedCursor? {
            if let hit = cache[fileName] { return hit }
            let result = CursorImageDecoder.decode(contentsOf: folder.appendingPathComponent(fileName))
            cache[fileName] = result
            return result
        }

        for entry in entries {
            let fileURL = folder.appendingPathComponent(entry.fileName)
            let allRoles = CursorRole.roles(forRegistryName: entry.registryName)
            guard !allRoles.isEmpty else {
                // Known Windows role with no macOS counterpart (NWPen, UpArrow, Person, Pin).
                if FileManager.default.fileExists(atPath: fileURL.path), !unmatched.contains(fileURL) {
                    unmatched.append(fileURL)
                }
                continue
            }
            let roles = allRoles.filter { assignments[$0] == nil }
            guard !roles.isEmpty, let cursor = decoded(entry.fileName) else { continue }
            for role in roles {
                assignments[role] = CursorAssignment(role: role, sourceURL: fileURL, decoded: cursor)
            }
        }

        return CursorTheme(
            name: name,
            assignments: CursorRole.all.compactMap { assignments[$0] },
            unmatchedFiles: unmatched,
            usedInf: true
        )
    }

    // MARK: - From file names (no .inf)

    private static func loadByFileName(_ files: [URL], name: String) -> CursorTheme {
        var assignments: [CursorRole: CursorAssignment] = [:]
        var unmatched: [URL] = []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard cursorExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            let allRoles = CursorRole.matchingRoles(fileStem: stem)
            guard !allRoles.isEmpty else {
                unmatched.append(url)
                continue
            }
            let roles = allRoles.filter { assignments[$0] == nil }
            guard !roles.isEmpty, let decoded = CursorImageDecoder.decode(contentsOf: url) else { continue }
            for role in roles {
                assignments[role] = CursorAssignment(role: role, sourceURL: url, decoded: decoded)
            }
        }
        return CursorTheme(
            name: name,
            assignments: CursorRole.all.compactMap { assignments[$0] },
            unmatchedFiles: unmatched,
            usedInf: false
        )
    }
}
