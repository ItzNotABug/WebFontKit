# Sources and self-hosting

Use Google Fonts, your own server, or any client.

## Self-hosting

``HostedFontSource`` maps a family and style to a file in one https folder:

```
https://cdn.example.com/fonts/Inter.ttf              regular
https://cdn.example.com/fonts/Inter-Bold.ttf         bold
https://cdn.example.com/fonts/Inter-Italic.ttf       italic
https://cdn.example.com/fonts/Inter-BoldItalic.ttf   bold italic
https://cdn.example.com/fonts/Inter-300.ttf          any other weight
https://cdn.example.com/fonts/Inter-300Italic.ttf
```

```swift
WebFonts.shared.configure(.init(source: .hosted(at: URL(string: "https://cdn.example.com/fonts")!)))
```

## Custom sources

Give a request, with any headers, and WebFontKit downloads it to disk:

```swift
struct MyServer: RemoteFontSource {
    let token: String
    func request(for font: FontRequest) async throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://fonts.example.com/\(font.family)/\(font.style.weight).ttf")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}
```

Or return the bytes yourself, with any client:

```swift
struct MyClient: FontSource {
    func fetch(_ font: FontRequest) async throws -> Data { try await api.font(font.family, font.style.weight) }
}
```

Throw ``WebFontError/notFound`` for a face you don't have. A `URLError` is mapped like WebFontKit's own; any other error becomes `.network(.unknown)` and is logged. Bytes are checked by CoreText alone, so TrueType, OpenType, WOFF and WOFF2 all work. Implement ``FontSource/cacheKey(for:)`` to version files: when the key changes, the next `load` replaces the stored file.
