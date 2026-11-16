import XCTest

/// Walks the account flows against the real server (read-only: `ping` only) and saves a screenshot
/// at each step. Skipped unless given a login file kept **outside the repo**, JSON
/// `{"url": "http://…:4533", "username": "…", "password": "…"}`:
///
///     TEST_RUNNER_NAVINX_LIVE=/path/login.json TEST_RUNNER_NAVINX_SHOTS=/path/shots \
///       xcodebuild test -scheme NavinxUITests -destination …
///
/// Screenshots go to `NAVINX_SHOTS` (if set), named `<step>.png`. It resets the app's saved logins.
final class AccountFlowUITests: XCTestCase {
    private struct Login: Decodable { let url: String; let username: String; let password: String }

    private var app: XCUIApplication!
    private var shots: URL?
    private var prefix = ""

    override func setUp() async throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        if let dir = env["NAVINX_SHOTS"] {
            shots = URL(filePath: dir)
            try? FileManager.default.createDirectory(at: shots!, withIntermediateDirectories: true)
        }
        prefix = env["NAVINX_SHOT_PREFIX"] ?? ""
    }

    @MainActor
    func testAccountFlows() throws {
        guard let path = ProcessInfo.processInfo.environment["NAVINX_LIVE"] else {
            throw XCTSkip("No login file (TEST_RUNNER_NAVINX_LIVE)")
        }
        let login = try JSONDecoder().decode(Login.self, from: Data(contentsOf: URL(filePath: path)))

        app = XCUIApplication()
        app.launchArguments = ["-UITestReset"]
        app.launch()

        // Login screen, empty, then the validators.
        let connect = app.buttons["connect"]
        XCTAssert(connect.waitForExistence(timeout: 10))
        shot("01-login")
        connect.tap()
        XCTAssert(app.staticTexts["Please enter server URL"].waitForExistence(timeout: 2))
        XCTAssert(app.staticTexts["Please enter username"].exists)
        shot("02-login-validation")

        // Wrong password: the error card.
        type(login.url, into: app.textFields["Server URL"])
        type(login.username, into: app.textFields["Username"])
        type("not-the-password\n", into: app.secureTextFields["Password"])
        XCTAssert(app.descendants(matching: .any)["signInFailure"].waitForExistence(timeout: 15))
        shot("03-sign-in-failure")

        // Right password: the app.
        let password = app.secureTextFields["Password"]
        password.tap()
        password.typeText(login.password + "\n")  // a secure field clears when typed into again
        let gear = app.buttons["settingsGear"]
        XCTAssert(gear.waitForExistence(timeout: 15))
        dismissSavePassword()
        shot("04-home")

        // Settings → Server, then the switcher, with one server. "Save Password?" can come late and
        // swallow a tap (`docs/gotchas.md`).
        openServerSettings()
        shot("05a-settings-server")
        let addServer = app.buttons["addServer"]
        openSwitcher()
        shot("05-switcher")

        // Add Server: a wrong password keeps the current server, then a second profile.
        addServer.tap()
        let save = app.buttons["connectAndSave"]
        XCTAssert(save.waitForExistence(timeout: 5))
        sleep(1)
        shot("06-add-server")
        type("Second", into: app.textFields["Profile Name (Optional)"])
        // A trailing slash: the same server, but another address to the unreachable screen's
        // Switch Server list (which offers only other addresses or users, as in Flutter).
        type(login.url + "/", into: app.textFields["Server URL *"])
        type(login.username, into: app.textFields["Username *"])
        type("not-the-password\n", into: app.secureTextFields["Password *"])
        XCTAssert(app.descendants(matching: .any)["connectionError"].waitForExistence(timeout: 15))
        shot("07-add-server-error")
        let addPassword = app.secureTextFields["Password *"]
        addPassword.tap()
        addPassword.typeText(login.password + "\n")
        XCTAssert(app.descendants(matching: .any)["toast"].waitForExistence(timeout: 15))
        shot("08-connected-toast")
        dismissSavePassword()

        // Signed in to the new server, the app starts again on Home. Settings → Server lists two
        // servers; then the switcher's ⋯ menu; rename the first.
        openServerSettings()
        XCTAssert(app.buttons["savedServer-Second"].waitForExistence(timeout: 5))
        shot("08a-settings-two-servers")
        openSwitcher()
        shot("09-switcher-two")
        let more = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'More for'")).element(boundBy: 0)
        more.tap()
        let rename = app.buttons["Rename Profile"]
        XCTAssert(rename.waitForExistence(timeout: 3))
        shot("10-switcher-menu")
        rename.tap()
        let nameField = app.alerts.textFields.firstMatch
        XCTAssert(nameField.waitForExistence(timeout: 3))
        nameField.clearAndType("Home")
        shot("11-rename")
        // On the iPhone Duo this tap doesn't land (the alert stays up), so the walk-through stops
        // here there; it passes on the iPhone 17 Pro. See docs/gotchas.md.
        app.alerts.buttons["Save"].tap()
        let homeCard = app.staticTexts["serverName-Home"]
        let renamed = homeCard.waitForExistence(timeout: 5)
        shot("12-renamed")
        XCTAssert(renamed)

        // Switch to Home: the connecting screen, then "Connected to Home".
        homeCard.tap()
        XCTAssert(app.descendants(matching: .any)["toast"].waitForExistence(timeout: 15))
        shot("13-switched")

        // Logout, from Settings → Server, keeps the saved servers as chips on the login screen.
        openServerSettings()
        app.buttons["settingsLogout"].tap()
        let confirm = app.alerts.buttons["Sign Out"]
        XCTAssert(confirm.waitForExistence(timeout: 3))
        shot("14-logout-confirm")
        confirm.tap()
        XCTAssert(app.staticTexts["Saved Profiles"].waitForExistence(timeout: 5))
        shot("15-login-chips")

        // Connect from a chip, then relaunch with the server "down".
        app.buttons["Home"].tap()
        XCTAssert(gear.waitForExistence(timeout: 15))
        app.terminate()
        app.launchArguments = ["-UITestUnreachable"]
        app.launch()
        sleep(1)
        shot("16-connecting")
        sleep(5)
        shot("17-connecting-slow")
        let retry = app.buttons["retry"]
        XCTAssert(retry.waitForExistence(timeout: 15))
        shot("18-unreachable")
        app.buttons["Switch Server"].tap()
        sleep(1)
        shot("19-unreachable-switch")
        app.swipeDown(velocity: .fast)
        sleep(1)
        app.buttons["disconnect"].tap()
        XCTAssert(app.staticTexts["Saved Profiles"].waitForExistence(timeout: 5))
    }

    // MARK: Helpers

    /// Types into a field once the keyboard is up: a late "Save Password?" can take the first tap,
    /// and a form that has just appeared can miss it, so it taps again if it must.
    @MainActor
    private func type(_ text: String, into field: XCUIElement) {
        XCTAssert(field.waitForExistence(timeout: 5), "\(field)")
        for attempt in 0..<3 {
            field.tap()
            if app.keyboards.firstMatch.waitForExistence(timeout: 3), field.hasFocus { break }
            if attempt == 0 { dismissSavePassword() } else { sleep(1) }
        }
        field.typeText(text)
    }

    /// Home's gear, then Settings' Server tab.
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

    /// The Server tab's Switch button opens the switcher sheet.
    @MainActor
    private func openSwitcher() {
        let addServer = app.buttons["addServer"]
        for _ in 0..<2 where !addServer.exists {
            app.buttons["settingsSwitchServer"].tap()
            if addServer.waitForExistence(timeout: 4) { break }
            dismissSavePassword()
        }
        XCTAssert(addServer.waitForExistence(timeout: 5))
        sleep(1)
    }

    /// iOS offers to save the password after a login; answer "Not Now".
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
            try? screenshot.pngRepresentation.write(to: shots.appending(path: "\(prefix)\(name).png"))
        }
    }
}

private extension XCUIElement {
    var hasFocus: Bool { (value(forKey: "hasKeyboardFocus") as? Bool) ?? false }

    /// Deletes the field's text, then types `text`.
    func clearAndType(_ text: String) {
        tap()
        let count = (value as? String)?.count ?? 0
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count) + text)
    }
}
