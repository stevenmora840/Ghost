import Foundation
import NetworkExtension

/// The tunnel boundary. UI and app state talk only to this protocol, so the
/// security-critical path (the packet tunnel extension) stays isolated from
/// interface code — see docs/vpn-development-recommendations.md.
@MainActor
protocol TunnelController: AnyObject {
    var onStateChange: ((ConnectionState) -> Void)? { get set }
    func connect(to server: VPNServer, config: TunnelConfig) async throws
    func disconnect() async
}

/// Everything needed to bring up a WireGuard tunnel, assembled by AppState
/// from the device registration + selected server.
struct TunnelConfig {
    let privateKeyBase64: String
    let assignedIP: String        // e.g. "10.64.1.2"
    let dns: [String]
    let allowedIPs: [String]      // "0.0.0.0/0", "::/0" — kill switch builds on full-route
}

// MARK: - Demo implementation

/// Simulates the connection lifecycle so the full app works in the simulator
/// and before the Network Extension entitlement is granted. Selected
/// automatically when the real tunnel is unavailable.
@MainActor
final class DemoTunnelController: TunnelController {
    var onStateChange: ((ConnectionState) -> Void)?
    private var task: Task<Void, Never>?

    func connect(to server: VPNServer, config: TunnelConfig) async throws {
        onStateChange?(.connecting)
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            onStateChange?(.connected(since: Date()))
        }
    }

    func disconnect() async {
        task?.cancel()
        onStateChange?(.disconnecting)
        try? await Task.sleep(for: .milliseconds(300))
        onStateChange?(.disconnected)
    }
}

// MARK: - System (NetworkExtension) implementation

/// Drives the real WireGuard tunnel through the PacketTunnel app extension.
/// Requires the Personal VPN + Network Extension entitlements and a live
/// WireGuard endpoint; until both exist, AppState falls back to the demo
/// controller.
@MainActor
final class SystemTunnelController: TunnelController {
    var onStateChange: ((ConnectionState) -> Void)?
    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?

    static let providerBundleID = "com.ghostvpn.ios.PacketTunnel"

    /// Loads or creates the tunnel configuration in Settings. Returns nil if
    /// the extension can't be used (no entitlement, unsupported platform).
    static func loadOrCreate() async -> SystemTunnelController? {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            let controller = SystemTunnelController()
            controller.manager = managers.first ?? NETunnelProviderManager()
            return controller
        } catch {
            return nil
        }
    }

    func connect(to server: VPNServer, config: TunnelConfig) async throws {
        guard let manager else { throw TunnelError.unavailable }

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.providerBundleID
        proto.serverAddress = server.endpoint
        // Configuration crosses to the extension via providerConfiguration.
        // The private key is passed here (extension has no Keychain group by
        // default); switch to an App Group + shared Keychain before shipping.
        proto.providerConfiguration = [
            "privateKey": config.privateKeyBase64,
            "serverPublicKey": server.publicKey,
            "endpoint": server.endpoint,
            "assignedIP": config.assignedIP,
            "dns": config.dns,
            "allowedIPs": config.allowedIPs,
        ]

        manager.protocolConfiguration = proto
        manager.localizedDescription = "Ghost — \(server.city)"
        manager.isEnabled = true
        // On-demand keeps the tunnel up across network changes (part of the
        // kill-switch story; full leak-proofing also needs
        // includeAllNetworks, set below).
        if let p = manager.protocolConfiguration {
            p.includeAllNetworks = true      // route everything, no fallback outside the tunnel
            p.enforceRoutes = true
        }

        try await manager.saveToPreferences()
        try await manager.loadFromPreferences() // required before starting

        observeStatus(manager.connection)
        onStateChange?(.connecting)
        try manager.connection.startVPNTunnel()
    }

    func disconnect() async {
        onStateChange?(.disconnecting)
        manager?.connection.stopVPNTunnel()
    }

    private func observeStatus(_ connection: NEVPNConnection) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: connection, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                switch connection.status {
                case .connected: self?.onStateChange?(.connected(since: connection.connectedDate ?? Date()))
                case .connecting, .reasserting: self?.onStateChange?(.connecting)
                case .disconnecting: self?.onStateChange?(.disconnecting)
                default: self?.onStateChange?(.disconnected)
                }
            }
        }
    }
}

enum TunnelError: LocalizedError {
    case unavailable
    var errorDescription: String? { "VPN tunnel is not available on this device yet." }
}
