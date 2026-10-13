# Widgets and extensions

Load every face a widget draws before it renders.

Registration is per process, so each process calls ``WebFonts/configure(_:)`` with the shared directory (an App Group container). A widget or App Intent renders once and never sees the modifier's later swap, so before returning its entry it awaits `load` for every family and style it draws:

```swift
WebFonts.shared.configure(.init(directory: appGroupURL))
await WebFonts.shared.load("Lobster", styles: [.regular])
```

A `load` of a registered face returns at once with no network call. Waiting for `.warmedUp` is not enough: a face that shares a system font's name comes back only through `load`. Ask only for styles the family has: the modifier's stand-in regular face lives in memory, so `load` reports `.notFound` for a missing style.

A `remove` in the app doesn't reach a running extension, which keeps drawing the faces it opened until it relaunches.
