import Foundation
import WebFontKit

/// Launch arguments for the UI tests and the device race. Every stubbed run needs
/// `-WebFontKitDirectory`, so it never reads or writes the real store.
enum TestMode {
    enum Screen {
        case showcase
        /// A seed launch: it loads, then exits, and shows nothing meanwhile.
        case seeding
        case harness
        case race(family: String)
    }

    /// The Perf families the race loads; their files are bundled under `Perf/`.
    static var perfFamilies: [String] {
        ExampleStub.bundledFamilies.keys.sorted()
    }

    static func apply() -> Screen {
        // Values come from the arguments domain; flags without a value aren't in it.
        let arguments = ProcessInfo.processInfo.arguments
        let directory = UserDefaults.standard.string(forKey: "WebFontKitDirectory")
        let stub = arguments.contains("-WebFontKitStub")
        let offline = arguments.contains("-WebFontKitStubOffline")
        let seed = UserDefaults.standard.string(forKey: "WebFontKitSeed")
        let seedAll = arguments.contains("-WebFontKitSeedAll")
        let race = arguments.contains("-WebFontKitRace")

        guard let directory else {
            if stub || offline || seed != nil || seedAll || race {
                FileHandle.standardError.write(Data("-WebFontKitDirectory is required in test mode\n".utf8))
                exit(1)
            }
            return .showcase
        }

        var session: URLSession?
        if stub || offline {
            ExampleStub.offline = offline
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ExampleStub.self]
            session = URLSession(configuration: configuration)
        }
        WebFonts.shared.configure(.init(
            storage: .persistent,
            directory: URL.temporaryDirectory.appending(component: directory),
            session: session
        ))

        if let seed {
            Task {
                do {
                    try await WebFonts.shared.load(seed)
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("seeding \(seed) failed: \(error)\n".utf8))
                    exit(1)
                }
            }
            return .seeding
        }
        if seedAll {
            try? FileManager.default.removeItem(at: raceFile)
            Task {
                let results = await WebFonts.shared.load(perfFamilies)
                appendRaceLine("seed allSucceeded=\(results.allSucceeded)")
                exit(results.allSucceeded ? 0 : 1)
            }
            return .seeding
        }
        if race {
            guard let family = perfFamilies.first else {
                preconditionFailure("No Perf fonts in the bundle: the race needs Tests/Fixtures/Perf")
            }
            return .race(family: family)
        }
        return .harness
    }

    static var raceFile: URL {
        URL.documentsDirectory.appending(component: "race.txt")
    }

    static func appendRaceLine(_ line: String) {
        let existing = (try? String(contentsOf: raceFile, encoding: .utf8)) ?? ""
        try? (existing + line + "\n").write(to: raceFile, atomically: true, encoding: .utf8)
    }
}

/// Answers Google's CSS2 and font requests from the fonts bundled in the app; the
/// test targets' stub is not visible here.
final class ExampleStub: URLProtocol {
    nonisolated(unsafe) static var offline = false

    /// Family name → bundled regular face, e.g. "Abril Fatface" → "Perf/AbrilFatface-Regular.ttf".
    static let bundledFamilies: [String: String] = {
        guard let url = Bundle.main.url(forResource: "Perf", withExtension: nil),
              let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return [:] }
        var families: [String: String] = [:]
        for name in names where name.hasSuffix("-Regular.ttf") {
            let compact = String(name.dropLast("-Regular.ttf".count))
            let family = compact.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            families[family] = "Perf/\(name)"
        }
        return families
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard !Self.offline, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        if url.host == "fonts.googleapis.com" {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? ""
            let family = String(query.prefix { $0 != ":" })
            guard Self.bundledFamilies[family] != nil, query.hasSuffix("@0,400") else {
                respond(400, type: "text/html", body: Data("<title>400: Font family not found</title>".utf8), url: url)
                return
            }
            let path = family.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? family
            let css = """
            @font-face {
              font-family: '\(family)';
              font-style: normal;
              font-weight: 400;
              src: url(https://fonts.gstatic.com/s/\(path)/v1/regular.ttf) format('truetype');
            }
            """
            respond(200, type: "text/css", body: Data(css.utf8), url: url)
            return
        }
        let family = url.pathComponents.count > 2 ? url.pathComponents[2] : ""
        guard let file = Self.bundledFamilies[family],
              let data = Bundle.main.url(forResource: file, withExtension: nil).flatMap({ try? Data(contentsOf: $0) })
        else {
            respond(404, type: "text/plain", body: Data(), url: url)
            return
        }
        respond(200, type: "font/ttf", body: data, url: url)
    }

    private func respond(_ status: Int, type: String, body: Data, url: URL) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
