import Foundation

enum APIError: LocalizedError {
    case http(Int, String)
    case unauthorized
    case network(Error)

    var errorDescription: String? {
        switch self {
        case let .http(_, message): return message
        case .unauthorized: return "Session expired — please sign in again."
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
            throw status == 401 ? APIError.unauthorized : APIError.http(status, message)
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
