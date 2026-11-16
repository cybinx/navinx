import DeviceIdentity
import Foundation
import SubsonicKit
import Testing
@testable import Navinx

/// C44 and C45 together, the join's check: the app's own enrolment code against the add-on's dev front
/// (`Server/panel/dev/front.py --devices optional --tls-port …`), with a real key in the Keychain and a
/// real certificate presented to the front's stand-in for the gateway. It runs only when
/// `NAVINX_DEVICES_LIVE` names a JSON file `{"main": "https://<loopback>:<tls port>", "login":
/// "<login.json>", "code": "XXXXXXXX", "words": "<a file the device's four words are written to>"}`;
/// `docs/log/C45.md`, "The join's check", has the commands that start the front, make the invite and
/// approve the request. On the music server it only pings.
@MainActor @Suite(.serialized) struct DeviceApprovalLiveTests {
    struct Setup: Decodable, Sendable {
        var main: String
        var login: String
        var code: String
        var words: String
    }

    struct Login: Decodable {
        var username: String
        var password: String
    }

    nonisolated static let setup: Setup? = {
        guard let path = ProcessInfo.processInfo.environment["NAVINX_DEVICES_LIVE"],
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(Setup.self, from: data)
    }()

    @Test(.enabled(if: setup != nil)) func aDeviceEnrolsIsApprovedAndPresentsItsCertificate() async throws {
        let setup = try #require(Self.setup)
        let loginData = try #require(FileManager.default.contents(atPath: setup.login))
        let login = try JSONDecoder().decode(Login.self, from: loginData)
        let main = try #require(URL(string: setup.main))
        let client = try SubsonicClient(
            config: ServerConfig(serverURL: setup.main, username: login.username, password: login.password),
            coverArtSalt: "joincheck0000000"
        )
        let signed = try #require(client.signedLoginQuery(for: main))
        let profile = UUID()
        let store = KeychainDeviceKeys()
        let certificates = DeviceCertificates.shared
        defer {
            store.remove(profile: profile)
            DeviceRecords().set(nil, for: profile)
            certificates.use(profile: nil, server: nil)
            certificates.refresh()
        }
        // The certificate is presented only at the address it was issued for (C49), as the flow records it.
        DeviceRecords().set(DeviceRecords.Record(origin: DeviceOrigin(main)?.text), for: profile)
        certificates.use(profile: profile, server: main)
        let enroll = EnrollClient(baseURL: main, login: signed)

        // 1. The server approves devices, this one isn't approved yet, and an invite waits.
        guard case .answer(let hello) = await enroll.hello() else {
            Issue.record("the add-on gave no hello")
            return
        }
        #expect(hello.devices == .optional && !hello.approved && hello.invited)

        // 2. A key made here, and its request filed with the code. The four words go to a file, to be
        //    compared with the ones the add-on shows the owner.
        let key = try store.makeKey(for: profile)
        try key.words.joined(separator: " ").write(toFile: setup.words, atomically: true, encoding: .utf8)
        let application = EnrollApplication(
            code: setup.code, csr: try key.certificateRequest(), deviceID: UUID().uuidString.lowercased(),
            name: "Join check", model: "Simulator", system: "iOS 27.2", app: "1.0 (1)"
        )
        let applied = await enroll.apply(application)
        guard case .filed(let request) = applied else {
            Issue.record("the request was not filed: \(applied)")
            return
        }

        // 3. Waiting, as the waiting screen does, until the owner approves.
        var issued: IssuedCertificate?
        for _ in 0..<90 {
            let status = await enroll.status(request: request) { try key.sign($0) }
            if case .approved(let certificate) = status {
                issued = certificate
                break
            }
            guard status == .pending else {
                Issue.record("waiting ended with \(status)")
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        let certificate = try #require(issued, "never approved")

        // 4. The key and the certificate come back as one identity, and a connection that presents it
        //    is one the add-on knows.
        try store.storeCertificate(certificate.certificate, for: profile)
        certificates.refresh()
        #expect(store.identity(for: profile) != nil)
        guard case .answer(let after) = await enroll.hello() else {
            Issue.record("no hello with the certificate")
            return
        }
        #expect(after.approved)

        // 5. The API's own session reaches the music server through the stand-in gateway, and a renewal
        //    goes through over the certificate.
        _ = try await client.ping()
        let renewal = await enroll.renew(csr: try key.certificateRequest())
        guard case .renewed(let renewed) = renewal else {
            Issue.record("not renewed: \(renewal)")
            return
        }
        #expect(renewed.renewAfter >= certificate.renewAfter)
    }
}
