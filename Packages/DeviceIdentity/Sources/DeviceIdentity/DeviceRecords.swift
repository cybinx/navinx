import Foundation

/// What the app keeps about each profile's enrolment, beside the key and certificate in the Keychain: the
/// request waiting for the owner, when to renew, the issuer to send with the certificate. Nothing here is
/// secret (a request is useless without the key), so it's settings (`UserDefaults`), under keys of its own
/// that no earlier build wrote.
public struct DeviceRecords: @unchecked Sendable {
    public struct Record: Codable, Equatable, Sendable {
        /// The request filed and not yet answered.
        public var request: String?
        /// When the certificate should be renewed (unix seconds).
        public var renewAfter: Double?
        /// The issuer's certificate (DER), sent after the device's own.
        public var issuer: Data?
        /// The main address (`DeviceOrigin.text`) the request was filed at and the certificate issued
        /// for (C49). The key and certificate are presented there only, and only an answer from there may
        /// remove them. Missing in records kept before C49: the app takes such a record to be for the
        /// profile's main address as saved, the first time it sees it (`AccountModel`).
        public var origin: String?

        public init(request: String? = nil, renewAfter: Double? = nil, issuer: Data? = nil, origin: String? = nil) {
            self.request = request
            self.renewAfter = renewAfter
            self.issuer = issuer
            self.origin = origin
        }

        /// Whether the record is for `origin` (a record with no origin is for none).
        public func belongs(to origin: DeviceOrigin?) -> Bool {
            guard let origin, let kept = self.origin else { return false }
            return kept == origin.text
        }

        private enum CodingKeys: String, CodingKey {
            case request = "request"
            case renewAfter = "renewAfter"
            case issuer = "issuer"
            case origin = "origin"
        }
    }

    static let recordsKey = "device_enrolments"
    static let installKey = "device_install_id"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// One id per install (the protocol's `device.id`), made the first time it's asked for.
    public var installID: String {
        if let id = defaults.string(forKey: Self.installKey), !id.isEmpty { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: Self.installKey)
        return id
    }

    public func record(for profile: UUID) -> Record {
        all()[profile.uuidString] ?? Record()
    }

    public func set(_ record: Record?, for profile: UUID) {
        var list = all()
        list[profile.uuidString] = (record == Record()) ? nil : record
        defaults.set(try? JSONEncoder().encode(list), forKey: Self.recordsKey)
    }

    private func all() -> [String: Record] {
        guard let data = defaults.data(forKey: Self.recordsKey),
              let list = try? JSONDecoder().decode([String: Record].self, from: data) else { return [:] }
        return list
    }
}

/// A server's main address as far as a TLS connection goes (C49): https, the host lower-cased, the port
/// (443 when none is given). Enrolment happens only over https, so there is no other scheme.
public struct DeviceOrigin: Hashable, Sendable {
    public let host: String
    public let port: Int

    /// Nil unless `url` is https with a host.
    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        self.init(host: host, port: url.port ?? 443)
    }

    public init(host: String, port: Int) {
        self.host = host.lowercased()
        self.port = port
    }

    /// How a record keeps it: `https://host:port`.
    public var text: String { "https://\(host):\(port)" }
}
