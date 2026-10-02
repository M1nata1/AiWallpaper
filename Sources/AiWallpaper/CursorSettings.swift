import AppKit
import Combine
import CursorCore
import Foundation

/// One cursor ready to show animated in the settings preview.
struct CursorPreview: Identifiable {
    let id: String
    let name: String
    let frames: [CGImage]
    /// Seconds per frame, matching `frames`; empty or single-frame means static.
    let durations: [Double]
}

/// Drives the cursor section of the Settings window: the chosen pack, the preview, and the
/// Apply / Reset actions over `SystemCursorController`.
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

    /// Folder of the pack shown in the preview.
    private var themeFolder: URL?

    private enum Key {
        static let folderPath = "cursorFolderPath"
        /// Folder of the applied pack, which can differ from the one being previewed.
        static let appliedFolderPath = "appliedCursorFolderPath"
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
        themeFolder = url
        previews = Self.makePreviews(loaded)
        if remember {
            defaults.set(url.path, forKey: Key.folderPath)
            let source = loaded.usedInf
                ? NSLocalizedString("mapped from install.inf", comment: "Cursor status")
                : NSLocalizedString("mapped by file name", comment: "Cursor status")
            // localizedStringWithFormat picks the plural form from Localizable.stringsdict.
            status = String.localizedStringWithFormat(
                NSLocalizedString("Loaded %d cursors from “%@” (%@).", comment: "Cursor status"),
                Self.cursorCount(loaded), loaded.name, source)
        }
    }

    func apply() {
        guard let theme else { return }
        let result = controller.apply(theme, pointSize: pointSize)
        isApplied = controller.isApplied
        if isApplied, let themeFolder {
            defaults.set(themeFolder.path, forKey: Key.appliedFolderPath)
        }
        if result.failed.isEmpty {
            status = String.localizedStringWithFormat(
                NSLocalizedString("Applied %d cursors. Move the mouse to see them.", comment: "Cursor status"),
                Self.cursorCount(theme))
        } else {
            status = String.localizedStringWithFormat(
                NSLocalizedString("Applied %d cursors; %d could not be set.", comment: "Cursor status"),
                result.applied.count, result.failed.count)
        }
    }

    /// Puts the applied pack back when the app starts. The window server forgets registered
    /// cursors when the user logs out, and macOS can restore some of its own in the meantime;
    /// the choice itself is kept on disk. So restarting the app is enough to repair the pointer.
    func reapplyIfNeeded() {
        guard controller.isApplied else { return }
        let folder: URL
        if let path = defaults.string(forKey: Key.appliedFolderPath) {
            folder = URL(fileURLWithPath: path)
        } else if let themeFolder, theme?.name == controller.appliedThemeName {
            folder = themeFolder // applied by a version that did not record the folder separately
        } else {
            return
        }
        let applied = folder == themeFolder ? theme : CursorTheme.load(fromFolder: folder)
        guard let applied, !applied.assignments.isEmpty else { return }
        controller.apply(applied, pointSize: pointSize)
        defaults.set(folder.path, forKey: Key.appliedFolderPath)
    }

    func reset() {
        controller.reset()
        defaults.removeObject(forKey: Key.appliedFolderPath)
        isApplied = controller.isApplied
        status = NSLocalizedString("System cursors restored.", comment: "Cursor status")
    }
}
