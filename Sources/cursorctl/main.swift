import CursorCore
import Foundation

// cursorctl apply "<folder>" [pointSize]   – theme the system cursors from a folder
// cursorctl reset                           – restore the system cursors
// cursorctl status                          – print what is applied
// cursorctl check "<folder>"                – load a folder and print the mapping (no changes)
// cursorctl verify "<folder>" [pointSize]   – list the folder's cursors macOS has replaced (no changes)

@MainActor
func run() -> Int32 {
    let args = CommandLine.arguments
    let controller = SystemCursorController()
    guard args.count >= 2 else {
        print("usage: cursorctl apply <folder> [size] | reset | status | check <folder> | verify <folder> [size]")
        return 2
    }

    switch args[1] {
    case "verify":
        guard args.count >= 3 else { print("verify needs a folder path"); return 2 }
        let theme = CursorTheme.load(fromFolder: URL(fileURLWithPath: args[2]))
        let size = args.count > 3 ? (Double(args[3]) ?? 28) : 28
        let replaced = controller.replacedAssignments(in: theme, pointSize: size)
        print("\(theme.assignments.count - replaced.count) of \(theme.assignments.count) cursors hold the pack")
        for assignment in replaced {
            print("  replaced: \(assignment.role.displayName) (\(assignment.role.id))")
        }
        return replaced.isEmpty ? 0 : 1

    case "check":
        guard args.count >= 3 else { print("check needs a folder path"); return 2 }
        let theme = CursorTheme.load(fromFolder: URL(fileURLWithPath: args[2]))
        print("source: \(theme.usedInf ? "install.inf" : "file names")")
        print("mapped \(theme.assignments.count) roles:")
        for a in theme.assignments {
            print("  \(a.role.displayName.padding(toLength: 24, withPad: " ", startingAt: 0)) ← \(a.sourceURL.lastPathComponent) [\(a.decoded.frames.count) frame(s), \(Int(a.decoded.pixelSize.width))px]")
        }
        let unmatched = theme.unmatchedFiles.map { $0.lastPathComponent }
        if !unmatched.isEmpty { print("no macOS match: \(unmatched.joined(separator: ", "))") }
        return theme.assignments.isEmpty ? 1 : 0


    case "apply":
        guard args.count >= 3 else { print("apply needs a folder path"); return 2 }
        let folder = URL(fileURLWithPath: args[2])
        let size = args.count > 3 ? (Double(args[3]) ?? 28) : 28
        let theme = CursorTheme.load(fromFolder: folder)
        guard !theme.assignments.isEmpty else { print("no cursors found in \(folder.path)"); return 1 }
        let result = controller.apply(theme, pointSize: size)
        print("applied \(result.applied.count) roles at \(Int(size)) pt: \(result.applied.joined(separator: ", "))")
        if !result.failed.isEmpty { print("failed: \(result.failed.joined(separator: ", "))") }
        return result.failed.isEmpty ? 0 : 1

    case "reset":
        controller.reset()
        print("system cursors restored")
        return 0

    case "status":
        print(controller.isApplied ? "applied: \(controller.appliedThemeName ?? "?")" : "not applied")
        return 0

    default:
        print("unknown command: \(args[1])")
        return 2
    }
}

exit(MainActor.assumeIsolated { run() })
