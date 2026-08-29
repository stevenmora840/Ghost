import Foundation
import SwiftUI
import UIKit

/// Central observable state: auth, mode, servers, and the tunnel lifecycle.
@MainActor
final class AppState: ObservableObject {
    // Mode is per-device by design (docs/vpn-development-recommendations.md).
    @AppStorage("appMode") private var storedMode: String = AppMode.simple.rawValue
    var mode: AppMode {
        get { AppMode(rawValue: storedMode) ?? .simple }
        set {
            objectWillChange.send()
            storedMode = newValue.rawValue
        }
    }

    @Published var isSignedIn: Bool
    @Published var servers: [VPNServer] = []
    @Published var selectedServer: VPNServer?
    @Published var connection: ConnectionState = .disconnected
    @Published var stats = TunnelStats()
    @Published var account: Account?
    @Published var errorMessage: String?

    // Advanced-mode settings. v1 surfaces the controls; obfuscation and
    // multi-hop are UI + config plumbing ahead of PoP support.
    @Published var tunnelProtocol: TunnelProtocol = .wireGuard
    @Published var killSwitchEnabled = true
    @Published var splitTunnelingEnabled = false
    @Published var obfuscationEnabled = false

    let api: APIClient
    private var tunnel: TunnelController?
    private var statsTimer: Timer?
    /// Set false to force the demo tunnel (default until the Network
    /// Extension entitlement + a live endpoint exist — see ios/README.md).
    static var useSystemTunnel = false

    init(api: APIClient = APIClient()) {
        self.api = api
        self.isSignedIn = KeychainStore.get(.refreshToken) != nil
    }

    // MARK: Auth

    func signIn(with pair: TokenPair) {
        KeychainStore.set(pair.accessToken, for: .accessToken)
        KeychainStore.set(pair.refreshToken, for: .refreshToken)
        isSignedIn = true
        Task { await bootstrap() }
    }

    func signOut() async {
        await disconnect()
        KeychainStore.clearAll()
        servers = []
        selectedServer = nil
        account = nil
        isSignedIn = false
    }

    /// Post-sign-in setup: register this device's WireGuard key (idempotent
    /// per key) and load the catalog.
    func bootstrap() async {
        do {
            let publicKey = WireGuardKeys.ensureKeypair()
            if KeychainStore.get(.deviceID) == nil {
                let reg = try await api.registerDevice(name: UIDevice.current.name, publicKey: publicKey)
                KeychainStore.set(reg.device.id, for: .deviceID)
                UserDefaults.standard.set(reg.device.assignedIP, forKey: "assignedIP")
                UserDefaults.standard.set(reg.dns, forKey: "tunnelDNS")
                UserDefaults.standard.set(reg.allowedIPs, forKey: "tunnelAllowedIPs")
            }
            try await refreshServers()
            account = try? await api.account()
        } catch let err as APIError {
            if case .unauthorized = err {
                await signOut()
            } else if case .http(409, _) = err {
                // Key already registered (fresh install with an old Keychain);
                // carry on — the server list is what matters.
                try? await refreshServers()
            } else {
                errorMessage = err.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshServers() async throws {
        servers = try await api.servers()
        if selectedServer == nil {
            selectedServer = servers.first // list is load-sorted: first ≈ best
        }
    }

    // MARK: Tunnel

    func toggleConnection() async {
        if connection.isConnected || connection.isBusy {
            await disconnect()
        } else {
            await connect()
        }
    }

    func connect() async {
        guard let server = selectedServer else {
            errorMessage = "Pick a location first."
            return
        }
        guard let privateKey = WireGuardKeys.privateKeyBase64,
              let assignedIP = UserDefaults.standard.string(forKey: "assignedIP")
        else {
            await bootstrap()
            errorMessage = UserDefaults.standard.string(forKey: "assignedIP") == nil
                ? "Device isn't registered yet — check your connection and try again."
                : nil
            return
        }

        let config = TunnelConfig(
            privateKeyBase64: privateKey,
            assignedIP: assignedIP,
            dns: UserDefaults.standard.stringArray(forKey: "tunnelDNS") ?? ["10.64.0.1"],
            allowedIPs: UserDefaults.standard.stringArray(forKey: "tunnelAllowedIPs") ?? ["0.0.0.0/0", "::/0"]
        )

        if tunnel == nil {
            if Self.useSystemTunnel, let system = await SystemTunnelController.loadOrCreate() {
                tunnel = system
            } else {
                tunnel = DemoTunnelController()
            }
            tunnel?.onStateChange = { [weak self] state in
                self?.connection = state
                if state.isConnected { self?.startStatsTicker() } else { self?.stopStatsTicker() }
            }
        }

        do {
            try await tunnel?.connect(to: server, config: config)
        } catch {
            connection = .disconnected
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() async {
        await tunnel?.disconnect()
    }

    // MARK: Stats (demo values until the extension reports real counters)

    private func startStatsTicker() {
        stats = TunnelStats(bytesUp: 0, bytesDown: 0, pingMs: Int.random(in: 14...32))
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.connection.isConnected else { return }
                self.stats.bytesUp += Int64.random(in: 8_000...220_000)
                self.stats.bytesDown += Int64.random(in: 40_000...900_000)
            }
        }
    }

    private func stopStatsTicker() {
        statsTimer?.invalidate()
        statsTimer = nil
        stats = TunnelStats()
    }
}

extension Int64 {
    var byteString: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .binary)
    }
}
