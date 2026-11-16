import XCTest

/// Edit Server (D139) against a real server (read-only: `ping` only): signs in, edits the address
/// from the switcher's ⋯ menu to another one for the same server, then opens Edit Server from the
/// unreachable screen. Skipped unless given a login file kept **outside the repo**, JSON
/// `{"url": "https://…", "username": "…", "password": "…", "editTo": "https://…"}`:
///
///     TEST_RUNNER_NAVINX_LIVE=/path/login.json TEST_RUNNER_NAVINX_SHOTS=/path/shots \
///       xcodebuild test -scheme Navinx -only-testing:NavinxUITests/EditServerUITests -destination …
///
/// It resets the app's saved logins.
final class EditServerUITests: XCTestCase {
    private struct Login: Decodable { let url: String; let username: String; let password: String; let editTo: String }

    private var app: XCUIApplication!
    private var shots: URL?

    override func setUp() async throws {
        continueAfterFailure = false
        if let dir = ProcessInfo.processInfo.environment["NAVINX_SHOTS"] {
            shots = URL(filePath: dir)
            try? FileManager.default.createDirectory(at: shots!, withIntermediateDirectories: true)
        }
    }

    @MainActor
    func testEditServer() throws {
        guard let path = ProcessInfo.processInfo.environment["NAVINX_LIVE"] else {
            throw XCTSkip("No login file (TEST_RUNNER_NAVINX_LIVE)")
        }
        let login = try JSONDecoder().decode(Login.self, from: Data(contentsOf: URL(filePath: path)))

        app = XCUIApplication()
        app.launchArguments = ["-UITestReset"]
        app.launch()
        XCTAssert(app.buttons["connect"].waitForExistence(timeout: 10))
        type(login.url, into: app.textFields["Server URL"])
        type(login.username, into: app.textFields["Username"])
        type(login.password + "\n", into: app.secureTextFields["Password"])
        XCTAssert(app.buttons["settingsGear"].waitForExistence(timeout: 20))
        dismissSavePassword()

        // Settings → Server → Switch → ⋯ → Edit Server: the login screen, filled in.
        openServerSettings()
        let addServer = app.buttons["addServer"]
        for _ in 0..<2 where !addServer.exists {
            app.buttons["settingsSwitchServer"].tap()
            if addServer.waitForExistence(timeout: 4) { break }
            dismissSavePassword()
        }
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'More for'")).element(boundBy: 0).tap()
        let edit = app.buttons["Edit Server"]
        XCTAssert(edit.waitForExistence(timeout: 3))
        shot("e1-menu")
        edit.tap()
        let server = app.textFields["Server URL"]
        XCTAssert(server.waitForExistence(timeout: 5))
        sleep(1)
        shot("e2-edit-filled")
        XCTAssertEqual(server.value as? String, login.url)
        XCTAssertEqual(app.textFields["Username"].value as? String, login.username)
        XCTAssertFalse(app.staticTexts["Saved Profiles"].exists)

        // A new address: connected, the sheets close, the profile shows it.
        // Tapped at its end, so the cursor is after the last character.
        server.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        let count = (server.value as? String)?.count ?? 0
        server.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count + 5) + login.editTo)
        XCTAssertEqual(server.value as? String, login.editTo)
        app.buttons["connect"].tap()
        let connected = app.descendants(matching: .any)["toast"].waitForExistence(timeout: 20)
        shot("e3-connected")
        XCTAssert(connected)
        let newHost = URL(string: login.editTo)!.host()!
        XCTAssert(app.staticTexts[newHost].waitForExistence(timeout: 5))
        shot("e4-settings-new-address")

        // The unreachable screen offers it too; Cancel leaves it as it was.
        app.terminate()
        app.launchArguments = ["-UITestUnreachable"]
        app.launch()
        let editServer = app.buttons["editServer"]
        XCTAssert(editServer.waitForExistence(timeout: 20))
        shot("e5-unreachable")
        editServer.tap()
        XCTAssert(app.textFields["Server URL"].waitForExistence(timeout: 5))
        sleep(1)
        shot("e6-unreachable-edit")
        XCTAssertEqual(app.textFields["Server URL"].value as? String, login.editTo)
        app.buttons["editServerCancel"].tap()
        XCTAssert(app.buttons["retry"].waitForExistence(timeout: 5))
    }

    // MARK: Helpers (as in AccountFlowUITests)

    @MainActor
    private func type(_ text: String, into field: XCUIElement) {
        XCTAssert(field.waitForExistence(timeout: 5), "\(field)")
        for attempt in 0..<3 {
            field.tap()
            if app.keyboards.firstMatch.waitForExistence(timeout: 3) { break }
            if attempt == 0 { dismissSavePassword() } else { sleep(1) }
        }
        field.typeText(text)
    }

    @MainActor
    private func openServerSettings() {
        let gear = app.buttons["settingsGear"]
        XCTAssert(gear.waitForExistence(timeout: 10))
        let serverTab = app.buttons["settingsTab-Server"]
        for _ in 0..<2 where !serverTab.exists {
            gear.tap()
            if serverTab.waitForExistence(timeout: 4) { break }
            dismissSavePassword()
        }
        serverTab.tap()
        XCTAssert(app.buttons["settingsSwitchServer"].waitForExistence(timeout: 5))
        sleep(1)
    }

    @MainActor
    private func dismissSavePassword() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for owner in [app!, springboard] {
            let notNow = owner.buttons["Not Now"]
            if notNow.waitForExistence(timeout: owner == springboard ? 1 : 8) {
                notNow.tap()
                sleep(1)
                return
            }
        }
    }

    @MainActor
    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots {
            try? screenshot.pngRepresentation.write(to: shots.appending(path: "\(name).png"))
        }
    }
}
