import Foundation

/// Parses a Windows cursor-scheme `install.inf` to learn, authoritatively, which cursor file
/// belongs to which pointer role — instead of guessing from file names. This is the standard
/// format Windows cursor packs ship, so it makes the mapping work for any pack.
///
/// Two layouts exist, and packs use one or the other:
///  • Per-role `[Wreg]` lines, each naming a registry role explicitly:
///       HKCU,"Control Panel\Cursors",Arrow,0x00020000,"%10%\%CUR_DIR%\%pointer%"
///  • A single `[...Schemes]` line listing the files in the fixed Windows order:
///       HKCU,"Control Panel\Cursors\Schemes","%NAME%",,"...\%pointer%,...\%help%,..."
/// `[Strings]` resolves the `%variables%` to file names in both cases.
public enum WindowsCursorInf {
    public struct Entry: Equatable {
        public let registryName: String
        public let fileName: String
    }

    /// The fixed order of the Windows "Schemes" cursor list.
    static let schemeOrder = [
        "Arrow", "Help", "AppStarting", "Wait", "Crosshair", "IBeam", "NWPen", "No",
        "SizeNS", "SizeWE", "SizeNWSE", "SizeNESW", "SizeAll", "UpArrow", "Hand", "Pin", "Person",
    ]

    public static func find(in folder: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.lastPathComponent.lowercased() == "install.inf" }
            ?? files.first { $0.pathExtension.lowercased() == "inf" }
    }

    /// INF files come in ANSI, UTF-16 or UTF-8; try the common encodings.
    public static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        for encoding: String.Encoding in [.utf8, .utf16, .windowsCP1252, .isoLatin1] {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return nil
    }

    public static func parse(_ text: String) -> [Entry] {
        var strings: [String: String] = [:]
        var wregRaw: [(name: String, token: String)] = []   // explicit per-role lines
        var schemeRaw: String?                               // the comma-separated Schemes list
        var section = ""

        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine
            if let comment = line.firstIndex(of: ";") { line = String(line[..<comment]) }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                section = trimmed.dropFirst().dropLast().lowercased()
                continue
            }

            if section == "strings", let equals = trimmed.firstIndex(of: "=") {
                let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                let value = unquote(String(trimmed[trimmed.index(after: equals)...]))
                if !key.isEmpty { strings[key] = value }
                continue
            }

            let fields = splitFields(trimmed)
            guard fields.count >= 5 else { continue }
            let regPath = unquote(fields[1])
            if regPath.caseInsensitiveCompare("Control Panel\\Cursors") == .orderedSame {
                let name = unquote(fields[2])
                guard !name.isEmpty else { continue } // the default "scheme name" line has no value name
                let token = unquote(fields[4]).components(separatedBy: "\\").last ?? ""
                if !token.isEmpty { wregRaw.append((name, token)) }
            } else if regPath.caseInsensitiveCompare("Control Panel\\Cursors\\Schemes") == .orderedSame {
                schemeRaw = unquote(fields[4])
            }
        }

        if !wregRaw.isEmpty {
            return wregRaw.compactMap { entry(registryName: $0.name, token: $0.token, strings: strings) }
        }
        if let schemeRaw {
            // Each item is a path like "%10%\%CUR_DIR%\%pointer%"; map by position to a role.
            return schemeRaw.components(separatedBy: ",").enumerated().compactMap { index, item in
                guard index < schemeOrder.count else { return nil }
                let token = item.components(separatedBy: "\\").last?.trimmingCharacters(in: .whitespaces) ?? ""
                return entry(registryName: schemeOrder[index], token: token, strings: strings)
            }
        }
        return []
    }

    // MARK: - Helpers

    private static func entry(registryName: String, token: String, strings: [String: String]) -> Entry? {
        let fileName: String
        if token.hasPrefix("%"), token.hasSuffix("%"), token.count > 2 {
            guard let resolved = strings[token.dropFirst().dropLast().lowercased()] else { return nil }
            fileName = resolved
        } else {
            fileName = token // a literal file name
        }
        guard isCursorFile(fileName) else { return nil }
        return Entry(registryName: registryName, fileName: fileName)
    }

    private static func isCursorFile(_ name: String) -> Bool {
        ["ani", "cur", "ico"].contains((name as NSString).pathExtension.lowercased())
    }

    /// Splits on commas that are not inside double quotes.
    private static func splitFields(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for character in line {
            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
            } else if character == ",", !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        fields.append(current)
        return fields
    }

    private static func unquote(_ string: String) -> String {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 {
            s = String(s.dropFirst().dropLast())
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}
