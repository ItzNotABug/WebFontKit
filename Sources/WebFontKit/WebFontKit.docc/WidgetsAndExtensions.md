# Widgets and extensions

Load every face before rendering once.

Registration is per process, so each process calls ``WebFonts/configure(_:)`` with the shared directory (an App Group container). A widget or App Intent renders once and never sees the modifier's later swap, so before returning its entry it awaits `load` for every family and style it draws:

```swift
WebFonts.shared.configure(.init(directory: appGroupURL))
try await WebFonts.shared.load("Lobster", styles: [.regular])
```

A `load` of a registered face returns at once with no network call. Waiting for `.warmedUp` alone is not enough after a relaunch: a face that met a system font's name (error 305) gets its entry back only from a `load`, and a face never stored is fetched only by a `load`. The modifier's stand-in regular face for a style the family lacks lives in memory only, and `load` throws `.notFound` for that style, so a widget asks only for styles the family has. A `remove` in the app does not reach a running extension, which keeps drawing the faces it already opened until it relaunches.
