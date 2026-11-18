import Foundation
import Network

/// Whether the phone is on mobile data, for the streaming quality (C11). Mobile data means a path
/// over the cellular radio without Wi-Fi; anything else (Wi-Fi, a cable) counts as Wi-Fi. Flutter
/// counted every connection without Wi-Fi as mobile.
@Observable
final class NetworkMonitor {
    private(set) var isOnMobileData = false
    /// Whether there's a network path at all (C27: the server's tab is asked again when it comes back).
    private(set) var isConnected = true
    /// Called on the main actor when `isOnMobileData` changes.
    @ObservationIgnored var onChange: (() -> Void)?
    /// Called on the main actor when the path changes while there's a network (another Wi-Fi, or
    /// mobile data, or back after none): fresh connections, the server's LAN address tried again, and a
    /// song that failed for the network's sake loaded again (C68). Not for the first path, at launch.
    @ObservationIgnored var onPathChange: (() -> Void)?
    @ObservationIgnored private var hasSeenPath = false
    /// Smart Downloads may run (C37): a path is known and it's Wi-Fi or a cable, not mobile data, Low
    /// Data Mode or a personal hotspot (expensive). False until the first path, so nothing starts on
    /// mobile data in the moment before it's known.
    private(set) var allowsAutomaticDownloads = false
    /// Called on the main actor when `allowsAutomaticDownloads` changes.
    @ObservationIgnored var onAutomaticDownloadsChange: (() -> Void)?

    @ObservationIgnored private let monitor = NWPathMonitor()

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let mobile = path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi)
            let connected = path.status == .satisfied
            let automatic = connected && !mobile && !path.isConstrained && !path.isExpensive
            Task { @MainActor in
                self?.update(mobile)
                self?.updateAutomatic(automatic)
                if self?.isConnected != connected { self?.isConnected = connected }
                self?.pathChanged(connected: connected)
            }
        }
        monitor.start(queue: DispatchQueue(label: "NetworkMonitor"))
    }

    private func pathChanged(connected: Bool) {
        let isFirst = !hasSeenPath
        hasSeenPath = true
        if connected, !isFirst { onPathChange?() }
    }

    private func updateAutomatic(_ allowed: Bool) {
        guard allowed != allowsAutomaticDownloads else { return }
        allowsAutomaticDownloads = allowed
        onAutomaticDownloadsChange?()
    }

    private func update(_ mobile: Bool) {
        guard mobile != isOnMobileData else { return }
        isOnMobileData = mobile
        onChange?()
    }
}
