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
    let frames: [CGImage]
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
    /// Accessibility → Display → Pointer size, so the app offers no size control of its own.
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

    /// Builds the animated previews, once per loaded pack. One cursor file can theme several
    /// macOS roles (all the resize variants, say); it is shown once, under its main role.
    private static func makePreviews(_ theme: CursorTheme) -> [CursorPreview] {
        var seen: Set<URL> = []
        return theme.assignments.compactMap { assignment in
            guard seen.insert(assignment.sourceURL).inserted else { return nil }
            return CursorPreview(
                id: assignment.role.id,
                name: NSLocalizedString(assignment.role.displayName, comment: "Cursor role"),
                frames: assignment.decoded.frames,
                durations: assignment.decoded.frameDurations
            )
        }
    }

    /// Number of distinct cursor files in use, which is what people count — not macOS roles.
    private static func cursorCount(_ theme: CursorTheme) -> Int {
        Set(theme.assignments.map(\.sourceURL)).count
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
                            Self.cursorCount(loaded), loaded.name, source)
        }
    }

    func apply() {
        guard let theme else { return }
        let result = controller.apply(theme, pointSize: pointSize)
        isApplied = controller.isApplied
        if result.failed.isEmpty {
            status = String(format: NSLocalizedString("Applied %d cursors. Move the mouse to see them.", comment: "Cursor status"),
                            Self.cursorCount(theme))
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
