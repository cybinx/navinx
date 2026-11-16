import Foundation
import Observation

/// What the device says about itself when it applies (`device` in the request).
public struct DeviceDescription: Sendable, Equatable {
    public var model: String
    public var system: String
    public var app: String

    public init(model: String, system: String, app: String) {
        self.model = model
        self.system = system
        self.app = app
    }
}

/// Apple's proof that the key was made by the genuine app (App Attest), when the add-on asks for it.
/// Any failure (the simulator, no entitlement, Apple's service) is nil, and the request carries nulls.
public protocol EnrolmentAttesting: Sendable {
    func attest(clientDataHash: Data) async -> (keyID: String, attestation: Data)?
}

/// One device's way through a server that approves each device (C45): the code from the invite, the
/// key and its request, the waiting screen with the four words, and the certificate once the owner
/// approves. The screens show `step` and `notice`; the app decides when to start it and what follows.
@MainActor @Observable
public final class DeviceEnrolment: Identifiable {
    public enum Step: Equatable, Sendable {
        /// Asking the server.
        case checking
        /// No invite waits for this username.
        case noInvite
        /// An invite waits: the code it sent, to this masked address.
        case enterCode(sentTo: String?)
        /// The application is on its way.
        case sending
        /// Filed, waiting for the owner; these are the words to read out.
        case waiting(words: [String])
        /// The owner said no.
        case denied
        /// The invite is used up or ran out.
        case expired
        /// The server didn't answer.
        case unreachable
        /// Approved: the certificate is stored.
        case approved
    }

    /// A note under the code field.
    public enum Notice: Equatable, Sendable {
        case wrongCode(triesLeft: Int?)
        case wrongPlace
        case notAccepted
        case unreachable
    }

    public let id = UUID()
    public let profile: UUID
    /// The main address this flow runs at: the request and the certificate are recorded for it (C49).
    public let origin: DeviceOrigin
    /// The server's rule: at `optional` the app works without a certificate, so the person may skip.
    public private(set) var rule: DeviceRule
    public private(set) var step: Step = .checking
    public private(set) var notice: Notice?
    public var code = ""
    public var deviceName: String

    /// How long the waiting screen waits between asks.
    public static let pollInterval: Duration = .seconds(5)

    private let username: String
    private var hello: EnrollHello
    private let api: any EnrollAPI
    private let keys: any DeviceKeyStore
    private let records: DeviceRecords
    private let certificates: DeviceCertificates?
    private let device: DeviceDescription
    private let attesting: (any EnrolmentAttesting)?
    @ObservationIgnored private var polling = false
    /// Called once, when the certificate is stored.
    @ObservationIgnored public var onApproved: @MainActor () -> Void = {}
    /// Called when a request is filed (the app keeps the login, so the request can be found again).
    @ObservationIgnored public var onFiled: @MainActor () -> Void = {}

    public init(
        profile: UUID, origin: DeviceOrigin, username: String, hello: EnrollHello, api: any EnrollAPI,
        keys: any DeviceKeyStore, records: DeviceRecords, certificates: DeviceCertificates?,
        device: DeviceDescription, deviceName: String, attesting: (any EnrolmentAttesting)? = nil
    ) {
        self.profile = profile
        self.origin = origin
        self.username = username
        self.hello = hello
        rule = hello.devices
        self.api = api
        self.keys = keys
        self.records = records
        self.certificates = certificates
        self.device = device
        self.deviceName = deviceName
        self.attesting = attesting
        step = Self.firstStep(hello: hello, pending: pendingKey)
    }

    /// A request filed earlier (the screen was left, the app closed) is waited on again; else the invite.
    static func firstStep(hello: EnrollHello, pending key: (any DeviceKey)?) -> Step {
        if let key { return .waiting(words: key.words) }
        return hello.invited ? .enterCode(sentTo: hello.to) : .noInvite
    }

    /// The code as typed, with anything but letters and digits dropped and upper-cased (`abcd-2345`).
    public var normalizedCode: String {
        String(code.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

    /// The protocol's codes are 8 characters.
    public var canSend: Bool { normalizedCode.count == 8 && !deviceName.trimmingCharacters(in: .whitespaces).isEmpty }

    // MARK: Asking the server again

    /// "Check Again" on the no-invite and unreachable screens: hello once more.
    public func checkAgain() async {
        step = .checking
        notice = nil
        switch await api.hello() {
        case .answer(let fresh):
            hello = fresh
            rule = fresh.devices
            if fresh.approved || fresh.devices == .off {
                // Approved elsewhere (a certificate this device already holds), or the server stopped asking.
                step = .approved
                onApproved()
                return
            }
            step = Self.firstStep(hello: fresh, pending: pendingKey)
        case .notOffered:
            step = .approved
            onApproved()
        case .unreachable:
            step = .unreachable
        }
    }

    /// The key of a request filed at this flow's address and not yet answered.
    private var pendingKey: (any DeviceKey)? {
        let record = records.record(for: profile)
        return record.request != nil && record.belongs(to: origin) ? keys.key(for: profile) : nil
    }

    /// The profile holds a certificate or a waiting request for another address (C49): this flow must not
    /// replace that key or record. The app never starts a flow then; this is the flow's own guard.
    private var holdsElsewhere: Bool {
        let record = records.record(for: profile)
        return !record.belongs(to: origin) && (record.request != nil || keys.hasCertificate(for: profile))
    }

    // MARK: Applying

    /// Sends the code with a key made here and the device's details.
    public func send() async {
        guard canSend, case .enterCode(let sentTo) = step else { return }
        let code = normalizedCode
        guard !holdsElsewhere else {
            notice = .notAccepted
            return
        }
        step = .sending
        notice = nil
        let key: any DeviceKey
        do {
            // A key with no certificate (an earlier wrong code) is used again; otherwise a new one.
            if let kept = keys.key(for: profile), !keys.hasCertificate(for: profile) {
                key = kept
            } else {
                key = try keys.makeKey(for: profile)
            }
        } catch {
            step = .enterCode(sentTo: sentTo)
            notice = .notAccepted
            return
        }
        guard let csr = try? key.certificateRequest() else {
            step = .enterCode(sentTo: sentTo)
            notice = .notAccepted
            return
        }
        var attestKey: String?
        var attestation: Data?
        if hello.attest != .off, let attesting {
            let hash = EnrollProof.attestClientDataHash(code: code, username: username, subjectPublicKeyInfo: key.subjectPublicKeyInfo)
            if let made = await attesting.attest(clientDataHash: hash) {
                (attestKey, attestation) = (made.keyID, made.attestation)
            }
        }
        let application = EnrollApplication(
            code: code, csr: csr, deviceID: records.installID,
            name: deviceName.trimmingCharacters(in: .whitespacesAndNewlines),
            model: device.model, system: device.system, app: device.app, attestKey: attestKey, attestation: attestation
        )
        switch await api.apply(application) {
        case .filed(let request):
            var record = records.record(for: profile)
            record.request = request
            record.origin = origin.text
            records.set(record, for: profile)
            self.code = ""
            onFiled()
            step = .waiting(words: key.words)
            await poll()
        case .wrongCode(let triesLeft):
            if triesLeft == 0 {
                step = .expired
            } else if triesLeft == nil, await inviteGone() {
                step = .expired
            } else {
                step = .enterCode(sentTo: sentTo)
                notice = .wrongCode(triesLeft: triesLeft)
            }
        case .wrongPlace:
            step = .enterCode(sentTo: sentTo)
            notice = .wrongPlace
        case .refused:
            if await inviteGone() {
                step = .expired
            } else {
                step = .enterCode(sentTo: sentTo)
                notice = .notAccepted
            }
        case .unreachable:
            step = .enterCode(sentTo: sentTo)
            notice = .unreachable
        }
    }

    /// After a refused code with no count: true when hello says no invite waits any more.
    private func inviteGone() async -> Bool {
        if case .answer(let fresh) = await api.hello() {
            hello = fresh
            return !fresh.invited
        }
        return false
    }

    // MARK: Waiting

    /// The waiting screen's loop: asks now, then every `pollInterval`, until it's answered or the task
    /// ends (the screen left; the request is kept, and asked about again when it's back).
    public func waitForApproval() async {
        guard !polling else { return }
        polling = true
        defer { polling = false }
        while case .waiting = step, !Task.isCancelled {
            await poll()
            guard case .waiting = step else { return }
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    /// One ask for the request's state.
    public func poll() async {
        guard case .waiting = step, let request = records.record(for: profile).request,
              records.record(for: profile).belongs(to: origin), let key = keys.key(for: profile) else { return }
        let result = await api.status(request: request) { try key.sign($0) }
        guard case .waiting = step else { return }
        switch result {
        case .pending, .unreachable:
            break
        case .approved(let issued):
            guard CertificateKey.certificate(issued.certificate, isFor: key) else {
                // A certificate for another key (C49): not kept; the request counts as failed, as one the
                // server didn't take. The key stays (it holds no certificate, so it's used again).
                var record = records.record(for: profile)
                record.request = nil
                records.set(record, for: profile)
                await checkAgain()
                if case .enterCode = step { notice = .notAccepted }
                return
            }
            do {
                try keys.storeCertificate(issued.certificate, for: profile)
            } catch {
                return   // asked again on the next round
            }
            records.set(DeviceRecords.Record(renewAfter: issued.renewAfter, issuer: issued.issuer, origin: origin.text), for: profile)
            certificates?.refresh()
            step = .approved
            onApproved()
        case .denied:
            records.set(nil, for: profile)
            keys.remove(profile: profile)
            step = .denied
        case .refused:
            // The add-on doesn't know the request (it was cleared): start again from the invite.
            records.set(nil, for: profile)
            await checkAgain()
        }
    }
}

/// Whether a `hello` that says "not approved" to a device holding a certificate means the certificate is no
/// longer taken (re-check, item 1). That answer may have come over a connection opened before the
/// certificate was stored, which never presented it: so it counts only once a new connection, which does,
/// says the same. Anything else (approved, the server no longer asking, no answer) keeps the certificate.
public enum DeviceRevocation {
    /// Asks `hello` again after `freshConnection()` (`DeviceCertificates.resetConnections`). The new answer
    /// when it confirms the revocation, nil when the certificate stays.
    public static func confirm(api: any EnrollAPI, freshConnection: @Sendable () -> Void) async -> EnrollHello? {
        freshConnection()
        guard case .answer(let hello) = await api.hello(), hello.devices != .off, !hello.approved else { return nil }
        return hello
    }
}

/// Renewing a certificate when `renewAfter` has passed, with the same key, over a connection that
/// presents the current certificate.
public enum DeviceRenewal {
    public static func isDue(_ record: DeviceRecords.Record, now: Date) -> Bool {
        guard let renewAfter = record.renewAfter else { return false }
        return now.timeIntervalSince1970 >= renewAfter
    }

    /// True when a new certificate was stored. A refusal, no answer, or a certificate that isn't for this
    /// device's key leaves the current one. Only asked at `origin`, the address the certificate is for.
    @discardableResult
    public static func renewIfDue(
        profile: UUID, origin: DeviceOrigin, api: any EnrollAPI, keys: any DeviceKeyStore, records: DeviceRecords,
        certificates: DeviceCertificates?, now: Date = Date()
    ) async -> Bool {
        let record = records.record(for: profile)
        guard record.belongs(to: origin), isDue(record, now: now), keys.hasCertificate(for: profile),
              let key = keys.key(for: profile), let csr = try? key.certificateRequest() else { return false }
        guard case .renewed(let issued) = await api.renew(csr: csr),
              CertificateKey.certificate(issued.certificate, isFor: key) else { return false }
        guard (try? keys.storeCertificate(issued.certificate, for: profile)) != nil else { return false }
        records.set(
            DeviceRecords.Record(renewAfter: issued.renewAfter, issuer: issued.issuer ?? record.issuer, origin: origin.text),
            for: profile
        )
        certificates?.refresh()
        return true
    }
}
