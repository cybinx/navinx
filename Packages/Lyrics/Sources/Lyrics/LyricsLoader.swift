import Foundation
import SubsonicKit

/// Finds a song's lyrics: a downloaded song's saved lyrics, then the server's structured lyrics,
/// then its plain lyrics. Nothing is looked up anywhere but the user's own server (D199).
///
/// A fix from Flutter's `_fetchLyrics` (D40): Navidrome answers a song with no lyrics with an empty
/// `lyricsList`, which Flutter takes as an answer, so it never reaches the other two.
public struct LyricsLoader: Sendable {
    private let client: SubsonicClient?
    private let saved: (@Sendable (String) async -> [LyricLine]?)?

    /// - Parameters:
    ///   - client: nil offline, when only `saved` is asked (Flutter: offline, nothing else).
    ///   - saved: a downloaded song's lyrics, saved with it (C10). Empty saved lyrics go on to the server.
    public init(
        client: SubsonicClient?,
        saved: (@Sendable (String) async -> [LyricLine]?)? = nil
    ) {
        self.client = client
        self.saved = saved
    }

    /// The song's lines, or none. A failure at one step moves on to the next, so an error ends up
    /// as "No lyrics available", as in Flutter.
    public func lines(songID: String, artist: String?, title: String) async -> [LyricLine] {
        if let local = await saved?(songID), !local.isEmpty { return local }
        guard let client, !Task.isCancelled else { return [] }
        return await remoteLines(client: client, songID: songID, artist: artist, title: title)
    }

    /// The chain without the saved step: what a download saves.
    public func remoteLines(client: SubsonicClient, songID: String, artist: String?, title: String) async -> [LyricLine] {
        // Navidrome may send several entries (synced and plain, other languages): the first synced
        // one that has lines, else the first with lines.
        let entries = (try? await client.lyricsBySongID(songID)) ?? []
        let found = entries.map { (synced: $0.synced, lines: LyricLine.lines(from: $0)) }.filter { !$0.lines.isEmpty }
        if let best = found.first(where: { $0.synced }) ?? found.first { return best.lines }
        if Task.isCancelled { return [] }
        guard let plain = try? await client.lyrics(artist: artist, title: title) else { return [] }
        return TimedLyricsReader.parse(plain.value)
    }
}
