import Foundation

// MARK: - Wire models (Monica v5 vault-scoped API)

struct V5Vault: Decodable {
    let id: String
    let name: String
    let description: String?
}

struct V5Contact: Decodable {
    let id: String
    let vaultID: String?
    let firstName: String?
    let lastName: String?
    let nickname: String?
    let name: String?
    let jobPosition: String?
    let company: V5Company?
    let avatarURL: String?
    let contactInformation: [V5ContactInformation]?
    let addresses: [V5Address]?
    let importantDates: [V5ImportantDate]?

    enum CodingKeys: String, CodingKey {
        case id
        case vaultID = "vault_id"
        case firstName = "first_name"
        case lastName = "last_name"
        case nickname
        case name
        case jobPosition = "job_position"
        case company
        case avatarURL = "avatar_url"
        case contactInformation = "contact_information"
        case addresses
        case importantDates = "important_dates"
    }

    struct V5Company: Decodable {
        let id: String?
        let name: String?
    }
}

struct V5ContactInformation: Decodable {
    let id: Int
    let kind: String?
    let content: String?
    let contactInformationType: V5ContactInformationType?

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case content
        case contactInformationType = "contact_information_type"
    }
}

struct V5ContactInformationType: Decodable {
    let id: Int
    let name: String?
    let protocolPrefix: String?
    let type: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case protocolPrefix = "protocol"
        case type
    }
}

struct V5Address: Decodable {
    let id: Int
    let line1: String?
    let line2: String?
    let city: String?
    let province: String?
    let postalCode: String?
    let country: String?
    let addressType: V5AddressType?

    enum CodingKeys: String, CodingKey {
        case id
        case line1 = "line_1"
        case line2 = "line_2"
        case city
        case province
        case postalCode = "postal_code"
        case country
        case addressType = "address_type"
    }

    struct V5AddressType: Decodable {
        let id: Int?
        let name: String?
    }
}

struct V5ImportantDate: Decodable {
    let id: Int
    let label: String?
    let day: Int?
    let month: Int?
    let year: Int?
    let type: V5ImportantDateType?

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case day
        case month
        case year
        case type = "contact_important_date_type"
    }

    struct V5ImportantDateType: Decodable {
        let id: Int?
        let label: String?
        let internalType: String?

        enum CodingKeys: String, CodingKey {
            case id
            case label
            case internalType = "internal_type"
        }
    }
}

struct V5Task: Decodable {
    let id: Int
    let label: String?
    let description: String?
    let completed: Bool?
    let contact: V5ContactSummary?

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case description
        case completed
        case contact
    }
}

struct V5Reminder: Decodable {
    let id: Int
    let label: String?
    let day: Int?
    let month: Int?
    let year: Int?
    let type: String?
    let frequencyNumber: Int?
    let contact: V5ContactSummary?

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case day
        case month
        case year
        case type
        case frequencyNumber = "frequency_number"
        case contact
    }
}

struct V5Call: Decodable {
    let id: Int
    let calledAt: String?
    let description: String?

    enum CodingKeys: String, CodingKey {
        case id
        case calledAt = "called_at"
        case description
    }
}

struct V5ContactSummary: Decodable {
    let id: String
    let name: String?
    let vaultID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case vaultID = "vault_id"
    }
}

// MARK: - Client

/// Async client for the Monica v5 vault-scoped REST API, authenticated with
/// a Sanctum token created under Settings → API Tokens.
final class MonicaV5Client: @unchecked Sendable {
    let baseURL: URL
    private let token: String
    private let session: URLSession
    private let decoder = JSONDecoder()

    private static let pageLimit = 100

    init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    // MARK: Requests

    private func makeRequest(
        path: String,
        query: [URLQueryItem] = [],
        method: String = "GET",
        body: [String: Any]? = nil
    ) throws -> URLRequest {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api").appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw MonicaAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

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

    private func fetchAllPages<T: Decodable>(path: String) async throws -> [T] {
        var results: [T] = []
        var page = 1
        while true {
            let request = try makeRequest(path: path, query: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "limit", value: String(Self.pageLimit)),
            ])
            let response = try await send(request, as: PagedResponse<T>.self)
            results.append(contentsOf: response.data)
            let lastPage = response.meta?.lastPage ?? page
            if page >= lastPage || response.data.isEmpty { break }
            page += 1
        }
        return results
    }

    // MARK: Endpoints

    func fetchVaults() async throws -> [MonicaVault] {
        let vaults: [V5Vault] = try await fetchAllPages(path: "vaults")
        return vaults.map { MonicaVault(id: $0.id, name: $0.name, description: $0.description) }
    }

    func fetchContacts(vaultID: String) async throws -> [V5Contact] {
        try await fetchAllPages(path: "vaults/\(vaultID)/contacts")
    }

    func fetchContact(vaultID: String, contactID: String) async throws -> V5Contact {
        let request = try makeRequest(path: "vaults/\(vaultID)/contacts/\(contactID)")
        return try await send(request, as: SingleResponse<V5Contact>.self).data
    }

    func fetchTasks(vaultID: String) async throws -> [V5Task] {
        try await fetchAllPages(path: "vaults/\(vaultID)/tasks")
    }

    func fetchReminders(vaultID: String) async throws -> [V5Reminder] {
        try await fetchAllPages(path: "vaults/\(vaultID)/reminders")
    }

    func fetchCalls(vaultID: String, contactID: String) async throws -> [V5Call] {
        try await fetchAllPages(path: "vaults/\(vaultID)/contacts/\(contactID)/calls")
    }

    func toggleTask(vaultID: String, taskID: Int) async throws {
        let request = try makeRequest(
            path: "vaults/\(vaultID)/tasks/\(taskID)/toggle", method: "PUT"
        )
        _ = try await perform(request)
    }

    func createTask(vaultID: String, contactID: String, label: String, description: String?) async throws {
        var body: [String: Any] = ["label": label]
        if let description, !description.isEmpty { body["description"] = description }
        let request = try makeRequest(
            path: "vaults/\(vaultID)/contacts/\(contactID)/tasks",
            method: "POST",
            body: body
        )
        _ = try await perform(request)
    }

    func createCall(vaultID: String, contactID: String, description: String, calledAt: Date) async throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let request = try makeRequest(
            path: "vaults/\(vaultID)/contacts/\(contactID)/calls",
            method: "POST",
            body: [
                "called_at": formatter.string(from: calledAt),
                "description": description,
            ]
        )
        _ = try await perform(request)
    }

    func fetchContactInformationTypes() async throws -> [V5ContactInformationType] {
        try await fetchAllPages(path: "contactInformationTypes")
    }

    func createContactInformation(
        vaultID: String, contactID: String, typeID: Int, value: String
    ) async throws {
        let request = try makeRequest(
            path: "vaults/\(vaultID)/contacts/\(contactID)/contactInformation",
            method: "POST",
            body: [
                "contact_information_type_id": typeID,
                "data": value,
            ]
        )
        _ = try await perform(request)
    }

    func deleteContactInformation(
        vaultID: String, contactID: String, informationID: Int
    ) async throws {
        let request = try makeRequest(
            path: "vaults/\(vaultID)/contacts/\(contactID)/contactInformation/\(informationID)",
            method: "DELETE"
        )
        _ = try await perform(request)
    }

    func fetchAvatarData(from urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              !data.isEmpty
        else { return nil }
        return data
    }
}
