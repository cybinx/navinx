import Foundation
import Testing
@testable import SubsonicKit

@Suite struct ScanTests {
    private func ok(_ body: String) -> Reply {
        .body(#"{"subsonic-response":{"status":"ok","version":"1.16.1",\#(body)}}"#)
    }

    @Test func readsTheAdminRole() async throws {
        let (admin, transport) = try makeClient(["getUser": ok(#""user":{"username":"a","adminRole":true}"#)])
        #expect(try await admin.accountInfo().isAdmin)
        #expect(transport.requests[0].params["username"] == testConfig.username)
        let (plain, _) = try makeClient(["getUser": ok(#""user":{"username":"a","adminRole":false}"#)])
        #expect(try await plain.accountInfo().isAdmin == false)
        let (missing, _) = try makeClient(["getUser": ok(#""user":{"username":"a"}"#)])
        #expect(try await missing.accountInfo().isAdmin == false)
    }

    @Test func startScanAndStatusRead() async throws {
        let (client, _) = try makeClient([
            "startScan": ok(#""scanStatus":{"scanning":true,"count":3}"#),
            "getScanStatus": ok(#""scanStatus":{"scanning":false,"count":9}"#),
        ])
        #expect(try await client.startScan() == ScanStatus(isScanning: true, count: 3))
        #expect(try await client.scanStatus() == ScanStatus(isScanning: false, count: 9))
    }

    @Test func scanAndWaitPollsUntilDone() async throws {
        let (client, transport) = try makeClient([
            "startScan": ok(#""scanStatus":{"scanning":true,"count":0}"#),
            "getScanStatus": ok(#""scanStatus":{"scanning":false,"count":4}"#),
        ])
        let finished = try await client.scanAndWait(interval: .milliseconds(1), limit: .seconds(5))
        #expect(finished)
        #expect(transport.requests.map(\.lastPathComponent) == ["startScan", "getScanStatus"])
    }

    @Test func scanAndWaitGivesUpAtTheLimit() async throws {
        let (client, _) = try makeClient([
            "startScan": ok(#""scanStatus":{"scanning":true}"#),
            "getScanStatus": ok(#""scanStatus":{"scanning":true}"#),
        ])
        #expect(try await client.scanAndWait(interval: .milliseconds(1), limit: .milliseconds(20)) == false)
    }

    @Test func aRefusedScanThrows() async throws {
        let (client, _) = try makeClient([
            "startScan": .body(#"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":50,"message":"not authorized"}}}"#),
        ])
        await #expect(throws: SubsonicError.self) { try await client.startScan() }
    }
}
