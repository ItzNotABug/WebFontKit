import SwiftUI
import WebFontKit

/// What is stored, with the exact PostScript name to use with `UIFont(name:size:)`.
struct LibraryView: View {
    @Environment(FontLibrary.self) private var library
    @State private var confirmRemoveAll = false

    var body: some View {
        List {
            Section {
                // Side by side when they fit; stacked at large text sizes.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        stats(dividers: true)
                    }
                    VStack(spacing: 12) {
                        stats(dividers: false)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
            }
            .listRowBackground(Color.clear.surface(cornerRadius: 22))

            if library.fonts.isEmpty {
                ContentUnavailableView("Nothing stored yet", systemImage: "internaldrive",
                                       description: Text("Load a family in Try or Gallery; it stays on disk for the next launch."))
                    .listRowBackground(Color.clear)
            }
            ForEach(library.fonts, id: \.postScriptName) { font in
                row(font)
            }
            if let error = library.error {
                Label(ErrorText.describe(error), systemImage: "exclamationmark.triangle").foregroundStyle(Theme.failed)
                    .listRowBackground(Color.clear)
            }
        }
        .listRowSpacing(10)
        .screen("Library")
        .toolbar {
            Button(role: .destructive) { confirmRemoveAll = true } label: { Label("Remove all", systemImage: "trash") }
                .disabled(library.fonts.isEmpty)
                // Attached to the button so the dialog anchors to it, not to the list.
                .confirmationDialog("Remove every stored font?", isPresented: $confirmRemoveAll, titleVisibility: .visible) {
                    Button("Remove all", role: .destructive) { Task { await library.removeAll() } }
                } message: {
                    Text("Text using them falls back to the system font until it loads them again.")
                }
        }
        .motion(.spring(duration: 0.35), value: library.fonts)
        .onChange(of: library.error) { _, error in
            if let error { AccessibilityNotification.Announcement(ErrorText.describe(error)).post() }
        }
    }

    @ViewBuilder
    private func stats(dividers: Bool) -> some View {
        stat(value: library.fonts.count.formatted(), label: library.fonts.count == 1 ? "face" : "faces")
        if dividers { Divider().frame(height: 36) }
        stat(value: library.familyCount.formatted(), label: library.familyCount == 1 ? "family" : "families")
        if dividers { Divider().frame(height: 36) }
        stat(value: ByteCountFormatter.string(fromByteCount: library.totalBytes, countStyle: .file), label: "on disk")
    }

    private func stat(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ font: DownloadedFont) -> some View {
        let size = ByteCountFormatter.string(fromByteCount: Int64(font.byteCount), countStyle: .file)
        return VStack(alignment: .leading, spacing: 6) {
            Text(font.family).font(.custom(font.postScriptName, size: 24))
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 34)
            // The PostScript name already says the style; one short line.
            Text("\(font.postScriptName) · \(size)")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.clear.surface(cornerRadius: 18))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(font.family), \(font.style.displayName), \(size)")
        // Removal is per family: the library stores and removes families, not single faces.
        .swipeActions {
            Button(role: .destructive) { Task { await library.remove(font.family) } } label: {
                Label("Remove family", systemImage: "trash")
            }
        }
        .accessibilityAction(named: "Remove \(font.family)") { Task { await library.remove(font.family) } }
    }
}
