import Foundation
import SubsonicKit

/// One section's data (Flutter `NewSectionState`). A reload keeps what's showing until new data
/// arrives, so a pull to refresh doesn't flash the placeholders; only the error state goes back to them.
/// A reload that fails keeps what's showing too (Flutter showed the error instead): the error shows
/// only when there is nothing loaded.
@Observable
final class SectionLoad<Value: Sendable> {
    enum Phase {
        case placeholder, content(Value), failed
    }

    private(set) var data: Value?
    private var hasError = false
    private var isLoading = true
    private var generation = 0

    private let timeout: Duration
    private let fetch: @Sendable (SubsonicClient) async throws -> Value

    init(timeout: Duration = .seconds(30), fetch: @escaping @Sendable (SubsonicClient) async throws -> Value) {
        self.timeout = timeout
        self.fetch = fetch
    }

    var phase: Phase {
        if let data { return .content(data) }
        return isLoading ? .placeholder : .failed
    }

    /// Safe to call during a fetch: only the latest result is kept. True when this reload failed while
    /// data was shown, which stays (so the page can say the reload failed: nothing on it changes).
    @discardableResult
    func load(client: SubsonicClient?) async -> Bool {
        generation += 1
        let current = generation
        if hasError {
            hasError = false
            isLoading = true
        }
        var keptAfterFailure = false
        do {
            guard let client else { throw SubsonicError.network }
            let fetch = fetch
            // Flutter's limit covers the whole section, however many requests it makes.
            let value = try await withTimeout(timeout) { try await fetch(client) }
            guard current == generation else { return false }
            data = value
            hasError = false
        } catch {
            guard current == generation else { return false }
            hasError = true
            keptAfterFailure = data != nil
        }
        isLoading = false
        return keptAfterFailure
    }
}

/// The New tab's five sections. Each loads on its own, so one failing leaves the others alone.
@Observable
final class NewModel {
    let hero = SectionLoad(fetch: NewFeed.hero)
    let fresh = SectionLoad(fetch: NewFeed.artistNewArrivals)
    let rediscover = SectionLoad(fetch: NewFeed.rediscover)
    let latestAdditions = SectionLoad(fetch: NewFeed.latestAdditions)
    let mix = SectionLoad(fetch: NewFeed.mix)

    private var hasStarted = false

    /// The first time the tab shows with a server. Coming back to the tab keeps what's there, as in
    /// Flutter. With no client (offline mode) it waits, so the load happens once a server is there.
    func start(client: SubsonicClient?) {
        guard !hasStarted, client != nil else { return }
        hasStarted = true
        Task { await refresh(client: client) }
    }

    /// What a refresh that failed left as it was: whether an albums section (the first four) and the
    /// songs section (the mix) failed with data shown.
    struct KeptAfterFailure: Equatable {
        var albums = false
        var songs = false
    }

    /// Reloads every section, and finishes when all have, whether they worked or not.
    @discardableResult
    func refresh(client: SubsonicClient?) async -> KeptAfterFailure {
        async let hero = self.hero.load(client: client)
        async let fresh = self.fresh.load(client: client)
        async let rediscover = self.rediscover.load(client: client)
        async let latestAdditions = self.latestAdditions.load(client: client)
        async let mix = self.mix.load(client: client)
        let albums = await [hero, fresh, rediscover, latestAdditions]
        return KeptAfterFailure(albums: albums.contains(true), songs: await mix)
    }
}
