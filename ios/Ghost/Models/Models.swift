import Foundation

// MARK: - API payloads (mirror backend/internal/api JSON)

struct TokenPair: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

struct VPNServer: Codable, Identifiable, Hashable {
    let id: String
    let city: String
    let country: String
    let countryCode: String
    let endpoint: String
    let publicKey: String
    let loadPct: Int
    let audited: Bool
    /// Part of the low-load pool reserved for Ghost Plus.
    let priority: Bool
    /// True when `priority` is set and this account can't use it. The server
    /// withholds endpoint/public key for locked entries, so a locked server
    /// can be shown but never connected to.
    let locked: Bool

    enum CodingKeys: String, CodingKey {
        case id, city, country, endpoint, audited, priority, locked
        case countryCode = "country_code"
        case publicKey = "public_key"
        case loadPct = "load_pct"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        city = try c.decode(String.self, forKey: .city)
        country = try c.decode(String.self, forKey: .country)
        countryCode = try c.decode(String.self, forKey: .countryCode)
        // Withheld for locked servers.
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        publicKey = try c.decodeIfPresent(String.self, forKey: .publicKey) ?? ""
        loadPct = try c.decode(Int.self, forKey: .loadPct)
        audited = try c.decode(Bool.self, forKey: .audited)
        priority = try c.decodeIfPresent(Bool.self, forKey: .priority) ?? false
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
    }

    var flagEmoji: String {
        countryCode.unicodeScalars.reduce(into: "") { result, scalar in
            if let flag = UnicodeScalar(127397 + scalar.value) {
                result.unicodeScalars.append(flag)
            }
        }
    }
}

struct Device: Codable, Identifiable {
    let id: String
    let name: String
    let publicKey: String
    let assignedIP: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case publicKey = "public_key"
        case assignedIP = "assigned_ip"
    }
}

struct DeviceRegistration: Codable {
    let device: Device
    let dns: [String]
    let allowedIPs: [String]

    enum CodingKeys: String, CodingKey {
        case device, dns
        case allowedIPs = "allowed_ips"
    }
}

/// Ghost Plus gates the priority server pool, panic wipe, and custom
/// multi-hop chains. Dedicated IPs and DNS filtering are free.
enum AccountTier: String, Codable {
    case free
    case paid

    var isPaid: Bool { self == .paid }
    var displayName: String { self == .paid ? "Ghost Plus" : "Ghost Free" }
}

struct DNSFilter: Codable, Equatable {
    var blockAds: Bool
    var blockMalware: Bool
    var blockTrackers: Bool
    var resolvers: [String]

    enum CodingKeys: String, CodingKey {
        case blockAds = "block_ads"
        case blockMalware = "block_malware"
        case blockTrackers = "block_trackers"
        case resolvers
    }

    static let off = DNSFilter(blockAds: false, blockMalware: false, blockTrackers: false, resolvers: [])

    var isAnyEnabled: Bool { blockAds || blockMalware || blockTrackers }

    var summary: String {
        var on: [String] = []
        if blockAds { on.append("Ads") }
        if blockTrackers { on.append("Trackers") }
        if blockMalware { on.append("Malware") }
        return on.isEmpty ? "Off" : on.joined(separator: ", ")
    }
}

struct DedicatedIP: Codable, Equatable {
    let ip: String
    let serverID: String

    enum CodingKeys: String, CodingKey {
        case ip
        case serverID = "server_id"
    }
}

struct Account: Codable {
    let id: String
    let email: String
    let tier: AccountTier
    let deviceCount: Int
    let deviceLimit: Int
    let dnsFilter: DNSFilter
    let dedicatedIP: DedicatedIP?
    let multiHopChain: [String]?

    enum CodingKeys: String, CodingKey {
        case id, email, tier
        case deviceCount = "device_count"
        case deviceLimit = "device_limit"
        case dnsFilter = "dns_filter"
        case dedicatedIP = "dedicated_ip"
        case multiHopChain = "multihop_chain"
    }
}

// MARK: - App state

/// Simple vs Advanced presentation, per docs/vpn-development-recommendations.md:
/// same screens and data, two densities. Persisted per device, not per account.
enum AppMode: String {
    case simple
    case advanced
}

enum TunnelProtocol: String, CaseIterable, Identifiable {
    case wireGuard = "WireGuard"
    case openVPN = "OpenVPN"
    case auto = "Auto"
    var id: String { rawValue }
}

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected(since: Date)
    case disconnecting

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isBusy: Bool {
        self == .connecting || self == .disconnecting
    }
}

struct TunnelStats: Equatable {
    var bytesUp: Int64 = 0
    var bytesDown: Int64 = 0
    var pingMs: Int = 0
}
