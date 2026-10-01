import SwiftUI

/// Plays a cursor's frames in a loop, keeping pixel art crisp. Static cursors show their frame.
struct AnimatedCursorImage: View {
    let frames: [NSImage]
    let durations: [Double]

    var body: some View {
        if frames.count > 1, totalDuration > 0 {
            TimelineView(.periodic(from: .now, by: 0.05)) { context in
                image(frames[frameIndex(at: context.date)])
            }
        } else {
            image(frames.first)
        }
    }

    private var totalDuration: Double { durations.prefix(frames.count).reduce(0, +) }

    private func image(_ nsImage: NSImage?) -> some View {
        Image(nsImage: nsImage ?? NSImage())
            .interpolation(.none) // pixel-art cursors stay sharp
            .resizable()
            .scaledToFit()
    }

    /// The frame to show now, looping over the per-frame durations.
    private func frameIndex(at date: Date) -> Int {
        var t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: totalDuration)
        for (index, duration) in durations.enumerated() where index < frames.count {
            if t < duration { return index }
            t -= duration
        }
        return frames.count - 1
    }
}

/// The "Cursor" section of the Settings window.
struct CursorSettingsSection: View {
    @EnvironmentObject private var cursor: CursorSettings

    var body: some View {
        Section {
            LabeledContent("Cursor pack") {
                HStack(spacing: 8) {
                    if let name = cursor.folderName {
                        Text(name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Button(cursor.folderName == nil ? "Choose Folder…" : "Change…") {
                        cursor.chooseFolder()
                    }
                }
            }

            if !cursor.previews.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(cursor.previews) { item in
                            VStack(spacing: 4) {
                                AnimatedCursorImage(frames: item.frames, durations: item.durations)
                                    .frame(width: 36, height: 36)
                                Text(item.name)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .frame(width: 62)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                if !cursor.unmatchedNames.isEmpty {
                    Text(String(format: NSLocalizedString("No macOS match for: %@", comment: "Cursor settings"),
                                cursor.unmatchedNames.joined(separator: ", ")))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Apply", action: cursor.apply)
                        .buttonStyle(.borderedProminent)
                        .disabled(cursor.mappedCount == 0)
                    if cursor.isApplied {
                        Button("Reset to Default", action: cursor.reset)
                    }
                    Spacer()
                }
            }

            if let status = cursor.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Cursor")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pointer size is set in System Settings → Accessibility → Pointer.")
                Text("Replaces the pointer for the whole system using a private macOS interface. If the pointer ever looks wrong, click Reset — or log out and back in, which always restores it.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
