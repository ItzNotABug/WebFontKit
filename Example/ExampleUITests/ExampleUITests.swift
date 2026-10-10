import XCTest

/// The modifier on a real screen, stubbed through launch arguments. Each test starts from an empty store.
final class ExampleUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    @MainActor
    private func waitForPhases(_ app: XCUIApplication, _ expected: String) {
        waitForPhases(app, matching: NSPredicate(format: "value == %@", expected))
    }

    /// Returns the phases once they match, for further checks.
    @MainActor
    @discardableResult
    private func waitForPhases(_ app: XCUIApplication, matching predicate: NSPredicate) -> String {
        let phases = app.staticTexts["phases"]
        let match = XCTNSPredicateExpectation(predicate: predicate, object: phases)
        XCTAssertEqual(XCTWaiter.wait(for: [match], timeout: 20), .completed, "phases were \(phases.value ?? "nil")")
        return phases.value as? String ?? ""
    }

    @MainActor
    func testTheFontSwapsInAfterLoading() {
        let app = launch(["-WebFontKitDirectory", UUID().uuidString, "-WebFontKitStub"])
        XCTAssertTrue(app.staticTexts["greeting"].waitForExistence(timeout: 10))
        waitForPhases(app, "loading,loaded")
    }

    @MainActor
    func testOfflineWithNothingStoredReportsTheFailure() {
        let app = launch(["-WebFontKitDirectory", UUID().uuidString, "-WebFontKitStubOffline"])
        waitForPhases(app, "loading,failed(offline)")
    }

    @MainActor
    func testAStoredFontLoadsOfflineAfterARelaunch() {
        let directory = UUID().uuidString
        let seed = launch(["-WebFontKitDirectory", directory, "-WebFontKitStub", "-WebFontKitSeed", "Pacifico"])
        XCTAssertTrue(seed.wait(for: .notRunning, timeout: 30))
        let app = launch(["-WebFontKitDirectory", directory, "-WebFontKitStubOffline"])
        let phases = waitForPhases(app, matching: NSPredicate(format: "value ENDSWITH 'loaded'"))
        XCTAssertFalse(phases.contains("failed"))
    }
}
