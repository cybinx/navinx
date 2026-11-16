import Foundation

/// Where a library scan stands (`getScanStatus`, `startScan`).
public struct ScanStatus: Sendable, Hashable, Decodable {
    public var isScanning: Bool
    public var count: Int

    public init(isScanning: Bool, count: Int = 0) {
        self.isScanning = isScanning
        self.count = count
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        isScanning = c.bool("scanning") ?? false
        count = c.int("count") ?? 0
    }
}

/// The account's own record (`getUser`); only the role Search needs.
public struct AccountInfo: Sendable, Hashable, Decodable {
    public var username: String
    /// Navidrome only lets an administrator start a scan.
    public var isAdmin: Bool

    public init(username: String, isAdmin: Bool) {
        self.username = username
        self.isAdmin = isAdmin
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        username = c.string("username") ?? ""
        isAdmin = c.bool("adminRole") ?? false
    }
}

extension SubsonicClient {
    /// `getUser` for the signed-in account.
    public func accountInfo() async throws -> AccountInfo {
        try await payload("getUser", [("username", config.username)], key: "user")
    }

    /// `startScan`: asks the server to scan its library (administrators only).
    @discardableResult
    public func startScan() async throws -> ScanStatus {
        try await payload("startScan", key: "scanStatus")
    }

    /// `getScanStatus`.
    public func scanStatus() async throws -> ScanStatus {
        try await payload("getScanStatus", key: "scanStatus")
    }

    /// Starts a scan and waits for it to end (polling every `interval`, up to `limit`), so the
    /// caller can search again. Returns false if it was still running when time ran out.
    public func scanAndWait(
        interval: Duration = .seconds(2),
        limit: Duration = .seconds(120)
    ) async throws -> Bool {
        var status = try await startScan()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while status.isScanning {
            if clock.now >= deadline { return false }
            try await Task.sleep(for: interval)
            status = try await scanStatus()
        }
        return true
    }
}
