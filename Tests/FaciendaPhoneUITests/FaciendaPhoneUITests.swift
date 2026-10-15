import XCTest

final class FaciendaPhoneUITests: XCTestCase {
    @MainActor func testWorkspaceCreationRenamingRoutingAndDrafts() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let switcher = app.buttons["workspaceSwitcher"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 10))
        switcher.tap()
        app.buttons["Manage workspaces…"].tap()
        app.buttons["newWorkspace"].tap()
        let name = app.textFields["workspaceName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Personal")
        app.buttons["saveWorkspace"].tap()
        XCTAssertTrue(app.buttons["Open Personal"].waitForExistence(timeout: 5))
        app.buttons["Rename Personal"].tap()
        let renamed = app.textFields["workspaceName"]
        XCTAssertTrue(renamed.waitForExistence(timeout: 5))
        renamed.tap(); renamed.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + "Home")
        app.buttons["saveWorkspace"].tap()
        XCTAssertTrue(app.buttons["Open Home"].waitForExistence(timeout: 5))
        app.buttons["Open Home"].tap()
        let request = app.textViews["taskRequest"]
        XCTAssertTrue(request.waitForExistence(timeout: 5))
        request.tap(); request.typeText("Home draft")
        app.toolbars.buttons["Done"].tap()
        switcher.tap(); app.buttons["Manage workspaces…"].tap()
        app.buttons["newWorkspace"].tap()
        let secondName = app.textFields["workspaceName"]
        XCTAssertTrue(secondName.waitForExistence(timeout: 5))
        secondName.tap(); secondName.typeText("Work")
        app.buttons["saveWorkspace"].tap()
        XCTAssertTrue(app.buttons["Open Work"].waitForExistence(timeout: 5))
        app.buttons["Open Work"].tap()
        XCTAssertTrue(request.waitForExistence(timeout: 5))
        XCTAssertEqual(request.value as? String, "")
        request.tap(); request.typeText("Work task")
        app.buttons["sendTask"].tap()
        XCTAssertTrue(app.staticTexts["Work task"].waitForExistence(timeout: 5))
        switcher.tap(); app.buttons["Home"].tap()
        XCTAssertFalse(app.staticTexts["Work task"].exists)
        app.tabBars.buttons["New task"].tap()
        XCTAssertTrue(request.waitForExistence(timeout: 5))
        XCTAssertEqual(request.value as? String, "Home draft")
        screenshot("Named workspace capture")
    }

    @MainActor func testCaptureAndLists() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let send = app.buttons["sendTask"]
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        let editor = app.textViews["taskRequest"]
        XCTAssertFalse(send.isEnabled)
        editor.tap()
        editor.typeText("Check tomorrow’s kitchen capture")
        XCTAssertTrue(send.isEnabled)
        send.tap()
        XCTAssertTrue(app.navigationBars["In progress"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Check tomorrow’s kitchen capture"].exists)
        XCTAssertTrue(app.staticTexts["Saved on this iPhone"].exists)
        screenshot("Captured task")
        app.tabBars.buttons["Tasks"].tap()
        XCTAssertTrue(app.staticTexts["Nothing to check yet."].waitForExistence(timeout: 5))
        app.tabBars.buttons["New task"].tap()
        XCTAssertFalse(send.isEnabled)
        XCTAssertTrue(app.buttons["voiceCapture"].isEnabled)
        screenshot("Capture screen")
    }

    @MainActor func testTaskCategoriesSearchAndDetails() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        app.tabBars.buttons["Tasks"].tap()
        XCTAssertTrue(app.staticTexts["Follow up on the camera repair"].waitForExistence(timeout: 5))
        screenshot("Waiting tasks")
        app.staticTexts["Follow up on the camera repair"].tap()
        XCTAssertTrue(app.staticTexts["Waiting for the repair shop’s estimate."].waitForExistence(timeout: 5))
        app.navigationBars["Task"].buttons["Tasks"].tap()
        XCTAssertTrue(app.staticTexts["Choose a weekend walking route"].exists)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Check next week’s weather"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Prepare the workshop checklist"].exists)
        screenshot("All task categories")
        app.swipeDown()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("checklist")
        XCTAssertTrue(app.staticTexts["Prepare the workshop checklist"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Follow up on the camera repair"].exists)
        app.staticTexts["Prepare the workshop checklist"].tap()
        XCTAssertTrue(app.staticTexts["The checklist is ready on your Mac."].waitForExistence(timeout: 5))
        screenshot("Completed task")
        app.navigationBars["Task"].buttons["Tasks"].tap()
        app.buttons["Close"].tap()
        app.tabBars.buttons["In progress"].tap()
        XCTAssertTrue(app.staticTexts["Find a quieter kitchen extractor"].waitForExistence(timeout: 5))
        screenshot("Processing tasks")
        app.buttons["iCloud connection"].tap()
        XCTAssertTrue(app.staticTexts["Preview"].waitForExistence(timeout: 5))
    }

    @MainActor func testDeniedMicrophoneKeepsTypingAvailable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.buttons["voiceCapture"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let denied = springboard.alerts.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Don")).firstMatch
        if denied.waitForExistence(timeout: 3) { denied.tap() }
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Allow microphone access")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.textViews["taskRequest"].isEnabled)
        XCTAssertFalse(app.buttons["sendTask"].isEnabled)
        screenshot("Microphone permission denied")
    }

    @MainActor func testLargeTextCaptureRemainsUsable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["voiceCapture"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["voiceCapture"].isHittable)
        XCTAssertTrue(app.buttons["Type a task"].isHittable)
        let requestFrame = app.textViews["taskRequest"].frame
        XCTAssertGreaterThanOrEqual(requestFrame.minX, app.frame.minX + 16)
        XCTAssertLessThanOrEqual(requestFrame.maxX, app.frame.maxX - 16)
        screenshot("Capture with large text")
        let editor = app.textViews["taskRequest"]
        if !editor.isHittable { app.swipeUp() }
        editor.tap(); editor.typeText("Plan tomorrow")
        app.buttons["sendTask"].tap()
        XCTAssertTrue(app.navigationBars["In progress"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Plan tomorrow"].exists)
    }

    @MainActor private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIApplication().screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
