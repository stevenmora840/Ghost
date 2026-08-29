import Foundation

enum APIError: LocalizedError {
    case http(Int, String)
    case unauthorized
    /// The server answered 402: this feature needs Ghost Plus.
    case upgradeRequired(String)
    case network(Error)

    var errorDescription: String? {
        switch self {
        case let .http(_, message): return message
        case .unauthorized: return "Session expired — please sign in again."
        case let .upgradeRequired(message): return message
        case let .network(err): return err.localizedDescription
        }
    }
}

/// Client for ghostd's control-plane API. Handles bearer auth and one
/// transparent refresh-and-retry when the access token has expired.
actor APIClient {
    /// Point at your ghostd instance. The simulator can reach a ghostd
    /// running on the same Mac at localhost.
    static let defaultBaseURL = URL(string: "http://localhost:8080")!

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = APIClient.defaultBaseURL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.ephemeral // no cookie/cache persistence
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    // MARK: Auth

    func register(email: String, password: String) async throws -> TokenPair {
        try await post("/v1/auth/register", body: ["email": email, "password": password], authorized: false)
    }

    func login(email: String, password: String) async throws -> TokenPair {
        try await post("/v1/auth/login", body: ["email": email, "password": password], authorized: false)
    }

    func signInWithApple(identityToken: String) async throws -> TokenPair {
        try await post("/v1/auth/apple", body: ["identity_token": identityToken], authorized: false)
    }

    // MARK: Resources

    func servers() async throws -> [VPNServer] {
        struct Wrapper: Codable { let servers: [VPNServer] }
        let w: Wrapper = try await get("/v1/servers")
        return w.servers
    }

    func account() async throws -> Account {
        try await get("/v1/account")
    }

    func registerDevice(name: String, publicKey: String) async throws -> DeviceRegistration {
        try await post("/v1/devices", body: ["name": name, "public_key": publicKey], authorized: true)
    }

    func deleteDevice(id: String) async throws {
        _ = try await send(path: "/v1/devices/\(id)", method: "DELETE", body: nil, authorized: true) as Data
    }

    // MARK: Free tier — DNS filtering & dedicated IP

    func dnsFilter() async throws -> DNSFilter {
        try await get("/v1/dns-filter")
    }

    func setDNSFilter(ads: Bool, malware: Bool, trackers: Bool) async throws -> DNSFilter {
        let payload = try JSONEncoder().encode([
            "block_ads": ads, "block_malware": malware, "block_trackers": trackers,
        ])
        let data = try await send(path: "/v1/dns-filter", method: "PUT", body: payload, authorized: true)
        return try JSONDecoder().decode(DNSFilter.self, from: data)
    }

    private struct DedicatedIPWrapper: Codable {
        let dedicatedIP: DedicatedIP?
        enum CodingKeys: String, CodingKey { case dedicatedIP = "dedicated_ip" }
    }

    func dedicatedIP() async throws -> DedicatedIP? {
        let w: DedicatedIPWrapper = try await get("/v1/dedicated-ip")
        return w.dedicatedIP
    }

    func allocateDedicatedIP(serverID: String) async throws -> DedicatedIP? {
        let w: DedicatedIPWrapper = try await post("/v1/dedicated-ip", body: ["server_id": serverID], authorized: true)
        return w.dedicatedIP
    }

    func releaseDedicatedIP() async throws {
        _ = try await send(path: "/v1/dedicated-ip", method: "DELETE", body: nil, authorized: true)
    }

    // MARK: Paid tier — multi-hop chain & panic wipe

    private struct ChainWrapper: Codable { let chain: [String]? }

    func multiHopChain() async throws -> [String] {
        let w: ChainWrapper = try await get("/v1/multihop")
        return w.chain ?? []
    }

    func setMultiHopChain(_ chain: [String]) async throws -> [String] {
        let payload = try JSONEncoder().encode(["chain": chain])
        let data = try await send(path: "/v1/multihop", method: "PUT", body: payload, authorized: true)
        return (try JSONDecoder().decode(ChainWrapper.self, from: data)).chain ?? []
    }

    func clearMultiHopChain() async throws {
        _ = try await send(path: "/v1/multihop", method: "DELETE", body: nil, authorized: true)
    }

    /// Revokes every device, session, and allocation tied to this account's
    /// current identity. The caller's access token stays valid so the app can
    /// immediately re-provision a fresh one.
    func panicWipe() async throws {
        _ = try await send(path: "/v1/account/panic-wipe", method: "POST", body: Data("{}".utf8), authorized: true)
    }

    /// Development-only tier switch (ghostd must run with
    /// GHOST_ALLOW_TIER_OVERRIDE=1). Replaced by a payment flow.
    func setTier(_ tier: AccountTier) async throws {
        let payload = try JSONEncoder().encode(["tier": tier.rawValue])
        _ = try await send(path: "/v1/account/tier", method: "POST", body: payload, authorized: true)
    }

    // MARK: Plumbing

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let data = try await send(path: path, method: "GET", body: nil, authorized: true)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post<T: Decodable>(_ path: String, body: [String: String], authorized: Bool) async throws -> T {
        let payload = try JSONEncoder().encode(body)
        let data = try await send(path: path, method: "POST", body: payload, authorized: authorized)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func send(path: String, method: String, body: Data?, authorized: Bool, isRetry: Bool = false) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authorized, let token = KeychainStore.get(.accessToken) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.network(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 401, authorized, !isRetry {
            try await refreshTokens()
            return try await send(path: path, method: method, body: body, authorized: authorized, isRetry: true)
        }
        guard (200..<300).contains(status) else {
            struct ErrBody: Codable { let error: String }
            let message = (try? JSONDecoder().decode(ErrBody.self, from: data))?.error ?? "Request failed (\(status))"
            switch status {
            case 401: throw APIError.unauthorized
            case 402: throw APIError.upgradeRequired(message)
            default: throw APIError.http(status, message)
            }
        }
        return data
    }

    private func refreshTokens() async throws {
        guard let refresh = KeychainStore.get(.refreshToken) else { throw APIError.unauthorized }
        let payload = try JSONEncoder().encode(["refresh_token": refresh])
        let data = try await send(path: "/v1/auth/refresh", method: "POST", body: payload, authorized: false, isRetry: true)
        let pair = try JSONDecoder().decode(TokenPair.self, from: data)
        KeychainStore.set(pair.accessToken, for: .accessToken)
        KeychainStore.set(pair.refreshToken, for: .refreshToken)
    }
}
