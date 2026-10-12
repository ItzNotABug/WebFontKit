/// What `WebFonts.shared.events` reports, for code outside a view.
///
/// ```swift
/// for await event in WebFonts.shared.events {
///     if case .failed(let family, _, let error) = event { analytics.log(family, error) }
/// }
/// ```
public enum WebFontEvent: Sendable, Equatable {
    /// A `load` started work on these styles of a family; a name it rejects at once is followed by `.failed`.
    ///
    /// ```swift
    /// case .loading(let family, let styles): spinner.show(family, styles)
    /// ```
    case loading(family: String, styles: [FontStyle])

    /// The styles are registered and ready to draw.
    ///
    /// ```swift
    /// case .loaded(let family, _): print("\(family) is ready")
    /// ```
    case loaded(family: String, styles: [FontStyle])

    /// These styles failed with `error`; a load closes with `.loaded` for the rest and one `.failed` per error.
    ///
    /// ```swift
    /// case .failed(let family, _, let error): print("\(family): \(error)")
    /// ```
    case failed(family: String, styles: [FontStyle], error: WebFontError)

    /// Launch registration of saved fonts finished; `count` faces are registered.
    ///
    /// ```swift
    /// case .warmedUp(let count): print("\(count) saved faces ready")
    /// ```
    case warmedUp(count: Int)

    /// `remove` or `removeAll` removed the family.
    ///
    /// ```swift
    /// case .removed(let family): print("\(family) removed")
    /// ```
    case removed(family: String)
}

/// Where a `.font(web:)` view's font is.
///
/// ```swift
/// Text("Hi").font(web: "Lobster", size: 24) { phase in
///     if case .failed(let error) = phase { print(error) }
/// }
/// ```
public enum WebFontPhase: Sendable, Equatable {
    /// Drawing the fallback while the font loads.
    ///
    /// ```swift
    /// if phase == .loading { showPlaceholder() }
    /// ```
    case loading

    /// Drawing the web font.
    ///
    /// ```swift
    /// if phase == .loaded { hidePlaceholder() }
    /// ```
    case loaded

    /// The font could not be loaded; the fallback stays.
    ///
    /// ```swift
    /// if case .failed(.offline) = phase { showOfflineBanner() }
    /// ```
    case failed(WebFontError)
}
