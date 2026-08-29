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
    /// Set when a paid-only action was attempted; drives the upgrade sheet.
    @Published var upgradePrompt: String?

    // Tier features.
    @Published var dnsFilter: DNSFilter = .off
    @Published var dedicatedIP: DedicatedIP?
    @Published var multiHopChain: [String] = []

    var tier: AccountTier { account?.tier ?? .free }
    var isPaid: Bool { tier.isPaid }

    /// Servers this account can actually connect to.
    var usableServers: [VPNServer] { servers.filter { !$0.locked } }

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
            await refreshAccount()
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
        // Never leave a locked server selected — it carries no tunnel
        // credentials, so connecting would fail.
        if let current = selectedServer,
           let updated = servers.first(where: { $0.id == current.id }) {
            selectedServer = updated.locked ? usableServers.first : updated
        }
        if selectedServer == nil {
            selectedServer = usableServers.first // load-sorted: first ≈ best
        }
    }

    /// Reloads the account and the tier-feature state it carries.
    func refreshAccount() async {
        guard let account = try? await api.account() else { return }
        self.account = account
        dnsFilter = account.dnsFilter
        dedicatedIP = account.dedicatedIP
        multiHopChain = account.multiHopChain ?? []
    }

    // MARK: Free tier — DNS threat & ad blocking

    /// Applies new blocking preferences. The response carries the resolver
    /// set, so the stored tunnel config updates without re-registering the
    /// device (which would consume a fresh tunnel address each toggle). A
    /// live tunnel is cycled so the change takes effect immediately.
    func updateDNSFilter(ads: Bool, malware: Bool, trackers: Bool) async {
        let previous = dnsFilter
        do {
            let updated = try await api.setDNSFilter(ads: ads, malware: malware, trackers: trackers)
            dnsFilter = updated
            UserDefaults.standard.set(updated.resolvers, forKey: "tunnelDNS")
            if connection.isConnected {
                await disconnect()
                await connect()
            }
        } catch {
            dnsFilter = previous
            handle(error)
        }
    }

    // MARK: Free tier — dedicated static IP

    func allocateDedicatedIP(serverID: String) async {
        do {
            dedicatedIP = try await api.allocateDedicatedIP(serverID: serverID)
        } catch {
            handle(error)
        }
    }

    func releaseDedicatedIP() async {
        do {
            try await api.releaseDedicatedIP()
            dedicatedIP = nil
        } catch {
            handle(error)
        }
    }

    // MARK: Paid tier — custom multi-hop chain

    func saveMultiHopChain(_ chain: [String]) async {
        do {
            multiHopChain = try await api.setMultiHopChain(chain)
        } catch {
            handle(error)
        }
    }

    func clearMultiHopChain() async {
        do {
            try await api.clearMultiHopChain()
            multiHopChain = []
        } catch {
            handle(error)
        }
    }

    // MARK: Paid tier — panic wipe

    /// Drops the tunnel, wipes the on-device key, revokes everything
    /// server-side, then provisions a brand-new identity. The account and
    /// sign-in survive; the keys, tunnel address, and allocations do not.
    func panicWipe() async {
        await disconnect()
        do {
            try await api.panicWipe()
        } catch {
            handle(error)
            return
        }

        // Local identity goes even if the server call already succeeded.
        KeychainStore.delete(.wireGuardPrivateKey)
        KeychainStore.delete(.deviceID)
        UserDefaults.standard.removeObject(forKey: "assignedIP")
        UserDefaults.standard.removeObject(forKey: "tunnelDNS")
        UserDefaults.standard.removeObject(forKey: "tunnelAllowedIPs")
        dedicatedIP = nil
        multiHopChain = []
        tunnel = nil

        // Fresh keypair + registration: a new tunnel address, unlinkable to
        // the old one.
        do {
            let publicKey = WireGuardKeys.ensureKeypair()
            let reg = try await api.registerDevice(name: UIDevice.current.name, publicKey: publicKey)
            KeychainStore.set(reg.device.id, for: .deviceID)
            UserDefaults.standard.set(reg.device.assignedIP, forKey: "assignedIP")
            UserDefaults.standard.set(reg.dns, forKey: "tunnelDNS")
            UserDefaults.standard.set(reg.allowedIPs, forKey: "tunnelAllowedIPs")
            await refreshAccount()
        } catch {
            handle(error)
        }
    }

    // MARK: Tier

    /// Development-only upgrade path until billing exists.
    func setTier(_ tier: AccountTier) async {
        do {
            try await api.setTier(tier)
            await refreshAccount()
            try await refreshServers()
        } catch {
            handle(error)
        }
    }

    /// Routes a 402 to the upgrade sheet and everything else to the error
    /// alert, so paid-feature refusals never read as failures.
    private func handle(_ error: Error) {
        if case let APIError.upgradeRequired(message) = error {
            upgradePrompt = message
        } else {
            errorMessage = error.localizedDescription
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
        guard !server.locked else {
            upgradePrompt = "\(server.city) is a priority location, part of Ghost Plus."
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
