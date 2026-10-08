import SwiftUI
import WebFontKit

/// The Gallery's prefetch. User-started, so it runs on when the screen changes, and the
/// person can stop it; a stopped batch reports what finished.
@MainActor
@Observable
final class PrefetchModel {
    private(set) var summary: String?
    private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    func start(_ families: [String]) {
        guard task == nil else { return }
        summary = nil
        task = Task {
            let clock = ContinuousClock()
            let started = clock.now
            let results = await WebFonts.shared.load(families)
            let ready = "\(results.succeeded.count) of \(families.count) ready"
            if Task.isCancelled {
                summary = "Stopped: \(ready)"
            } else {
                let elapsed = (clock.now - started).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))
                let failed = results.failed.map(\.family)
                summary = "\(ready) in \(elapsed)" + (failed.isEmpty ? "" : " · failed: \(failed.joined(separator: ", "))")
            }
            task = nil
        }
    }

    func stop() {
        task?.cancel()
    }
}

/// Popular families as cards; each shows a skeleton until its face is ready.
struct GalleryView: View {
    private static let families = [
        "Lobster", "Pacifico", "Abril Fatface", "Righteous", "Bangers", "Comfortaa", "Dancing Script", "Fredoka",
        "Josefin Sans", "Kalam", "Lora", "Merriweather", "Montserrat", "Nunito", "Oswald", "Playfair Display",
        "Poppins", "Quicksand", "Raleway", "Caveat",
    ]

    @State private var prefetch = PrefetchModel()
    @Environment(FontLibrary.self) private var library
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .footnote) private var statusHeight: CGFloat = 20
    /// `-ExampleSpecimen <family>` opens a specimen directly, for screenshots.
    @State private var path: [String] = ProcessInfo.processInfo.arguments.firstIndex(of: "-ExampleSpecimen")
        .map { ProcessInfo.processInfo.arguments.dropFirst($0 + 1).prefix(1).map { $0 } } ?? []

    var body: some View {
        NavigationStack(path: $path) { content }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 16) {
                status
                // One column at accessibility text sizes, as Apple recommends for large type.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 300 : 160), spacing: 14)], spacing: 14) {
                    ForEach(Self.families, id: \.self) { family in
                        NavigationLink(value: family) {
                            GalleryCard(family: family)
                                .id(library.generation(of: family))
                        }
                        .buttonStyle(PressableCardStyle())
                    }
                }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .screen("Gallery")
        .navigationDestination(for: String.self) { SpecimenView(family: $0) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if prefetch.isRunning {
                    Button { prefetch.stop() } label: { Label("Stop prefetch", systemImage: "stop.circle") }
                } else {
                    Button { prefetch.start(Self.families) } label: { Label("Prefetch all families", systemImage: "arrow.down.circle") }
                }
            }
        }
        .motion(.easeInOut(duration: 0.3), value: prefetch.summary)
        .motion(.easeInOut(duration: 0.3), value: prefetch.isRunning)
        .onChange(of: prefetch.summary) { _, summary in
            if let summary { AccessibilityNotification.Announcement(summary).post() }
        }
    }

    /// Always one line, in a fixed slot, so starting or finishing a prefetch never moves the grid.
    private var status: some View {
        HStack(spacing: 8) {
            ZStack {
                ProgressView().controlSize(.small).opacity(prefetch.isRunning ? 1 : 0)
                Image(systemName: prefetch.summary == nil ? "arrow.down.circle" : "bolt.fill")
                    .opacity(prefetch.isRunning ? 0 : 1)
            }
            .frame(width: 18)
            .accessibilityHidden(true)
            Text(prefetch.isRunning ? "Prefetching \(Self.families.count) families…"
                 : prefetch.summary ?? "\(Self.families.count) families · prefetch them all to keep them offline")
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentTransition(.opacity)
        }
        .font(.footnote).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: statusHeight, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

struct GalleryCard: View {
    let family: String
    @State private var phase: WebFontPhase = .loading
    /// Fixed slots, so differing font metrics never shift the grid, scaled with Dynamic Type.
    @ScaledMetric(relativeTo: .body) private var glyphSlot: CGFloat = 64
    @ScaledMetric(relativeTo: .body) private var sampleSlot: CGFloat = 22
    @ScaledMetric(relativeTo: .body) private var cardHeight: CGFloat = 160

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Aa")
                .font(web: family, size: 46) { phase = $0 }
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .redacted(reason: phase == .loading ? .placeholder : [])
                .shimmer(phase == .loading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: glyphSlot)
            // In an overlay, so its natural width never widens the card; it runs off the edge with a fade.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: sampleSlot)
                .overlay(alignment: .leading) {
                    Text("Sphinx of black quartz")
                        .font(web: family, size: 15)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .redacted(reason: phase == .loading ? .placeholder : [])
                        .foregroundStyle(.secondary)
                }
                .clipped()
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                PhaseIcon(phase: phase).font(.caption)
                Text(family).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .padding(16)
        .frame(height: cardHeight)
        .surface(cornerRadius: 22)
        .contentShape(.rect(cornerRadius: 22))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(family)
        .accessibilityValue(phase.label)
        .accessibilityHint("Opens the specimen")
        .motion(.easeInOut(duration: 0.4), value: phase)
    }
}
