import Foundation

/// A page to show, asked from outside the views: Spotlight, Siri and Shortcuts, the icon's quick
/// actions, `navinx://` links and the widgets (C39, C40). Never the server's tab.
public enum AppDestination: Hashable, Sendable {
    case album(id: String)
    case artist(id: String)
    case playlist(id: String)
    /// The Search tab, with the text to search for when there's one.
    case search(String?)
    case favorites
    case downloads
}

/// The app's links: `navinx://album/<id>`, `artist/<id>`, `playlist/<id>`, `search` (`?q=` the text),
/// `favorites`, `downloads`. Any app or page can open one, so a link only ever opens a page.
public enum NavinxLink {
    public static let scheme = "navinx"

    public static func destination(from url: URL) -> AppDestination? {
        guard url.scheme?.lowercased() == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // `navinx://album/1` has the kind as its host; `navinx:album/1` as the path's first part.
        var parts = components.path.split(separator: "/").map(String.init)
        if let host = components.host, !host.isEmpty { parts.insert(host, at: 0) }
        guard let kind = parts.first?.lowercased() else { return nil }
        let id = parts.count == 2 ? parts[1] : nil
        switch (kind, id) {
        case ("album", let id?) where !id.isEmpty: return .album(id: id)
        case ("artist", let id?) where !id.isEmpty: return .artist(id: id)
        case ("playlist", let id?) where !id.isEmpty: return .playlist(id: id)
        case ("search", nil):
            let text = components.queryItems?.first { $0.name == "q" }?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .search(text?.isEmpty == false ? text : nil)
        case ("favorites", nil): return .favorites
        case ("downloads", nil): return .downloads
        default: return nil
        }
    }

    public static func url(for destination: AppDestination) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        switch destination {
        case .album(let id): components.host = "album"; components.path = "/" + id
        case .artist(let id): components.host = "artist"; components.path = "/" + id
        case .playlist(let id): components.host = "playlist"; components.path = "/" + id
        case .search(let text):
            components.host = "search"
            if let text { components.queryItems = [URLQueryItem(name: "q", value: text)] }
        case .favorites: components.host = "favorites"
        case .downloads: components.host = "downloads"
        }
        return components.url ?? URL(string: "\(scheme)://")!
    }
}
