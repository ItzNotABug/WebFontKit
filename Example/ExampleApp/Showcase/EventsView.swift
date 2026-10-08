import SwiftUI
import WebFontKit

/// Every event since launch, newest change first. A load is one entry: its `.loading` row
/// becomes its outcome when the load closes, with how long it took, and moves to the top.
@MainActor
@Observable
final class EventLog {
    struct Entry: Identifiable {
        enum Stop {
            /// `remove` overtook it.
            case removed
            /// No close came: the library sends none when every view that wanted it went away.
            case unneeded
        }

        let id = UUID()
        /// When it last changed: the feed is newest first by this.
        var date = Date()
        var event: WebFontEvent
        /// From `.loading` to the close, once closed.
        var duration: Duration?
        var stop: Stop?

        var isOpen: Bool {
            if case .loading = event { return stop == nil }
            return false
        }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", loads = "Loads", failures = "Failures", removals = "Removals"
        var id: Self { self }
    }

    private(set) var entries: [Entry] = []
    /// A long session would otherwise grow the log without bound.
    static let limit = 200
    /// How long an open load waits for its close before it counts as unneeded.
    private static let patience: Duration = .seconds(60)
    /// Loads without a close yet: (family, styles) → when it started and its row.
    private var open: [String: (started: ContinuousClock.Instant, id: UUID)] = [:]
    private var expiries: [UUID: Task<Void, Never>] = [:]

    func listen() async {
        for await event in WebFonts.shared.events {
            record(event)
        }
    }

    func entries(matching filter: Filter) -> [Entry] {
        guard filter != .all else { return entries }
        return entries.filter { entry in
            switch (filter, entry.event) {
            case (.loads, .loading), (.loads, .loaded), (.loads, .warmedUp): true
            case (.failures, .failed): true
            case (.removals, .removed): true
            default: false
            }
        }
    }

    /// Keeps loads still waiting for their close, so their rows can still close.
    func clear() {
        let ids = Set(open.values.map(\.id))
        entries.removeAll { !ids.contains($0.id) }
    }

    private func record(_ event: WebFontEvent) {
        let now = ContinuousClock.now
        switch event {
        case .loading(let family, let styles):
            let key = Self.key(family, styles)
            // The earlier load of the same styles was abandoned without a close (its views went
            // away), and this is it starting again: one row, not a spinner left behind.
            if let earlier = open[key] { discard(earlier.id) }
            let entry = Entry(event: event)
            open[key] = (now, entry.id)
            insert(entry)
            expiries[entry.id] = Task { [weak self] in
                try? await Task.sleep(for: Self.patience)
                guard !Task.isCancelled else { return }
                self?.markUnneeded(entry.id)
            }
        case .loaded(let family, let styles), .failed(let family, let styles, _):
            if let (started, id) = open.removeValue(forKey: Self.key(family, styles)),
               let index = entries.firstIndex(where: { $0.id == id }) {
                expiries.removeValue(forKey: id)?.cancel()
                var entry = entries.remove(at: index)
                entry.event = event
                entry.duration = now - started
                entry.stop = nil
                entry.date = Date()
                insert(entry)
            } else {
                insert(Entry(event: event))
            }
        case .removed(let family):
            // An overtaken load never closes; settle its row.
            for (key, value) in open where key.hasPrefix(family.lowercased() + "|") {
                open[key] = nil
                expiries.removeValue(forKey: value.id)?.cancel()
                if let index = entries.firstIndex(where: { $0.id == value.id }) {
                    var entry = entries.remove(at: index)
                    entry.stop = .removed
                    entry.date = Date()
                    insert(entry)
                }
            }
            insert(Entry(event: event))
        case .warmedUp:
            insert(Entry(event: event))
        }
    }

    /// Stays in `open`: a close that comes after all still settles the row.
    private func markUnneeded(_ id: UUID) {
        expiries[id] = nil
        if let index = entries.firstIndex(where: { $0.id == id }), entries[index].isOpen {
            entries[index].stop = .unneeded
        }
    }

    private func discard(_ id: UUID) {
        expiries.removeValue(forKey: id)?.cancel()
        entries.removeAll { $0.id == id }
    }

    private func insert(_ entry: Entry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    private static func key(_ family: String, _ styles: [FontStyle]) -> String {
        family.lowercased() + "|" + styles.map { "\($0.weight)\($0.isItalic ? "i" : "")" }.joined(separator: ",")
    }
}

/// A timeline of loads, launch registration and removals.
struct EventsView: View {
    @Environment(EventLog.self) private var events
    @State private var filter = EventLog.Filter.all

    var body: some View {
        let shown = events.entries(matching: filter)
        ScrollView {
            VStack(spacing: 16) {
                Picker("Show", selection: $filter) {
                    ForEach(EventLog.Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if !shown.isEmpty {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shown) { entry in
                            TimelineRow(entry: entry, isLast: entry.id == shown.last?.id)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .surface()
                }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .overlay {
            if shown.isEmpty {
                ContentUnavailableView(filter == .all ? "No activity yet" : "Nothing here",
                                       systemImage: "waveform.path.ecg",
                                       description: Text(filter == .all
                                           ? "Loads, launch registration and removals appear here."
                                           : "No \(filter.rawValue.lowercased()) since launch or the last clear."))
            }
        }
        .motion(.spring(duration: 0.3), value: shown.first?.id)
        .motion(.smooth(duration: 0.35), value: shown.filter(\.isOpen).count)
        .motion(.easeInOut(duration: 0.25), value: filter)
        .screen("Activity")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear") { events.clear() }
                    .disabled(events.entries.isEmpty)
                    .accessibilityHint("Empties the activity log")
            }
        }
    }
}

/// One event on the timeline: a symbol on a continuous line, what happened, and when.
private struct TimelineRow: View {
    let entry: EventLog.Entry
    let isLast: Bool
    @ScaledMetric(relativeTo: .footnote) private var badge: CGFloat = 30

    var body: some View {
        let look = Look(entry.event, stop: entry.stop)
        HStack(alignment: .top, spacing: 14) {
            // The line runs from this badge to the next, and stops at the last.
            ZStack {
                if entry.isOpen {
                    ProgressView().controlSize(.mini).tint(look.color)
                } else {
                    Image(systemName: look.symbol)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(look.color)
                        .transition(.scale.combined(with: .opacity))
                }
            }
                .frame(width: badge, height: badge)
                .background(look.color.opacity(0.16), in: .circle)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(alignment: .top) {
                    if !isLast {
                        Rectangle().fill(.white.opacity(0.12)).frame(width: 1.5).padding(.top, badge)
                    }
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(look.title).font(.callout.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(entry.date, format: .dateTime.hour().minute().second())
                        .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
                // Plain text, no ForEach or ViewThatFits: iOS 26 can build those off the main
                // thread during layout. One line; the duration keeps its space.
                if !look.details.isEmpty || entry.duration != nil {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if !look.details.isEmpty {
                            Text(look.details.joined(separator: " · "))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let duration = entry.duration {
                            Label(Self.format(duration), systemImage: "timer")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                }
            }
            .padding(.vertical, 10)
        }
        .accessibilityElement(children: .combine)
    }

    private static func format(_ duration: Duration) -> String {
        duration < .milliseconds(1) ? "< 1 ms"
            : duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated, maximumUnitCount: 1))
    }

    private struct Look {
        let symbol: String
        let color: Color
        let title: String
        let details: [String]

        init(_ event: WebFontEvent, stop: EventLog.Entry.Stop?) {
            switch event {
            case .loading(let family, let styles) where stop == .removed:
                (symbol, color, title, details) = ("minus", .secondary, "Stopped \(family)", styles.map(\.displayName) + ["Removed while loading"])
            case .loading(let family, let styles) where stop == .unneeded:
                (symbol, color, title, details) = ("minus", .secondary, "\(family) not finished", styles.map(\.displayName) + ["No view needs it now"])
            case .loading(let family, let styles):
                (symbol, color, title, details) = ("arrow.down", Theme.loading, "Loading \(family)", styles.map(\.displayName))
            case .loaded(let family, let styles):
                (symbol, color, title, details) = ("checkmark", Theme.loaded, "Loaded \(family)", styles.map(\.displayName))
            case .failed(let family, _, let error):
                (symbol, color, title, details) = ("xmark", Theme.failed, "Failed \(family)", [ErrorText.describe(error)])
            case .warmedUp(let count):
                let ready = String(AttributedString(localized: "^[\(count) saved face](inflect: true) registered").characters)
                (symbol, color, title, details) = ("bolt.fill", Theme.accent, "Launch registration", [ready])
            case .removed(let family):
                (symbol, color, title, details) = ("trash", Theme.removed, "Removed \(family)", [])
            }
        }
    }
}
