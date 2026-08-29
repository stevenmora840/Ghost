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

    enum CodingKeys: String, CodingKey {
        case id, city, country, endpoint, audited
        case countryCode = "country_code"
        case publicKey = "public_key"
        case loadPct = "load_pct"
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

struct Account: Codable {
    let id: String
    let email: String
    let deviceCount: Int
    let deviceLimit: Int

    enum CodingKeys: String, CodingKey {
        case id, email
        case deviceCount = "device_count"
        case deviceLimit = "device_limit"
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
