import Foundation

// MARK: - Configuration

struct MonicaServerConfig: Equatable {
    /// Root of the Monica instance, e.g. `https://app.monicahq.com` or a
    /// self-hosted `https://monica.example.org`.
    let baseURL: URL
    /// A personal access token created in Settings → API on the server.
    let token: String

    /// Normalizes user input: trims whitespace, adds a scheme when missing and
    /// strips trailing slashes and an accidental `/api` suffix.
    static func normalizedBaseURL(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "https://" + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        if text.lowercased().hasSuffix("/api") { text.removeLast(4) }
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text)
    }

    var apiRoot: URL { baseURL.appendingPathComponent("api") }

    /// Web page for a contact on this instance, used both as a convenience
    /// link and as the marker that ties an iPhone contact back to Monica.
    func webURL(forContactID id: Int, hashID: String?) -> URL {
        baseURL.appendingPathComponent("people").appendingPathComponent(hashID ?? String(id))
    }
}

// MARK: - Errors

enum MonicaAPIError: LocalizedError {
    case invalidURL
    case unauthorized
    case http(status: Int, message: String?)
    case decoding(Error)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The server URL is not valid."
        case .unauthorized:
            return "The server rejected the API token. Create a new token in Monica under Settings → API."
        case .http(let status, let message):
            return message ?? "The server answered with HTTP \(status)."
        case .decoding:
            return "Received an unexpected answer from the server. Is this a Monica instance?"
        case .transport(let error):
            return error.localizedDescription
        }
    }
}

// MARK: - Client

/// Thin async client for the Monica REST API (v4.x, compatible with
/// monicahq.com and self-hosted instances). Authenticates with a Bearer token.
final class MonicaAPIClient: @unchecked Sendable {
    private let config: MonicaServerConfig
    private let session: URLSession
    private let decoder: JSONDecoder

    /// Maximum page size the Monica API accepts.
    private static let pageLimit = 100

    init(config: MonicaServerConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
        self.decoder = Self.makeDecoder()
    }

    var serverConfig: MonicaServerConfig { config }

    // MARK: Decoding

    /// Monica mixes several date formats across endpoints
    /// (`2018-10-01T22:10:36Z`, `2018-10-01T22:10:36.000000Z`, `2018-10-01`),
    /// so the decoder tries each in turn.
    private static func makeDecoder() -> JSONDecoder {
        let iso = ISO8601DateFormatter()
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dayOnly = DateFormatter()
        dayOnly.dateFormat = "yyyy-MM-dd"
        dayOnly.locale = Locale(identifier: "en_US_POSIX")
        dayOnly.timeZone = TimeZone(identifier: "UTC")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = iso.date(from: raw) { return date }
            if let date = isoFractional.date(from: raw) { return date }
            if let date = dayOnly.date(from: String(raw.prefix(10))) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized date format: \(raw)"
            )
        }
        return decoder
    }

    // MARK: Requests

    private func makeRequest(
        path: String,
        query: [URLQueryItem] = [],
        method: String = "GET",
        body: [String: Any]? = nil
    ) throws -> URLRequest {
        var components = URLComponents(
            url: config.apiRoot.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw MonicaAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    /// Executes the request and validates the HTTP status, returning raw data.
    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MonicaAPIError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw MonicaAPIError.http(status: 0, message: nil)
        }
        switch http.statusCode {
        case 200...299:
            return data
        case 401:
            throw MonicaAPIError.unauthorized
        default:
            let message = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data))?.error?.message
            throw MonicaAPIError.http(status: http.statusCode, message: message)
        }
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let data = try await perform(request)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw MonicaAPIError.decoding(error)
        }
    }

    /// For writes where only success/failure matters.
    private func sendIgnoringBody(_ request: URLRequest) async throws {
        _ = try await perform(request)
    }

    /// Walks `?page=` until `meta.last_page`, concatenating `data` arrays.
    private func fetchAllPages<T: Decodable>(
        path: String,
        query: [URLQueryItem] = []
    ) async throws -> [T] {
        var results: [T] = []
        var page = 1
        while true {
            var pageQuery = query
            pageQuery.append(URLQueryItem(name: "page", value: String(page)))
            pageQuery.append(URLQueryItem(name: "limit", value: String(Self.pageLimit)))
            let request = try makeRequest(path: path, query: pageQuery)
            let response = try await send(request, as: PagedResponse<T>.self)
            results.append(contentsOf: response.data)
            let lastPage = response.meta?.lastPage ?? page
            if page >= lastPage || response.data.isEmpty { break }
            page += 1
        }
        return results
    }

    // MARK: Session

    /// Validates the server URL + token pair. Returns the account owner's
    /// display name when the server exposes `/api/me` (optional endpoint).
    func validateCredentials() async throws -> String? {
        let request = try makeRequest(
            path: "contacts",
            query: [URLQueryItem(name: "limit", value: "1")]
        )
        _ = try await send(request, as: PagedResponse<MonicaContact>.self)

        if let meRequest = try? makeRequest(path: "me"),
           let me = try? await send(meRequest, as: SingleResponse<MonicaUser>.self) {
            return me.data.displayName
        }
        return nil
    }

    // MARK: Contacts

    func fetchAllContacts() async throws -> [MonicaContact] {
        try await fetchAllPages(
            path: "contacts",
            query: [URLQueryItem(name: "with", value: "contactfields")]
        )
    }

    func fetchContact(id: Int) async throws -> MonicaContact {
        let request = try makeRequest(
            path: "contacts/\(id)",
            query: [URLQueryItem(name: "with", value: "contactfields")]
        )
        return try await send(request, as: SingleResponse<MonicaContact>.self).data
    }

    func fetchContactFieldTypes() async throws -> [MonicaContactFieldType] {
        try await fetchAllPages(path: "contactfieldtypes")
    }

    func createContactField(contactID: Int, typeID: Int, value: String) async throws {
        let request = try makeRequest(
            path: "contactfields",
            method: "POST",
            body: [
                "contact_id": contactID,
                "contact_field_type_id": typeID,
                "data": value,
            ]
        )
        try await sendIgnoringBody(request)
    }

    func deleteContactField(id: Int) async throws {
        let request = try makeRequest(path: "contactfields/\(id)", method: "DELETE")
        try await sendIgnoringBody(request)
    }

    // MARK: Tasks

    func fetchAllTasks() async throws -> [MonicaTask] {
        try await fetchAllPages(path: "tasks")
    }

    func fetchTasks(contactID: Int) async throws -> [MonicaTask] {
        try await fetchAllPages(path: "contacts/\(contactID)/tasks")
    }

    func createTask(contactID: Int, title: String, description: String?) async throws {
        var body: [String: Any] = [
            "contact_id": contactID,
            "title": title,
            "completed": 0,
        ]
        if let description, !description.isEmpty { body["description"] = description }
        let request = try makeRequest(path: "tasks", method: "POST", body: body)
        try await sendIgnoringBody(request)
    }

    func updateTask(_ task: MonicaTask, title: String, completed: Bool) async throws {
        var body: [String: Any] = [
            "title": title,
            "completed": completed ? 1 : 0,
        ]
        if let contactID = task.contact?.id { body["contact_id"] = contactID }
        if let description = task.description, !description.isEmpty {
            body["description"] = description
        }
        let request = try makeRequest(path: "tasks/\(task.id)", method: "PUT", body: body)
        try await sendIgnoringBody(request)
    }

    func deleteTask(id: Int) async throws {
        let request = try makeRequest(path: "tasks/\(id)", method: "DELETE")
        try await sendIgnoringBody(request)
    }

    // MARK: Reminders

    func fetchAllReminders() async throws -> [MonicaReminder] {
        try await fetchAllPages(path: "reminders")
    }

    func fetchReminders(contactID: Int) async throws -> [MonicaReminder] {
        try await fetchAllPages(path: "contacts/\(contactID)/reminders")
    }

    // MARK: Activities

    func fetchAllActivities() async throws -> [MonicaActivity] {
        try await fetchAllPages(path: "activities")
    }

    func fetchActivities(contactID: Int) async throws -> [MonicaActivity] {
        try await fetchAllPages(path: "contacts/\(contactID)/activities")
    }

    // MARK: Calls

    func fetchCalls(contactID: Int) async throws -> [MonicaCall] {
        try await fetchAllPages(path: "contacts/\(contactID)/calls")
    }

    func createCall(contactID: Int, content: String, calledAt: Date) async throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let request = try makeRequest(
            path: "calls",
            method: "POST",
            body: [
                "contact_id": contactID,
                "called_at": formatter.string(from: calledAt),
                "content": content,
            ]
        )
        try await sendIgnoringBody(request)
    }

    // MARK: Avatars

    /// Best-effort avatar download; returns nil on any failure so a broken
    /// avatar URL never blocks a sync.
    func fetchAvatarData(from urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              !data.isEmpty
        else { return nil }
        return data
    }
}
