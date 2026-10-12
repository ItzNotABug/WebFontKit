# ``WebFontKit``

Download fonts by family name, keep them on disk, and draw them with Apple's own font APIs.

## Overview

```swift
Text("Hello").font(web: "Lobster", size: 24)
```

The view draws its fallback until Lobster is ready, then swaps. Behind it, ``WebFonts`` resolves the family through a ``FontSource`` (Google Fonts by default), downloads the font file, checks it with CoreText, stores it, and registers it for the process. After that, `Font.custom` and `UIFont(name:size:)` draw it too. Saved fonts are registered again at the next launch, so a returning user doesn't wait for the network.

## Topics

### Essentials

- <doc:GettingStarted>
- ``WebFonts``
- ``SwiftUICore/View/font(web:size:weight:italic:fallback:onPhase:)``
- ``SwiftUICore/View/font(web:fixedSize:weight:italic:fallback:onPhase:)``

### Faces and styles

- <doc:StylesAndFaces>
- ``FontStyle``
- ``FontRequest``
- ``DownloadedFont``

### Sources

- <doc:SourcesAndSelfHosting>
- ``FontSource``
- ``RemoteFontSource``
- ``DefaultFontSource``
- ``HostedFontSource``

### Results and events

- ``WebFontError``
- ``WebFontPhase``
- ``WebFontEvent``
- ``FontLoadResults``
- ``FontStyleResults``

### Apps, widgets and privacy

- <doc:WidgetsAndExtensions>
- <doc:PrivacyAndLicences>
