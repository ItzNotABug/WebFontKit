# Getting started

Configure once at launch, then use the modifier or load and use Apple's APIs.

## Configure at launch

All settings are optional. Call ``WebFonts/configure(_:)`` early, in `App.init`, so saved fonts are registered before the first frame as often as possible.

```swift
@main struct MyApp: App {
    init() { WebFonts.shared.configure(.init(directory: appGroupURL)) }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

Files go in a `WebFontKit/` folder that WebFontKit creates inside the configured directory: Application Support by default on iOS, and `Application Support/<bundle identifier>` on macOS. WebFontKit touches only its own files there (`.wfkfont`, `.wfkpart`, `.wfkmark`). `.session` storage keeps files for the running process only.

## In a view

```swift
Text("Hello").font(web: "Inter", size: 17, weight: .bold) { phase in
    if case .failed(let error) = phase { print(error) }
}
```

- `size:` scales with Dynamic Type, like `Font.custom(_:size:)`; `fixedSize:` never scales, and neither does its fallback.
- The default fallback is the system font at the same size, weight and italic. Pass `fallback:` to choose another.
- A registered font draws on the first frame, and `onPhase` reports `.loaded` at once.
- `.font(web:)` returns `some View`, not `Text`, so it can't be used in `Text` concatenation or `TextField(prompt:)`. There, load first and use `.font(.custom(_:size:))`.

## Outside a view

```swift
try await WebFonts.shared.load("Inter", styles: [.regular, .bold])
label.font = UIFont(name: "Inter", size: 17)
let results = await WebFonts.shared.load(["Pacifico", "Bebas Neue"])   // never throws
```

``WebFonts/events`` reports loads, launch registration (`.warmedUp`) and removals. Each listener keeps the newest 256 events. A `.loading` with no closing `.loaded` or `.failed` means every caller abandoned that load, or ``WebFonts/remove(_:)`` or ``WebFonts/removeAll()`` overtook it before it stored anything.

## Errors and cancellation

``WebFontError`` has six cases. Two kinds of `load` throw `CancellationError` instead, which is not a `WebFontError`: a load whose caller is cancelled, and a load that `remove` (for its family) or `removeAll` overtakes before it stores anything, even though its caller was not cancelled. An overtaken load stores nothing, so a removal is never undone by a load already in flight, and `onPhase` does not report it. A load that starts after `remove` returns stores normally.

## Housekeeping

``WebFonts/downloaded`` lists the stored faces from memory; it is complete once `.warmedUp` has arrived. ``WebFonts/remove(_:)`` and ``WebFonts/removeAll()`` unregister and delete. A removed font's views fall back and stay on the fallback until their family or style changes. A removal reaches only the calling process: another process, such as a widget, keeps drawing the faces it already opened until it relaunches.
