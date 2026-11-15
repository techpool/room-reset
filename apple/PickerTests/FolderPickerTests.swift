import XCTest

final class FolderPickerTests: XCTestCase {
    func testFilesPickerAndSelectedRoom() throws {
        let app = XCUIApplication()
        app.launch()
        let folder = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "My folder")).firstMatch
        guard folder.waitForExistence(timeout: 25) else { return XCTFail("Game mode control unavailable: " + app.debugDescription) }
        folder.tap()
        let repick = app.buttons["Change folder"]
        if repick.waitForExistence(timeout: 2) { repick.tap() }

        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "Close"])).firstMatch
        guard cancel.waitForExistence(timeout: 20) else { return XCTFail("Files picker did not appear: " + app.debugDescription) }
        guard let name = ProcessInfo.processInfo.environment["ROOMRESET_FIXTURE"] else {
            cancel.tap()
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Practice")).firstMatch.exists)
            return
        }
        func labeled(_ text: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
        }
        let fixture = labeled(name)
        if !fixture.exists {
            let location = labeled("On My iPhone")
            let browse = app.buttons["Browse"].firstMatch
            if !location.exists && browse.exists { browse.tap() }
            if !location.exists {
                // Return from the picker's most recently used directory to Locations.
                for _ in 0..<6 {
                    let back = app.navigationBars.buttons.element(boundBy: 0)
                    if location.exists || !back.exists || back.label == "Cancel" { break }
                    back.tap()
                }
            }
            guard location.waitForExistence(timeout: 8) else { return XCTFail("Local Files location unavailable: " + app.debugDescription) }
            location.tap()
        }
        guard fixture.waitForExistence(timeout: 15) else { return XCTFail("Fixture missing from Files picker: " + app.debugDescription) }
        fixture.tap()
        app.buttons["Open"].firstMatch.tap()
        XCTAssertTrue(repick.waitForExistence(timeout: 20))
        let sweep = app.buttons["Sweep room"]
        XCTAssertTrue(sweep.isEnabled)
        sweep.tap()
        app.buttons["Tidy files"].tap()
        let undo = app.buttons["Undo last tidy"]
        let enabled = NSPredicate(format: "enabled == true")
        let canUndo = XCTNSPredicateExpectation(predicate: enabled, object: undo)
        XCTAssertEqual(XCTWaiter.wait(for: [canUndo], timeout: 20), .completed)
        undo.tap()
        let canTidyAgain = XCTNSPredicateExpectation(predicate: enabled, object: sweep)
        XCTAssertEqual(XCTWaiter.wait(for: [canTidyAgain], timeout: 10), .completed)
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Practice")).firstMatch.tap()
    }
}
