# Styles and faces

Ask for the styles you draw, and reach any face exactly by its PostScript name.

## Ask for styles the family has

- WebFontKit never discovers a family's styles. A family without a regular face (Molle, Buda, UnifrakturCook, Sunflower) answers ``WebFontError/notFound`` to a bare `load`; ask for a style it has.
- ``WebFonts/load(_:styles:)`` is all or nothing: if any requested style is missing, nothing from the call is stored and it throws `.notFound`.
- iOS does not synthesise bold or italic for a downloaded font. When the modifier asks for a style the family lacks, it draws the regular face plain and reports `.loaded`.

## Reaching a face through Apple's APIs

Regular, bold, italic and bold italic are usually reachable by family name. Other weights may register under their own family name (Google's Poppins 600 is family "Poppins SemiBold"), and a lookup by family plus weight picks the nearest registered trait. Every stored face is reachable exactly by ``DownloadedFont/postScriptName``:

```swift
for font in WebFonts.shared.downloaded where font.family == "Poppins" {
    label.font = UIFont(name: font.postScriptName, size: 17)
}
```

## Families iOS also ships

112 Google families are also iOS system fonts (iOS 26.5). A load of any of them reports `.loaded`. For most, the system's face draws; for six (Bebas Neue, Carlito, STIX Two Text, Noto Sans Oriya, Noto Nastaliq Urdu, Noto Sans Tai Tham), the downloaded face draws by its PostScript name. For all of them, lookup by family name (`.custom(family)`, `UIFont(name: family)`) returns Apple's copy. On macOS the downloaded copy registers and wins.
