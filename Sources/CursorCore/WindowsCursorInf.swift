import Foundation

/// Parses a Windows cursor-scheme `install.inf` to learn, authoritatively, which cursor file
/// belongs to which pointer role — instead of guessing from file names. This is the standard
/// format every Windows cursor pack ships, so it makes the mapping work for any pack.
///
/// The `[Wreg]` section maps a registry value name to a variable:
///     HKCU,"Control Panel\Cursors",Arrow,0x00020000,"%10%\%CUR_DIR%\%pointer%"
/// and `[Strings]` resolves the variable to a file:
///     pointer = "Normal.ani"
public enum WindowsCursorInf {
    public struct Entry: Equatable {
        public let registryName: String
        public let fileName: String
    }

    public static func find(in folder: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        // A cursor scheme installer is conventionally install.inf; otherwise take any .inf.
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
        // (registryName, lastPathComponent) collected first, resolved after [Strings] is known.
        var rawEntries: [(name: String, token: String)] = []
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

            // Registry cursor lines: HKCU,"Control Panel\Cursors",<name>,<flags>,"<value>"
            let fields = splitFields(trimmed)
            guard fields.count >= 5 else { continue }
            guard unquote(fields[1]).caseInsensitiveCompare("Control Panel\\Cursors") == .orderedSame else { continue }
            let name = unquote(fields[2])
            guard !name.isEmpty else { continue } // the default "scheme name" line has no value name
            let token = unquote(fields[4]).components(separatedBy: "\\").last ?? ""
            if !token.isEmpty { rawEntries.append((name, token)) }
        }

        var entries: [Entry] = []
        for raw in rawEntries {
            let fileName: String
            if raw.token.hasPrefix("%"), raw.token.hasSuffix("%"), raw.token.count > 2 {
                let key = raw.token.dropFirst().dropLast().lowercased()
                guard let resolved = strings[key] else { continue }
                fileName = resolved
            } else {
                fileName = raw.token // a literal file name
            }
            if isCursorFile(fileName) {
                entries.append(Entry(registryName: raw.name, fileName: fileName))
            }
        }
        return entries
    }

    // MARK: - Helpers

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
