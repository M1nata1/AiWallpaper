import CoreGraphics
import XCTest
@testable import CursorCore

/// Exercises the real system cursor path (apply → read back → reset → read back) against the
/// user's live session, so it only runs when explicitly asked for:
///
///     AIWALLPAPER_LIVE_CURSOR_TEST=1 swift test --filter SystemCursorLiveTests
///
/// It changes only the I-beam cursor and always restores it.
@MainActor
final class SystemCursorLiveTests: XCTestCase {
    private let ibeam = "com.apple.coregraphics.IBeam"
    private let packFolder = URL(fileURLWithPath:
        "/Users/fadevec/Documents/Personalization/Cursors/Hatsune Miku Cursor")

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AIWALLPAPER_LIVE_CURSOR_TEST"] == "1",
                          "set AIWALLPAPER_LIVE_CURSOR_TEST=1 to run the live cursor test")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: packFolder.path), "cursor pack not present")
    }

    func testApplyThenResetRestoresTheIBeam() throws {
        let controller = SystemCursorController(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("AiWallpaperCursorTest-\(UUID().uuidString)"))

        let original = try XCTUnwrap(controller.registeredSize(roleID: ibeam))
        let decoded = try XCTUnwrap(CursorImageDecoder.decode(
            contentsOf: packFolder.appendingPathComponent("Text.ani")))
        let role = try XCTUnwrap(CursorRole.all.first { $0.id == ibeam })
        let theme = CursorTheme(
            name: "Test",
            assignments: [CursorAssignment(role: role, sourceURL: packFolder, decoded: decoded)],
            unmatchedFiles: []
        )

        let result = controller.apply(theme, pointSize: 24)
        XCTAssertEqual(result.applied, ["Text (I-beam)"])
        XCTAssertTrue(controller.isApplied)
        let applied = try XCTUnwrap(controller.registeredSize(roleID: ibeam))
        XCTAssertEqual(max(applied.width, applied.height), 24, accuracy: 0.5)

        controller.reset()
        XCTAssertFalse(controller.isApplied)
        let restored = try XCTUnwrap(controller.registeredSize(roleID: ibeam))
        XCTAssertEqual(restored.width, original.width, accuracy: 0.5)
        XCTAssertEqual(restored.height, original.height, accuracy: 0.5)
    }
}
