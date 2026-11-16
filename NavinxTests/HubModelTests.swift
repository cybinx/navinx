import DeviceCheck
import Foundation
import HubKit
import PlaybackKit
import SubsonicKit
import UIKit
import Testing
@testable import Navinx

/// A stand-in server for the hub's model.
private actor FakeHub: HubAPI {
    var probeAnswer: HubProbe
    var screens: [String: HubScreen] = [:]
    var reply: Result<HubReply, HubError> = .success(HubReply(present: .none))
    var replyDelay: Duration = .zero
    var probeDelay: Duration = .zero
    private(set) var probes = 0
    private(set) var sent: [HubRequest] = []
    private(set) var fetched: [String] = []

    init(_ probe: HubProbe) { probeAnswer = probe }

    func set(probe: HubProbe, delay: Duration = .zero) {
        probeAnswer = probe
        probeDelay = delay
    }
    func set(screen: HubScreen) { screens[screen.id] = screen }
    func set(reply: Result<HubReply, HubError>, delay: Duration = .zero) {
        self.reply = reply
        replyDelay = delay
    }

    nonisolated func probe() async -> HubProbe {
        let (answer, delay) = await countProbe()
        try? await Task.sleep(for: delay)
        return answer
    }
    private func countProbe() -> (HubProbe, Duration) {
        probes += 1
        return (probeAnswer, probeDelay)
    }

    nonisolated func screen(_ id: String) async throws(HubError) -> HubScreen {
        guard let screen = await fetch(id) else { throw .refused(status: 403) }
        return screen
    }
    private func fetch(_ id: String) -> HubScreen? {
        fetched.append(id)
        return screens[id]
    }

    nonisolated func send(_ request: HubRequest) async throws(HubError) -> HubReply {
        let (result, delay) = await record(request)
        try? await Task.sleep(for: delay)
        return try result.get()
    }
    private func record(_ request: HubRequest) -> (Result<HubReply, HubError>, Duration) {
        sent.append(request)
        return (reply, replyDelay)
    }
}

private func root(title: String = "Tab", link: String = "", refresh: Int? = nil) -> HubScreen {
    HubScreen(id: "main", title: title, tab: HubTab(title: title, symbol: "star"), refresh: refresh, sections: [
        HubSection(id: "mode", card: .none, parts: [
            .choice(HubChoice(
                id: "mode", options: [.init(id: "a", label: "A"), .init(id: "b", label: "B")], value: "a",
                action: HubAction(id: "mode", sends: ["mode"])
            )),
        ]),
        HubSection(id: "link", parts: [
            .field(HubField(id: "link", value: link, button: HubButton(
                id: "check", label: "Check", action: HubAction(id: "check", sends: ["link"]), needs: ["link"]
            ))),
        ]),
    ])
}

@MainActor
struct HubModelTests {
    private func model(_ fake: FakeHub?, connection: HubConnection? = nil) -> (HubModel, ToastBox) {
        let model = HubModel()
        let toasts = ToastBox()
        model.connect = {
            if let connection { return connection }
            guard let fake else { return .offline }
            return .ready(fake)
        }
        model.onToast = { toasts.texts.append($0) }
        return (model, toasts)
    }

    @Test func aScreenWithATabShowsTheTab() async {
        let fake = FakeHub(.shown(root()))
        let (model, _) = model(fake)
        #expect(!model.isShown)
        await model.probe()
        #expect(model.isShown && model.tab?.title == "Tab")
    }

    @Test func aRefusalHidesItAndNoAnswerKeepsIt() async {
        let fake = FakeHub(.shown(root()))
        let (model, _) = model(fake)
        await model.probe()
        await fake.set(probe: .unreachable)
        await model.probe()
        #expect(model.isShown, "no answer doesn't take a shown tab away")
        await fake.set(probe: .absent)
        await model.probe()
        #expect(!model.isShown)
        await fake.set(probe: .unreachable)
        await model.probe()
        #expect(!model.isShown, "a hidden tab stays hidden")
    }

    @Test func aNewlyAllowedAccountGetsItOnTheNextProbe() async {
        let fake = FakeHub(.absent)
        let (model, _) = model(fake)
        await model.probe()
        #expect(!model.isShown)
        await fake.set(probe: .shown(root()))
        await model.probe()   // the return to the foreground
        #expect(model.isShown)
    }

    @Test func offlineAsksNothingAndKeepsTheTab() async {
        let fake = FakeHub(.shown(root()))
        let (model, toasts) = model(fake)
        await model.probe()
        model.connect = { .offline }
        await model.probe()
        #expect(model.isShown)
        #expect(await fake.probes == 1)
        await model.post(HubAction(id: "check"), from: model.root!)
        #expect(toasts.texts == [HubModel.failedMessage], "its calls fail with the app's own message")
    }

    @Test func legacyAuthHasNoTab() async {
        let fake = FakeHub(.shown(root()))
        let (model, _) = model(fake)
        await model.probe()
        model.connect = { .noLogin }
        await model.probe()
        #expect(!model.isShown)
    }

    @Test func aNewerProbeSupersedesAnOlderOne() async throws {
        let fake = FakeHub(.absent)
        let (model, _) = model(fake)
        await fake.set(probe: .absent, delay: .milliseconds(200))
        let old = Task { await model.probe() }   // the old address, still on its way
        try await Task.sleep(for: .milliseconds(50))
        await fake.set(probe: .shown(root()))
        await model.probe()                      // the new address
        await old.value
        #expect(model.isShown, "the old probe's late answer is ignored")
        #expect(await fake.probes == 2, "the new probe isn't skipped for the old one")
    }

    @Test func typedTextSurvivesARefresh() async {
        let fake = FakeHub(.shown(root(link: "")))
        let (model, _) = model(fake)
        await model.probe()
        let page = model.root!
        page.texts["link"] = "typed"
        await fake.set(screen: root(link: ""))
        #expect(await model.refresh(page))
        #expect(page.text("link") == "typed", "the server's value didn't change, so the typing stays")
        await fake.set(screen: root(link: "from the server"))
        await model.refresh(page)
        #expect(page.text("link") == "from the server", "a changed value replaces it")
        page.texts["link"] = "again"
        await fake.set(screen: root(link: ""))
        await model.refresh(page)
        #expect(page.text("link") == "", "Add another clears it")
    }

    @Test func anActionSendsWhatItNames() async throws {
        let fake = FakeHub(.shown(root()))
        let (model, toasts) = model(fake)
        await model.probe()
        let page = model.root!
        page.texts["link"] = " https://example.com/a "
        await fake.set(reply: .success(HubReply(present: .replace, screen: root(title: "Next"), toast: "Done.")))
        await model.post(HubAction(id: "check", sends: ["link", "mode"]), from: page, control: "check")
        let sent = try #require(await fake.sent.first)
        #expect(sent == HubRequest(screen: "main", action: "check", values: ["link": " https://example.com/a ", "mode": "a"]))
        #expect(page.screen.title == "Next")
        #expect(toasts.texts == ["Done."])
        #expect(!page.isSending)
    }

    @Test func aPickShowsAtOnceAndPostsTheOption() async throws {
        let fake = FakeHub(.shown(root()))
        let (model, _) = model(fake)
        await model.probe()
        let page = model.root!
        let choice = page.screen.choices[0]
        await fake.set(reply: .success(HubReply(present: .none)), delay: .milliseconds(200))
        let posting = Task { await model.pick("b", in: choice, on: page) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(page.value(of: choice) == "b", "shown before the reply")
        #expect(page.sending == "mode")
        await posting.value
        #expect(await fake.sent.first?.values == ["mode": "b"])
    }

    @Test func aFailedPostKeepsTheScreenAndSaysSo() async {
        let fake = FakeHub(.shown(root()))
        let (model, toasts) = model(fake)
        await model.probe()
        await fake.set(reply: .failure(.refused(status: 403)))
        await model.post(HubAction(id: "check"), from: model.root!)
        #expect(model.root?.screen == root())
        #expect(toasts.texts == [HubModel.failedMessage])
    }

    @Test func aRefreshDuringAPostIsDropped() async throws {
        let fake = FakeHub(.shown(root()))
        let (model, _) = model(fake)
        await model.probe()
        let page = model.root!
        await fake.set(reply: .success(HubReply(present: .replace, screen: root(title: "Reply"))), delay: .milliseconds(200))
        await fake.set(screen: root(title: "Refresh"))
        let posting = Task { await model.post(HubAction(id: "check"), from: page) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await !model.refresh(page), "paused while the post is on its way")
        await posting.value
        #expect(page.screen.title == "Reply", "the post's reply wins")
    }

    @Test func sheetsOpenAndCloseOntoTheScreenUnder() async {
        let fake = FakeHub(.shown(root()))
        let (model, _) = model(fake)
        await model.probe()
        let sheet = HubScreen(id: "request-1", sheetHeight: 300, sections: [])
        await fake.set(reply: .success(HubReply(present: .sheet, screen: sheet)))
        await model.post(HubAction(id: "open:1"), from: model.root!)
        #expect(model.sheet?.screen.id == "request-1")
        await fake.set(reply: .success(HubReply(present: .dismiss, screen: root(title: "Under"), toast: "Searching again.")))
        await model.post(HubAction(id: "again:1"), from: model.sheet!)
        #expect(model.sheet == nil)
        #expect(model.root?.screen.title == "Under")
    }

    @Test func pushAddsAPageToTheTabsStack() async {
        let fake = FakeHub(.shown(root()))
        let (model, _) = model(fake)
        await model.probe()
        await fake.set(reply: .success(HubReply(present: .push, screen: HubScreen(id: "more", title: "More"))))
        await model.post(HubAction(id: "more"), from: model.root!)
        guard case .screen(let id) = model.path.last else { Issue.record("nothing pushed"); return }
        #expect(model.page(id)?.screen.title == "More")
        model.path.removeAll()
        model.pathChanged()
        #expect(model.page(id) == nil)
    }

    @Test func anAcceptedPickWithNoScreenIsKept() async {
        let fake = FakeHub(.shown(root()))
        let (model, _) = model(fake)
        await model.probe()
        let page = model.root!
        let choice = page.screen.choices[0]
        await model.pick("b", in: choice, on: page)
        #expect(page.value(of: choice) == "b", "the server accepted it, so it doesn't snap back")
    }

    @Test func aFailedPickGoesBackToTheServersOption() async {
        let fake = FakeHub(.shown(root()))
        let (model, _) = model(fake)
        await model.probe()
        let page = model.root!
        let choice = page.screen.choices[0]
        await fake.set(reply: .failure(.refused(status: 403)))
        await model.pick("b", in: choice, on: page)
        #expect(page.value(of: choice) == "a")
    }

    @Test func aReplyForAPoppedPageIsDropped() async throws {
        let fake = FakeHub(.shown(root()))
        let (model, _) = model(fake)
        await model.probe()
        await fake.set(reply: .success(HubReply(present: .push, screen: HubScreen(id: "more", title: "More"))))
        await model.post(HubAction(id: "more"), from: model.root!)
        guard case .screen(let id) = model.path.last, let pushed = model.page(id) else {
            Issue.record("nothing pushed")
            return
        }
        await fake.set(reply: .success(HubReply(present: .push, screen: HubScreen(id: "deeper", title: "Deeper"))), delay: .milliseconds(200))
        let posting = Task { await model.post(HubAction(id: "deeper"), from: pushed) }
        try await Task.sleep(for: .milliseconds(50))
        model.path.removeAll()
        model.pathChanged()
        await posting.value
        #expect(model.path.isEmpty, "the user went back, so nothing is pushed")
    }

    @Test func aDismissFromAnotherPageKeepsTheSheet() async {
        let fake = FakeHub(.shown(root()))
        let (model, _) = model(fake)
        await model.probe()
        await fake.set(reply: .success(HubReply(present: .sheet, screen: HubScreen(id: "request-1", sheetHeight: 300, sections: []))))
        await model.post(HubAction(id: "open:1"), from: model.root!)
        await fake.set(reply: .success(HubReply(present: .dismiss)))
        await model.post(HubAction(id: "other"), from: model.root!)
        #expect(model.sheet?.screen.id == "request-1")
    }

    @Test func aFieldTheActionSentTakesTheRepliesValue() async {
        let fake = FakeHub(.shown(root(link: "")))
        let (model, _) = model(fake)
        await model.probe()
        let page = model.root!
        page.texts["link"] = "https://example.com/a"
        await fake.set(reply: .success(HubReply(present: .replace, screen: root(link: ""))))
        await model.post(HubAction(id: "check", sends: ["link"]), from: page, control: "check")
        #expect(page.text("link") == "", "the reply repeats the empty value, which clears what was sent")
        page.texts["link"] = "kept"
        await model.post(HubAction(id: "other"), from: page)
        #expect(page.text("link") == "kept", "a field the action didn't send is left alone")
    }

    @Test func aPullToRefreshDuringAPostIsNotAFailure() async throws {
        let fake = FakeHub(.shown(root()))
        let (model, toasts) = model(fake)
        await model.probe()
        await fake.set(reply: .success(HubReply(present: .none)), delay: .milliseconds(200))
        let posting = Task { await model.post(HubAction(id: "check"), from: model.root!) }
        try await Task.sleep(for: .milliseconds(50))
        await model.reload()
        await posting.value
        #expect(toasts.texts.isEmpty)
    }

    @Test func aSheetSwipedAwayStillGetsItsToastAndRefreshesTheParent() async throws {
        let fake = FakeHub(.shown(root()))
        let (model, toasts) = model(fake)
        await model.probe()
        await fake.set(reply: .success(HubReply(present: .sheet, screen: HubScreen(id: "request-1", sections: []))))
        await model.post(HubAction(id: "open:1"), from: model.root!)
        let sheet = try #require(model.sheet)
        await fake.set(
            reply: .success(HubReply(present: .dismiss, screen: root(title: "Under"), toast: "Saved.")),
            delay: .milliseconds(200)
        )
        let posting = Task { await model.post(HubAction(id: "save"), from: sheet) }
        try await Task.sleep(for: .milliseconds(50))
        model.sheet = nil   // swiped away
        await posting.value
        #expect(toasts.texts == ["Saved."])
        #expect(model.root?.screen.title == "Under")
    }

    @Test func aDismissWhoseOpenerIsGoneLeavesTheRootAlone() async throws {
        let fake = FakeHub(.shown(root(title: "Root")))
        let (model, toasts) = model(fake)
        await model.probe()
        await fake.set(reply: .success(HubReply(present: .push, screen: HubScreen(id: "more", title: "More"))))
        await model.post(HubAction(id: "more"), from: model.root!)
        guard case .screen(let id) = model.path.last, let pushed = model.page(id) else {
            Issue.record("nothing pushed")
            return
        }
        await fake.set(reply: .success(HubReply(present: .sheet, screen: HubScreen(id: "request-1", sections: []))))
        await model.post(HubAction(id: "open:1"), from: pushed)
        let sheet = try #require(model.sheet)
        model.path.removeAll()   // the opener goes
        model.pathChanged()
        await fake.set(reply: .success(HubReply(present: .dismiss, screen: root(title: "Elsewhere"), toast: "Done.")))
        await model.post(HubAction(id: "save"), from: sheet)
        #expect(model.sheet == nil)
        #expect(model.root?.screen.title == "Root", "the screen was meant for the page that's gone")
        #expect(toasts.texts == ["Done."])
    }

    @Test func searchesPushesAndSheetsHaveNowhereToShow() async {
        let fake = FakeHub(.shown(root()))
        let (model, _) = model(fake)
        await model.probe()
        await fake.set(reply: .success(HubReply(present: .replace, screen: HubScreen(id: "search"))))
        await model.searchAfterPause("radiohead", delay: .zero)
        let page = model.search!
        await fake.set(reply: .success(HubReply(present: .push, screen: HubScreen(id: "more", title: "More"))))
        await model.post(HubAction(id: "more"), from: page)
        await fake.set(reply: .success(HubReply(present: .sheet, screen: HubScreen(id: "request-1", sections: []))))
        await model.post(HubAction(id: "open:1"), from: page)
        #expect(model.path.isEmpty && model.sheet == nil)
    }

    @Test func aSearchWaitsForAnotherActionOnItsPage() async throws {
        let fake = FakeHub(.shown(root()))
        let (model, toasts) = model(fake)
        await model.probe()
        await fake.set(reply: .success(HubReply(present: .replace, screen: HubScreen(id: "search"))))
        await model.searchAfterPause("ab", delay: .zero)
        let page = try #require(model.search)
        await fake.set(reply: .success(HubReply(present: .none, toast: "Done.")), delay: .milliseconds(150))
        let button = Task { await model.post(HubAction(id: "go"), from: page, control: "go") }
        try await Task.sleep(for: .milliseconds(30))
        await model.searchAfterPause("abc", delay: .zero)
        await button.value
        #expect(await fake.sent.map(\.action) == ["search", "go", "search"])
        #expect(toasts.texts == ["Done.", "Done."], "the button's answer wasn't orphaned by the search")
        #expect(!page.isSending)
    }

    @Test func searchResultsGoWhenTheQueryIsTooShortOrTheSearchFails() async {
        let fake = FakeHub(.shown(root()))
        let (model, _) = model(fake)
        await model.probe()
        let section = HubScreen(id: "search", sections: [HubSection(id: "find", title: "From", card: .none, parts: [])])
        await fake.set(reply: .success(HubReply(present: .replace, screen: section)))
        await model.searchAfterPause("radiohead", delay: .zero)
        #expect(model.search != nil)
        await model.searchAfterPause("r", delay: .zero)
        #expect(model.search == nil, "the old query's results don't stay under the new text")
        await model.searchAfterPause("radiohead", delay: .zero)
        #expect(model.search != nil)
        await fake.set(reply: .failure(.unreachable))
        await model.searchAfterPause("radiohead!", delay: .zero)
        #expect(model.search == nil, "a failed search leaves no stale results")
    }

    @Test func searchAsksOnlyWithTheTab() async {
        let hidden = FakeHub(.absent)
        let (unflagged, _) = model(hidden)
        await unflagged.probe()
        await unflagged.searchAfterPause("radiohead", delay: .zero)
        #expect(await hidden.sent.isEmpty, "an account without the tab sends nothing")
        #expect(unflagged.search == nil)

        let fake = FakeHub(.shown(root()))
        let (model, _) = model(fake)
        await model.probe()
        await model.searchAfterPause("r", delay: .zero)
        #expect(await fake.sent.isEmpty, "two characters or more")
        let section = HubScreen(id: "search", sections: [HubSection(id: "find", title: "From", card: .none, parts: [])])
        await fake.set(reply: .success(HubReply(present: .replace, screen: section)))
        await model.searchAfterPause("  radiohead ", delay: .zero)
        #expect(await fake.sent == [HubRequest(screen: "search", action: "search", values: ["q": "radiohead"])])
        #expect(model.search?.screen.sections.first?.id == "find")
    }

    @Test func theConnectorReusesALoginForAWhile() throws {
        let connector = HubConnector()
        #expect({ if case .offline = connector.connection(client: nil, offline: false) { true } else { false } }())
        let config = ServerConfig(serverURL: "http://music.example:4533", username: "api", password: "pw")
        let client = try SubsonicClient(config: config, coverArtSalt: "salt")
        #expect({ if case .offline = connector.connection(client: client, offline: true) { true } else { false } }())
        let start = Date()
        guard case .ready(let first) = connector.connection(client: client, offline: false, now: start),
              case .ready(let second) = connector.connection(client: client, offline: false, now: start + 60)
        else { Issue.record("no client"); return }
        #expect((first as? HubClient)?.baseURL == (second as? HubClient)?.baseURL)
        let legacy = try SubsonicClient(
            config: ServerConfig(serverURL: "http://music.example:4533", username: "api", password: "pw", sendsPlainPassword: true),
            coverArtSalt: "salt"
        )
        #expect({ if case .noLogin = HubConnector().connection(client: legacy, offline: false) { true } else { false } }())
    }

    @Test func nothingIsSentWithoutASignedLogin() async throws {
        let sessions = HubSessions(session: Recorder.session)
        let legacy = try SubsonicClient(
            config: ServerConfig(serverURL: "http://unsigned.example:4533", username: "api", password: "pw", sendsPlainPassword: true),
            coverArtSalt: "salt"
        )
        // An https server reached at a plain http address: no downgrade.
        let downgraded = try SubsonicClient(
            config: ServerConfig(serverURL: "https://unsigned.example", homeNetworkURL: "http://unsigned.example:4533", username: "api", password: "pw"),
            baseURL: URL(string: "http://unsigned.example:4533")!, coverArtSalt: "salt"
        )
        for client in [legacy, downgraded] {
            #expect(try await LevelPreloader.fetch("s1", client: client, profile: UUID(), sessions: sessions) == .unavailable)
            #expect({ if case .noLogin = HubConnector(sessions: sessions).connection(client: client, offline: false) { true } else { false } }())
        }
        #expect(Recorder.hosts.isEmpty, "no sign-in and no old-way request")
    }

    @Test func theConnectorsClientIsTheAccountsAtItsAddress() throws {
        let client = try SubsonicClient(
            config: ServerConfig(serverURL: "https://music.example/sub", username: "api", password: "pw"), coverArtSalt: "salt"
        )
        guard case .ready(let api) = HubConnector().connection(client: client, offline: false, profile: UUID()) else {
            Issue.record("no client")
            return
        }
        #expect((api as? HubClient)?.baseURL.absoluteString == "https://music.example/sub")
        #expect(AppKey.keychainName(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
            == "device.00000000-0000-0000-0000-000000000001")
    }

    @Test func aProfilesKeyIdGoesWithIt() {
        let store = InMemorySecretStore()
        let id = UUID()
        store.write("key", for: AppKey.keychainName(id))
        store.write("pw", for: "profile.\(id.uuidString)")
        AppKey.forget(profileID: id, in: store)
        #expect(store.values == ["profile.\(id.uuidString)": "pw"])
    }

    // MARK: The re-check's fixes (2026-11-15)

    /// Edit Server on the active profile kept the old account's tab and its signed login.
    @Test func anotherLoginIsAnotherAccount() async throws {
        func identity(_ username: String, _ password: String, base: String? = nil) throws -> HubIdentity {
            let config = ServerConfig(serverURL: "https://music.example", homeNetworkURL: "http://home.example:4533", username: username, password: password)
            return HubIdentity(try SubsonicClient(config: config, baseURL: base.flatMap(URL.init(string:)), coverArtSalt: "salt"))
        }
        let first = try identity("api", "pw")
        #expect(first == (try identity("api", "pw")))
        #expect(first.account != (try identity("other", "pw")).account)
        #expect(first.account != (try identity("api", "new")).account)
        let home = try identity("api", "pw", base: "http://home.example:4533")
        #expect(home != first && home.account == first.account, "the home address is the same account")

        let fake = FakeHub(.shown(root()))
        let (model, _) = model(fake)
        model.use(account: first.account)
        await model.probe()
        model.use(account: home.account)
        #expect(model.isShown, "another address of the same account keeps the tab")
        model.use(account: nil)
        #expect(model.isShown, "offline changes nothing")
        model.use(account: (try identity("other", "pw")).account)
        #expect(!model.isShown && model.root == nil, "nothing of the old account stays")
    }

    @Test func aRootScreenWithoutATabKeepsTheProbes() async {
        let fake = FakeHub(.shown(root(title: "Tab")))
        let (model, _) = model(fake)
        await model.probe()
        await fake.set(reply: .success(HubReply(present: .replace, screen: HubScreen(id: "main", title: "Next"))))
        await model.post(HubAction(id: "check"), from: model.root!)
        #expect(model.root?.screen.title == "Next")
        #expect(model.isShown && model.tab?.title == "Tab")
    }

    @Test func aSlowProbeDoesntOverwriteANewerReply() async throws {
        let fake = FakeHub(.shown(root()))
        let (model, _) = model(fake)
        await model.probe()
        await fake.set(probe: .shown(root(title: "Probe")), delay: .milliseconds(200))
        let probing = Task { await model.probe() }
        try await Task.sleep(for: .milliseconds(50))
        await fake.set(reply: .success(HubReply(present: .replace, screen: root(title: "Reply"))))
        await model.post(HubAction(id: "check"), from: model.root!)
        await probing.value
        #expect(model.root?.screen.title == "Reply", "the probe was asked before the reply")
    }

    @Test func searchShowsOnlyTheAnswerToTheQueryTypedNow() async throws {
        let fake = FakeHub(.shown(root()))
        let (model, _) = model(fake)
        await model.probe()
        let section = HubScreen(id: "search", sections: [HubSection(id: "find", title: "From", card: .none, parts: [])])
        await fake.set(reply: .success(HubReply(present: .replace, screen: section)))
        await model.searchAfterPause("radiohead", delay: .zero)
        #expect(model.searchSection != nil)
        let typing = Task { await model.searchAfterPause("radiohead live", delay: .milliseconds(200)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.search != nil && model.searchSection == nil, "the older answer isn't shown under the newer text")
        await typing.value
        #expect(model.searchSection != nil)
        await fake.set(reply: .success(HubReply(present: .none)))
        await model.searchAfterPause("radiohead live!", delay: .zero)
        #expect(model.searchSection == nil, "a reply that didn't replace it isn't this query's")
    }

    @Test func searchsRefreshSendsTheQueryAgain() async throws {
        let fake = FakeHub(.shown(root()))
        let (model, _) = model(fake)
        await model.probe()
        let section = HubScreen(id: "search", refresh: 5, sections: [HubSection(id: "find", title: "From", card: .none, parts: [])])
        await fake.set(reply: .success(HubReply(present: .replace, screen: section)))
        await model.searchAfterPause("radiohead", delay: .zero)
        let page = try #require(model.searchSection)
        let later = HubScreen(id: "search", sections: [HubSection(id: "later", title: "From", card: .none, parts: [])])
        await fake.set(reply: .success(HubReply(present: .replace, screen: later, toast: "Again")))
        #expect(await model.refresh(page))
        #expect(await fake.sent.last == HubRequest(screen: "search", action: "search", values: ["q": "radiohead"]))
        #expect(await fake.fetched.isEmpty, "not fetched by its id, which carries no query")
        #expect(model.searchSection?.screen.sections.first?.id == "later")
    }

    // MARK: The audit's fixes (2026-11-15b)

    /// T5: the sheet that opened this one is gone (nothing holds it), and the dismiss didn't close it.
    @Test func aDismissFromASheetOpenedByASheetClosesIt() async throws {
        let fake = FakeHub(.shown(root(title: "Root")))
        let (model, _) = model(fake)
        await model.probe()
        await fake.set(reply: .success(HubReply(present: .sheet, screen: HubScreen(id: "first", sections: []))))
        await model.post(HubAction(id: "open"), from: model.root!)
        await fake.set(reply: .success(HubReply(present: .sheet, screen: HubScreen(id: "second", sections: []))))
        await model.post(HubAction(id: "more"), from: model.sheet!)
        #expect(model.sheet?.screen.id == "second")
        await fake.set(reply: .success(HubReply(present: .dismiss, screen: root(title: "Elsewhere"))))
        await model.post(HubAction(id: "done"), from: model.sheet!)
        #expect(model.sheet == nil)
        #expect(model.root?.screen.title == "Root", "the screen was for the sheet under it, which is gone")
    }

    /// Search entered again asked the server again for the query its section already answers.
    @Test func searchIsntAskedAgainForTheQueryItShows() async throws {
        let fake = FakeHub(.shown(root()))
        let (model, _) = model(fake)
        await model.probe()
        let section = HubScreen(id: "search", refresh: 5, sections: [HubSection(id: "find", title: "From", card: .none, parts: [])])
        await fake.set(reply: .success(HubReply(present: .replace, screen: section)))
        await model.searchAfterPause("radiohead", delay: .zero)
        await model.searchAfterPause("radiohead", delay: .zero)
        #expect(await fake.sent.count == 1)
        #expect(model.searchSection != nil)
        let page = try #require(model.searchSection)
        #expect(await model.refresh(page), "the screen's own refresh still asks")
        #expect(await fake.sent.count == 2)
        await model.searchAfterPause("radiohead live", delay: .zero)
        #expect(await fake.sent.count == 3, "another query asks")
    }

    /// A key made whose attestation didn't get through was thrown away, and a new one made next time.
    @Test func aKeyWhoseAttestationDidntGetThroughIsKept() async throws {
        let store = InMemorySecretStore()
        let attest = FakeAttest()
        let profile = UUID()
        let key = AppKey(profileID: profile, service: { attest }, store: { store })
        attest.next = .serverUnavailable
        await #expect(throws: DCError.self) { try await key.attestNewKey(clientDataHash: Data()) }
        #expect(await key.currentKeyID() == nil)
        attest.next = nil
        let made = try await key.attestNewKey(clientDataHash: Data())
        #expect(made.keyID == "key-1" && attest.generated == 1, "the same key, attested on the next try")
        #expect(await key.currentKeyID() == "key-1")
        #expect(store.values.keys.sorted() == [AppKey.keychainName(profile)])

        attest.next = .invalidKey
        await #expect(throws: DCError.self) { try await key.attestNewKey(clientDataHash: Data()) }
        attest.next = nil
        #expect(try await key.attestNewKey(clientDataHash: Data()).keyID == "key-3", "Apple's refusal lets the key go")
        #expect(attest.generated == 3)
    }

    @Test func theTabsSymbolFallsBack() {
        #expect(HubSymbol.resolve("dot.radiowaves.left.and.right") == "dot.radiowaves.left.and.right")
        #expect(HubSymbol.resolve("no.such.symbol") == "circle.grid.2x2")
    }

    @Test func theBackdropTurnsTheHueInHSL() {
        let (h, s, l) = UIColor.hsl(r: 1, g: 0, b: 0)
        #expect(h == 0 && s == 1 && l == 0.5)
        let (r, g, b) = UIColor.rgb(h: 120, s: 1, l: 0.5)
        #expect(r == 0 && g == 1 && b == 0)
        let shifted = UIColor(red: 1, green: 0, blue: 0, alpha: 1).shiftingHSLHue(by: -120)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        shifted.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #expect(abs(blue - 1) < 0.001 && red < 0.001 && green < 0.001)
    }
}

@MainActor
private final class ToastBox {
    var texts: [String] = []
}

/// A stand-in for Apple's App Attest: keys numbered as made; `next` fails the next attestation.
nonisolated private final class FakeAttest: AttestService, @unchecked Sendable {
    private let lock = NSLock()
    private var made = 0
    private var failure: DCError.Code?

    nonisolated var next: DCError.Code? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }
    nonisolated var generated: Int { lock.withLock { made } }
    nonisolated var isSupported: Bool { true }

    nonisolated func generateKey() async throws -> String {
        lock.withLock {
            made += 1
            return "key-\(made)"
        }
    }

    nonisolated func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        if let code = lock.withLock({ failure.take() }) { throw DCError(code) }
        return Data("ATT".utf8)
    }

    nonisolated func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        Data("ASR".utf8)
    }
}

/// Records every host asked, answering none: for checking that nothing is sent.
private final class Recorder: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var asked: [String] = []
    private static let lock = NSLock()

    nonisolated static var hosts: [String] { lock.withLock { asked } }

    nonisolated static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Recorder.self]
        return HubClient.makeSession(configuration)
    }

    nonisolated override class func canInit(with request: URLRequest) -> Bool { true }
    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    nonisolated override func startLoading() {
        Self.lock.withLock { Self.asked.append(request.url?.host() ?? "") }
        client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
    }

    nonisolated override func stopLoading() {}
}
