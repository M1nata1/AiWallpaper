import AppKit
import Combine
import CursorCore
import Foundation

/// Drives the cursor section of the Settings window: the chosen pack, the preview, and the
/// Apply / Reset actions over `SystemCursorController`.
/// One cursor ready to show animated in the settings preview.
struct CursorPreview: Identifiable {
    let id: String
    let name: String
    let frames: [NSImage]
    /// Seconds per frame, matching `frames`; empty or single-frame means static.
    let durations: [Double]
}

@MainActor
final class CursorSettings: ObservableObject {
    @Published private(set) var theme: CursorTheme?
    @Published private(set) var previews: [CursorPreview] = []
    @Published private(set) var isApplied: Bool
    @Published private(set) var status: String?

    private let controller = SystemCursorController()
    private let defaults = UserDefaults.standard
    /// Base on-screen size. The pointer is enlarged from here by System Settings →
    /// Accessibility → Pointer, so the app offers no size control of its own.
    private let pointSize: Double = 28

    private enum Key {
        static let folderPath = "cursorFolderPath"
    }

    init() {
        isApplied = controller.isApplied
        if let path = defaults.string(forKey: Key.folderPath) {
            loadFolder(URL(fileURLWithPath: path), remember: false)
        }
        if let name = controller.appliedThemeName, theme == nil {
            status = String(format: NSLocalizedString("“%@” is applied.", comment: "Cursor status"), name)
        }
    }

    var folderName: String? { theme?.name }

    var mappedCount: Int { theme?.assignments.count ?? 0 }

    var unmatchedNames: [String] {
        (theme?.unmatchedFiles ?? []).map { $0.deletingPathExtension().lastPathComponent }
    }

    /// Builds the animated preview of every mapped cursor, once per loaded pack.
    private static func makePreviews(_ theme: CursorTheme) -> [CursorPreview] {
        theme.assignments.map { assignment in
            let size = NSSize(width: assignment.decoded.pixelSize.width, height: assignment.decoded.pixelSize.height)
            return CursorPreview(
                id: assignment.role.id,
                name: assignment.role.displayName,
                frames: assignment.decoded.frames.map { NSImage(cgImage: $0, size: size) },
                durations: assignment.decoded.frameDurations
            )
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("Choose", comment: "Open panel button")
        panel.message = NSLocalizedString("Choose a folder of cursors (.ani, .cur, .png).", comment: "Open panel")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadFolder(url, remember: true)
    }

    private func loadFolder(_ url: URL, remember: Bool) {
        let loaded = CursorTheme.load(fromFolder: url)
        guard !loaded.assignments.isEmpty else {
            status = NSLocalizedString("No usable cursors were found in that folder.", comment: "Cursor status")
            return
        }
        theme = loaded
        previews = Self.makePreviews(loaded)
        if remember {
            defaults.set(url.path, forKey: Key.folderPath)
            let source = loaded.usedInf
                ? NSLocalizedString("mapped from install.inf", comment: "Cursor status")
                : NSLocalizedString("mapped by file name", comment: "Cursor status")
            status = String(format: NSLocalizedString("Loaded %d cursors from “%@” (%@).", comment: "Cursor status"),
                            loaded.assignments.count, loaded.name, source)
        }
    }

    func apply() {
        guard let theme else { return }
        let result = controller.apply(theme, pointSize: pointSize)
        isApplied = controller.isApplied
        if result.failed.isEmpty {
            status = String(format: NSLocalizedString("Applied %d cursors. Move the mouse to see them.", comment: "Cursor status"),
                            result.applied.count)
        } else {
            status = String(format: NSLocalizedString("Applied %d cursors; %d could not be set.", comment: "Cursor status"),
                            result.applied.count, result.failed.count)
        }
    }

    func reset() {
        controller.reset()
        isApplied = controller.isApplied
        status = NSLocalizedString("System cursors restored.", comment: "Cursor status")
    }
}
