import DeviceCheck
import DeviceIdentity
import Foundation
import SubsonicKit
import UIKit

/// What `AccountModel` needs for a server that approves each device (C45): the enrolment routes for a
/// login, the keys, the records, the provider every connection asks, and what the device says about
/// itself. The app uses `live`; tests give stand-ins; nil (the default) never asks a server at all.
struct DeviceServices {
    /// The routes at the login's **main** address, or nil where the login can't go there (legacy
    /// authentication sends the password itself, so no signed login is made for it; a plain-http main
    /// address would send the code and the login in clear, C49). `AccountModel` asks only for https.
    var api: (ServerConfig) -> (any EnrollAPI)?
    var keys: any DeviceKeyStore
    var records: DeviceRecords
    var certificates: DeviceCertificates?
    var device: DeviceDescription
    /// The device name field's first value: the model ("iPhone"); iOS no longer gives apps the name.
    var deviceName: String
    var attesting: (any EnrolmentAttesting)?

    @MainActor static var live: DeviceServices {
        DeviceServices(
            api: { config in
                guard let main = URL(string: config.normalizedURL), main.scheme?.lowercased() == "https",
                      let client = try? SubsonicClient(config: config, baseURL: main, coverArtSalt: ""),
                      let login = client.signedLoginQuery(for: main) else { return nil }
                return EnrollClient(baseURL: main, login: login)
            },
            keys: KeychainDeviceKeys(),
            records: DeviceRecords(),
            certificates: .shared,
            device: DeviceDescription(model: machineModel, system: "iOS \(UIDevice.current.systemVersion)", app: appVersion),
            deviceName: UIDevice.current.model,
            attesting: EnrolmentAttest()
        )
    }

    /// The hardware's model identifier (`iPhone18,1`); on the simulator, the one it stands in for.
    static var machineModel: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// `1.0 (12)`: the version and the build.
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// App Attest at enrolment, when the add-on asks (`hello`'s `attest`): a key of its own, attested once
/// for the application's hash and not kept (the sessions' key, `AppKey`, is untouched). Anything failing
/// (the simulator, a build without the entitlement, Apple's service) sends nulls, and the add-on decides.
nonisolated struct EnrolmentAttest: EnrolmentAttesting {
    func attest(clientDataHash: Data) async -> (keyID: String, attestation: Data)? {
        let service = DCAppAttestService.shared
        guard service.isSupported, let id = try? await service.generateKey(),
              let attestation = try? await service.attestKey(id, clientDataHash: clientDataHash) else { return nil }
        return (id, attestation)
    }
}
