import Foundation

// Writes the models in the server's own JSON shape, so the decoders read them back. The app uses
// this to save the library between launches.

private extension KeyedEncodingContainer where K == AnyKey {
    mutating func put<T: Encodable>(_ value: T?, _ key: String) throws {
        if let value { try encode(value, forKey: AnyKey(key)) }
    }

    mutating func putDate(_ value: Date?, _ key: String) throws {
        if let value {
            try encode(value.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)), forKey: AnyKey(key))
        }
    }

    /// The decoders treat `starred` as "has a date".
    mutating func putStarred(_ starred: Bool) throws {
        if starred { try encode("1", forKey: AnyKey("starred")) }
    }

    mutating func putList<T: Encodable>(_ list: [T]?, _ key: String) throws {
        if let list, !list.isEmpty { try encode(list, forKey: AnyKey(key)) }
    }
}

extension ArtistCredit: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.put(id, "id")
        try c.put(name, "name")
        try c.put(coverArt, "coverArt")
    }
}

extension Song: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.put(id, "id")
        try c.put(title, "title")
        try c.put(album, "album")
        try c.put(albumID, "albumId")
        try c.put(artist, "artist")
        try c.put(artistID, "artistId")
        try c.put(track, "track")
        try c.put(discNumber, "discNumber")
        try c.put(year, "year")
        try c.put(genre, "genre")
        try c.put(coverArt, "coverArt")
        try c.put(duration, "duration")
        try c.put(bitRate, "bitRate")
        try c.put(suffix, "suffix")
        try c.put(contentType, "contentType")
        try c.put(size, "size")
        try c.put(path, "path")
        try c.putStarred(starred)
        try c.put(userRating, "userRating")
        if !replayGain.isEmpty {
            var gain = c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("replayGain"))
            try gain.put(replayGain.trackGain, "trackGain")
            try gain.put(replayGain.albumGain, "albumGain")
            try gain.put(replayGain.trackPeak, "trackPeak")
            try gain.put(replayGain.albumPeak, "albumPeak")
        }
        try c.putList(artists, "artists")
        try c.putDate(created, "created")
        try c.put(hasDolbyAtmos, "hasDolbyAtmos")
        try c.put(playCount, "playCount")
        try c.putDate(played, "played")
        try c.put(samplingRate, "samplingRate")
        try c.put(bitDepth, "bitDepth")
        try c.put(channelCount, "channelCount")
    }
}

extension Album: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.put(id, "id")
        try c.put(name, "name")
        try c.put(artist, "artist")
        try c.put(artistID, "artistId")
        try c.put(coverArt, "coverArt")
        try c.put(songCount, "songCount")
        try c.put(duration, "duration")
        try c.put(year, "year")
        try c.put(genre, "genre")
        try c.putDate(created, "created")
        try c.putList(artists, "artists")
        try c.putStarred(starred)
        try c.putList(songs, "song")
    }
}

extension Artist: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.put(id, "id")
        try c.put(name, "name")
        try c.put(coverArt, "coverArt")
        try c.put(albumCount, "albumCount")
        try c.put(artistImageURL, "artistImageUrl")
        try c.putList(artists, "artists")
        try c.putList(albums, "album")
    }
}

extension Playlist: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.put(id, "id")
        try c.put(name, "name")
        try c.put(comment, "comment")
        try c.put(owner, "owner")
        try c.put(isPublic, "public")
        try c.put(songCount, "songCount")
        try c.put(duration, "duration")
        try c.putDate(created, "created")
        try c.putDate(changed, "changed")
        try c.put(coverArt, "coverArt")
        try c.put(songs, "entry")
    }
}
