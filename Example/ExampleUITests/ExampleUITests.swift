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
        let phases = app.staticTexts["phases"]
        let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: phases)
        XCTAssertEqual(XCTWaiter.wait(for: [match], timeout: 20), .completed, "phases were \(phases.value ?? "nil")")
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
        let seed = launch(["-WebFontKitDirectory", directory, "-WebFontKitStub", "-WebFontKitSeed", "Lobster"])
        XCTAssertTrue(seed.wait(for: .notRunning, timeout: 30))
        let app = launch(["-WebFontKitDirectory", directory, "-WebFontKitStubOffline"])
        let phases = app.staticTexts["phases"]
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value ENDSWITH 'loaded'"), object: phases)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 20), .completed, "phases were \(phases.value ?? "nil")")
        XCTAssertFalse((phases.value as? String ?? "").contains("failed"))
    }
}
