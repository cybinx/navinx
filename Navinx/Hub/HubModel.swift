import CryptoKit
import Foundation
import Observation
import HubKit
import SubsonicKit

/// How the hub can be reached right now.
enum HubConnection {
    /// No server client (signed out, connecting, offline): nothing to ask, keep what's shown.
    case offline
    /// The account can't send a signed login (legacy auth, D101): no tab.
    case noLogin
    case ready(any HubAPI)
}

/// A screen the server sent, on show: the tab's root, a pushed page, a sheet or Search's section.
/// It keeps what the person typed across the server's refreshes.
@Observable
final class HubPage: Identifiable {
    let id = UUID()
    private(set) var screen: HubScreen
    /// The text in each field, by field id.
    var texts: [String: String] = [:]
    /// What the server last sent for each field: its `value` replaces the typed text only when it changes.
    @ObservationIgnored private var serverValues: [String: String] = [:]
    /// An option picked but not yet answered, by choice id.
    private(set) var picked: [String: String] = [:]
    /// The control whose action is in flight (a button's id, else its action's id); one at a time.
    fileprivate(set) var sending: String?
    /// Bumped by every post, so a refresh that was on its way when one started is dropped.
    @ObservationIgnored fileprivate var posts = 0
    /// For a sheet's page: the page that opened it, which its dismiss's screen goes back to.
    @ObservationIgnored fileprivate weak var opener: HubPage?
    /// Bumped by every screen shown, whatever brought it, so an answer asked for before it is dropped.
    @ObservationIgnored fileprivate private(set) var applied = 0
    /// For Search's section: the query whose answer it shows.
    fileprivate(set) var query: String?

    init(screen: HubScreen) {
        self.screen = screen
        apply(screen)
    }

    var isSending: Bool { sending != nil }

    /// Shows a new version of the screen, keeping typed text unless the server changed its value.
    /// The fields in `resetting` (the ones a successful action sent) take the server's value either way:
    /// a reply that repeats an empty value is how the server clears a field.
    func apply(_ new: HubScreen, resetting: Set<String> = []) {
        for field in new.fields
        where serverValues[field.id] != field.value || texts[field.id] == nil || resetting.contains(field.id) {
            texts[field.id] = field.value
            serverValues[field.id] = field.value
        }
        picked = [:]
        screen = new
        applied += 1
    }

    func text(_ fieldID: String) -> String { texts[fieldID] ?? "" }

    /// The value a choice shows: the one just picked, else the server's.
    func value(of choice: HubChoice) -> String { picked[choice.id] ?? choice.value }

    func pick(_ option: String, in choice: HubChoice) { picked[choice.id] = option }

    /// Back to the server's value, when the pick wasn't confirmed.
    func unpick(_ choice: HubChoice) { picked[choice.id] = nil }

    /// A button is off while any field it needs is blank.
    func isMissing(_ needs: [String]) -> Bool {
        needs.contains { text($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The values an action sends: the text of each field it names, the value of each choice.
    func values(for action: HubAction) -> [String: String] {
        var values: [String: String] = [:]
        let choices = Dictionary(screen.choices.map { ($0.id, $0) }) { first, _ in first }
        for name in action.sends {
            if let choice = choices[name] {
                values[name] = value(of: choice)
            } else if let text = texts[name] {
                values[name] = text
            }
        }
        return values
    }
}

/// Pushed hub pages and library pages share the hub tab's stack.
enum HubRoute: Hashable {
    case library(LibraryRoute)
    case screen(UUID)
}

/// The server's own tab (C27, D106, D107): whether it shows, and the screens on show in it and in
/// Search. The tab shows only after the server answered the probe with a screen this build can read;
/// nothing about it is kept on the phone, so it's asked again at every launch, on every return to
/// the foreground and when the network comes back.
@Observable
final class HubModel {
    /// The app's own messages, generic on purpose (the server sends every other text).
    static let failedMessage = "Something went wrong."
    static let loadFailedMessage = "Couldn't load."
    /// Search asks the server once the query has sat still this long.
    static let searchDelay: Duration = .milliseconds(700)

    /// The tab's root screen; nil while there's no tab.
    private(set) var root: HubPage?
    /// A sheet's screen.
    var sheet: HubPage?
    /// The hub tab's stack.
    var path: [HubRoute] = []
    /// Search's section, when the server has sent one.
    private(set) var search: HubPage?
    @ObservationIgnored private var pushed: [UUID: HubPage] = [:]

    /// How to reach the server now; set by the tab view from the account.
    @ObservationIgnored var connect: () -> HubConnection = { .offline }
    @ObservationIgnored var onToast: (String) -> Void = { _ in }
    /// Bumped by every probe that asks the server, so a newer one (the address changed) supersedes an older.
    @ObservationIgnored private var probes = 0
    /// The query Search's section is for now; nil while it's too short to ask.
    private var searchQuery: String?
    /// What `sending` holds while Search's own query is on its way.
    private static let searchControl = "hub.search"
    private static let searchAction = HubAction(id: "search")
    /// The tab the last probe gave: a later root screen without one keeps it.
    private var probedTab: HubTab?
    /// The account the screens on show are for (`HubIdentity.account`).
    @ObservationIgnored private var account: Data?

    var tab: HubTab? {
        guard let root else { return nil }
        return root.screen.tab ?? probedTab
    }
    var isShown: Bool { tab != nil }

    /// Search's section as drawn: only while it shows the answer to the query typed now, so an older
    /// query's answer never stands under newer typing.
    var searchSection: HubPage? {
        guard let search, search.query != nil, search.query == searchQuery else { return nil }
        return search
    }

    func page(_ id: UUID) -> HubPage? { pushed[id] }

    /// Who the hub is asked for. Another account (Edit Server changed the server, the username or the
    /// password) clears everything shown, and a probe still on its way for the old one is dropped. No
    /// client (offline) changes nothing.
    func use(account: Data?) {
        guard let account, account != self.account else { return }
        if self.account != nil {
            probes += 1
            clear()
        }
        self.account = account
    }

    // MARK: The probe

    /// Asks the server whether this account has the tab. Shown only for a v1 screen with a tab; any
    /// other answer hides it; no answer at all (or no client, offline) keeps what's shown.
    func probe() async {
        let api: any HubAPI
        switch connect() {
        case .offline: return
        case .noLogin:
            probes += 1
            clear()
            return
        case .ready(let ready): api = ready
        }
        probes += 1
        let mine = probes
        // What the root showed when this was asked: an action's reply since then is newer than this answer.
        let asked = root.map { (page: $0, posts: $0.posts, applied: $0.applied) }
        let outcome = await api.probe()
        // Not the latest probe (the address changed meanwhile), or cancelled: its answer is for something else.
        guard mine == probes, !Task.isCancelled else { return }
        switch outcome {
        case .shown(let screen):
            if let root {
                guard !root.isSending, let asked, asked.page === root, asked.posts == root.posts,
                      asked.applied == root.applied else { return }
                root.apply(screen)
            } else {
                root = HubPage(screen: screen)
            }
            probedTab = screen.tab
        case .absent:
            clear()
        case .unreachable:
            break
        }
    }

    /// No tab, no section, nothing kept.
    func clear() {
        root = nil
        probedTab = nil
        sheet = nil
        search = nil
        pushed = [:]
        path = []
    }

    // MARK: Actions

    /// Posts an action from a page: the reply replaces it, pushes, opens or closes a sheet.
    /// `control` marks what shows the spinner; `adding` adds values (Search's query). Says whether the
    /// server's answer was taken in: false when nothing was sent, the call failed or the answer was dropped.
    @discardableResult
    func post(
        _ action: HubAction, from page: HubPage, control: String? = nil, adding: [String: String] = [:],
        quiet: Bool = false
    ) async -> Bool {
        guard !page.isSending else { return false }
        guard case .ready(let api) = connect() else {
            if !quiet { onToast(Self.failedMessage) }
            return false
        }
        page.sending = control ?? action.id
        page.posts += 1
        let mine = page.posts
        // Only the page's latest post ends the sending: a newer one may be running (Search's).
        defer { if page.posts == mine { page.sending = nil } }
        let request = HubRequest(
            screen: page.screen.id, action: action.id, values: page.values(for: action).merging(adding) { $1 }
        )
        do {
            let reply = try await api.send(request)
            guard !Task.isCancelled, page.posts == mine else { return false }
            apply(reply, from: page, sent: Set(action.sends))
            return true
        } catch {
            if !Task.isCancelled, !quiet { onToast(Self.failedMessage) }
            return false
        }
    }

    /// Picks a choice's option: shown at once, then posted.
    func pick(_ option: String, in choice: HubChoice, on page: HubPage) async {
        guard page.value(of: choice) != option, !page.isSending else { return }
        page.pick(option, in: choice)
        let accepted = await post(choice.action, from: page, control: choice.id, adding: [choice.id: option])
        // A reply that shows a screen has reset the pick; one that changes nothing keeps it (the server
        // accepted it); only a post that failed goes back to the server's value.
        if !accepted { page.unpick(choice) }
    }

    /// Whether a page is on show: the root, a pushed page still on the stack, the sheet or Search's.
    private func isShown(_ page: HubPage) -> Bool {
        page === root || page === sheet || page === search || pushed[page.id] === page
    }

    /// `sent` is the ids of the fields the action sent: a replaced screen resets them (see `HubPage.apply`).
    func apply(_ reply: HubReply, from page: HubPage, sent: Set<String> = []) {
        // The toast answers the person whatever became of the page (a sheet swiped away, a page popped).
        if let toast = reply.toast, !toast.isEmpty { onToast(toast) }
        let shown = isShown(page)
        switch reply.present {
        case .replace:
            if shown, let screen = reply.screen { page.apply(screen, resetting: sent) }
        case .push:
            // Only the hub tab draws a stack, and Search's section lives in the Search tab: a push from
            // there has nowhere to show, so it's dropped (as is one from a page that's gone).
            guard shown, page !== search, let screen = reply.screen else { return }
            let new = HubPage(screen: screen)
            pushed[new.id] = new
            path.append(.screen(new.id))
        case .sheet:
            guard shown, page !== search, let screen = reply.screen else { return }
            let new = HubPage(screen: screen)
            new.opener = page
            sheet = new
        case .dismiss:
            // Closes only the sheet the reply came from, whatever opened it (a sheet opened from another
            // sheet has lost its opener, which nothing shows any more). Its screen goes to the page that
            // opened the sheet, if that page is still on show (a sheet swiped away before the reply still
            // counts); from any other page it goes to that page, if it's on show.
            let closing = page === sheet
            if closing { sheet = nil }
            let under: HubPage?
            if let opener = page.opener {
                under = isShown(opener) ? opener : nil
            } else {
                under = shown && !closing ? page : nil
            }
            if let screen = reply.screen { under?.apply(screen, resetting: under === page ? sent : []) }
        case .none:
            break
        }
    }

    /// Forgets pushed pages that are no longer on the stack.
    func pathChanged() {
        let kept = Set(path.compactMap { if case .screen(let id) = $0 { id } else { nil } })
        pushed = pushed.filter { kept.contains($0.key) }
    }

    // MARK: Refreshing

    /// The screen again from the server (its `refresh`). A failure keeps the screen as it is; so does
    /// an answer that arrives after a post started (the post's reply wins).
    @discardableResult
    func refresh(_ page: HubPage) async -> Bool {
        guard !page.isSending, case .ready(let api) = connect() else { return false }
        if page === search { return await refreshSearch(page, api: api) }
        let posts = page.posts
        guard let screen = try? await api.screen(page.screen.id) else { return false }
        guard posts == page.posts, !page.isSending else { return false }
        page.apply(screen)
        return true
    }

    /// Search's section again: its query is sent again (a screen fetched by its id alone would have
    /// none). Only a screen that replaces the section is taken; a toast or anything else was the first
    /// answer's.
    private func refreshSearch(_ page: HubPage, api: any HubAPI) async -> Bool {
        guard let query = searchQuery, page.query == query else { return false }
        let posts = page.posts
        let request = HubRequest(screen: page.screen.id, action: Self.searchAction.id, values: ["q": query])
        guard let reply = try? await api.send(request) else { return false }
        guard !Task.isCancelled, posts == page.posts, !page.isSending, search === page, searchQuery == query,
              reply.present == .replace, let screen = reply.screen else { return false }
        page.apply(screen)
        return true
    }

    /// Pull to refresh on the tab's root.
    func reload() async {
        guard let root, !root.isSending else { return }
        let posts = root.posts
        // A post that is on its way, or started meanwhile, has its own answer coming: not a failed load.
        if await !refresh(root), !Task.isCancelled, !root.isSending, root.posts == posts {
            onToast(Self.loadFailedMessage)
        }
    }

    // MARK: Search

    /// Search's section (Q2a): for 2 characters or more, after the query settles, the server's section
    /// for it. Nothing is asked without the tab.
    func searchAfterPause(_ raw: String, delay: Duration = HubModel.searchDelay) async {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isShown else { return }
        guard query.count >= 2 else {
            // Too short to ask: the last query's results don't stay under the new text, and a late
            // answer for it finds no page to land on.
            searchQuery = nil
            if search != nil { search = nil }
            return
        }
        // The section shown already answers this query (Search entered again): nothing to ask. A refresh
        // the screen asked for still runs (`refreshSearch`).
        if let search, search.query == query, !search.isSending {
            searchQuery = query
            return
        }
        searchQuery = query
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled, isShown, searchQuery == query else { return }
        let page = search ?? HubPage(screen: HubScreen(id: "search"))
        search = page
        // Another action from this page is on its way: let it end first, so a search doesn't orphan its answer.
        while page.isSending, page.sending != Self.searchControl {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, isShown, searchQuery == query else { return }
        }
        // A search still on its way is for an older query: this one replaces it.
        page.sending = nil
        let shown = page.applied
        let answered = await post(
            Self.searchAction, from: page, control: Self.searchControl, adding: ["q": query], quiet: true
        )
        // The section is this query's only once a reply has replaced it.
        if answered, page.applied != shown { page.query = query }
        // No answer: the older query's results don't stay under the new text.
        if !answered, !Task.isCancelled, searchQuery == query, search === page { search = nil }
    }
}

/// Whom the hub is asked for: the address in use, and the account signed in there as a digest of its
/// server's addresses, its username and its password. The digest is held in memory only, so a changed
/// login is told apart without the password being kept anywhere new.
struct HubIdentity: Hashable {
    let base: URL
    let account: Data

    init(_ client: SubsonicClient) {
        base = client.baseURL
        let config = client.config
        let parts = [config.normalizedURL, config.normalizedHomeNetworkURL ?? "", config.username, config.password]
        account = Data(SHA256.hash(data: Data(parts.joined(separator: "\u{0}").utf8)))
    }
}

/// The hub's client for the account in use, signed with its session (`HubSessions`, shared with the
/// levels). The signed login goes only to sign in, or on each call where the server has no sessions;
/// one is kept a few minutes per address and account: the server checks each new one with the music
/// server, so a screen refreshing every second doesn't cost a check every second.
final class HubConnector {
    static let reuse: TimeInterval = 240
    private let sessions: HubSessions
    private var kept: (identity: HubIdentity, login: String, made: Date)?

    init(sessions: HubSessions = .shared) {
        self.sessions = sessions
    }

    /// `profile` is the signed-in profile's id, whose key proves the sign-in comes from the app.
    func connection(client: SubsonicClient?, offline: Bool, profile: UUID? = nil, now: Date = .now) -> HubConnection {
        guard let client, !offline else { return .offline }
        let base = client.baseURL
        let identity = HubIdentity(client)
        let login: String
        if let kept, kept.identity == identity, now.timeIntervalSince(kept.made) < Self.reuse {
            login = kept.login
        } else {
            guard let fresh = client.signedLoginQuery(for: HubClient.rootURL(base: base)) else {
                kept = nil
                return .noLogin
            }
            kept = (identity, fresh, now)
            login = fresh
        }
        // The login's digest makes a changed password another session.
        let account = HubAccount(
            baseURL: base, username: client.config.username, login: login, loginDigest: identity.account,
            keys: AppKey.provider(for: profile)
        )
        return .ready(HubClient(account: account, sessions: sessions))
    }
}
