import SwiftUI

/// What the library does, how to use it, and what the default source sends to Google.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Card(title: "One line") {
                        Text("Text(\"Hello\").font(web: \"Lobster\", size: 24)")
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                        Text("The view draws a fallback until the font is ready, then swaps. Registered fonts draw on the first frame, and saved fonts are registered again at the next launch without the network.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Card(title: "Privacy") {
                        Label("Fonts in this demo come from Google Fonts. Each download sends your device's IP address to Google, as any web font request does. An app can serve the files from its own server instead.",
                              systemImage: "hand.raised.fill")
                            .font(.callout)
                    }
                    Card(title: "Licences") {
                        Text("Google Fonts are open-licensed (SIL Open Font License, Apache 2.0). WebFontKit is Apache 2.0.")
                            .font(.callout)
                        Link(destination: URL(string: "https://fonts.google.com/attribution")!) {
                            Label("Font attributions", systemImage: "arrow.up.right.square")
                        }
                        .font(.callout.weight(.semibold))
                    }
                }
                .padding(16)
            }
            .screen("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if #available(iOS 26.0, *) {
                        Button(role: .close) { dismiss() }
                    } else {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
