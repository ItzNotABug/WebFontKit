import SwiftUI
import WebFontKit

@main
struct ExampleApp: App {
    private let mode: TestMode.Screen

    init() {
        mode = TestMode.apply(ProcessInfo.processInfo.arguments)
        if case .showcase = mode {
            // Configure early, so saved fonts are registered before the first frame as often as possible.
            WebFonts.shared.configure(.init(storage: .persistent))
        }
    }

    var body: some Scene {
        WindowGroup {
            switch mode {
            case .showcase: ShowcaseView()
            case .seeding: Color.black.ignoresSafeArea()
            case .harness: TestHarnessView()
            case .race(let family): RaceView(family: family)
            }
        }
    }
}
