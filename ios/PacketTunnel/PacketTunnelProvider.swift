import NetworkExtension
import WireGuardKit

/// Ghost's packet tunnel provider: runs in the network extension process and
/// drives the actual WireGuard tunnel via WireGuardKit's adapter.
///
/// Requires the Network Extension (packet-tunnel-provider) entitlement on
/// both this target and the app, and a reachable WireGuard endpoint. See
/// ios/README.md for the enablement checklist.
class PacketTunnelProvider: NEPacketTunnelProvider {

    private lazy var adapter = WireGuardAdapter(with: self) { _, message in
        // WireGuardKit's own log line — routed to os_log by the adapter.
        // Never add per-connection logging here: the extension sees traffic
        // metadata that must not be recorded (no-logs constraint).
        NSLog("WireGuard: %{public}@", message)
    }

    override func startTunnel(options: [String: NSObject]?) async throws {
        guard
            let proto = protocolConfiguration as? NETunnelProviderProtocol,
            let config = proto.providerConfiguration,
            let privateKey = config["privateKey"] as? String,
            let serverPublicKey = config["serverPublicKey"] as? String,
            let endpoint = config["endpoint"] as? String,
            let assignedIP = config["assignedIP"] as? String
        else {
            throw NEVPNError(.configurationInvalid)
        }
        let dns = (config["dns"] as? [String]) ?? ["10.64.0.1"]
        let allowedIPs = (config["allowedIPs"] as? [String]) ?? ["0.0.0.0/0", "::/0"]

        // Build a wg-quick–style configuration for WireGuardKit.
        let quickConfig = """
        [Interface]
        PrivateKey = \(privateKey)
        Address = \(assignedIP)/32
        DNS = \(dns.joined(separator: ", "))

        [Peer]
        PublicKey = \(serverPublicKey)
        Endpoint = \(endpoint)
        AllowedIPs = \(allowedIPs.joined(separator: ", "))
        PersistentKeepalive = 25
        """

        guard let tunnelConfig = try? TunnelConfiguration(fromWgQuickConfig: quickConfig) else {
            throw NEVPNError(.configurationInvalid)
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            adapter.start(tunnelConfiguration: tunnelConfig) { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            adapter.stop { _ in cont.resume() }
        }
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        // Reserved for stats requests from the app (transfer counters via
        // adapter.getRuntimeConfiguration). Not wired in v1.
        nil
    }
}
