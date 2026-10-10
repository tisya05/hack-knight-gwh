import Foundation

@MainActor
final class TelemetryClient: TelemetryReporting {
    var pendingCount: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: pendingDirectory.path))?.count ?? 0
    }

    private let baseURL: URL
    private let token: String
    private let pendingDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.pendingDirectory = docs.appendingPathComponent("pending_rounds")
        try? FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    convenience init() {
        let url = Config.backendBaseURL
        let token = Bundle.main.infoDictionary?["ECHORA_BACKEND_TOKEN"] as? String ?? ""
        self.init(baseURL: url, token: token)
    }

    func report(_ result: RoundResult) async {
        guard !token.isEmpty else { return }
        var request = URLRequest(url: baseURL.appendingPathComponent("/api/rounds"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-Echora-Token")
        do {
            request.httpBody = try encoder.encode(result)
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                queuePending(result)
                return
            }
        } catch {
            queuePending(result)
        }
    }

    func fetchStats() async -> StudyStats? {
        guard !token.isEmpty else { return nil }
        var request = URLRequest(url: baseURL.appendingPathComponent("/api/stats"))
        request.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            return try decoder.decode(StudyStats.self, from: data)
        } catch {
            return nil
        }
    }

    func ping() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("/health"))
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func reportSamples(_ samples: [RoundSample]) async {
        guard !samples.isEmpty, !token.isEmpty else { return }
        // Group by roundId – TelemetryReporting expects per-round call from coordinator
        guard let first = samples.first else { return }
        let roundId = first.roundId
        var request = URLRequest(url: baseURL.appendingPathComponent("/api/rounds/\(roundId)/samples"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-Echora-Token")
        do {
            request.httpBody = try encoder.encode(samples)
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) else { return }
            // On failure, drop samples per default contract – no offline queue required
        } catch {
            // drop
        }
    }

    private func queuePending(_ result: RoundResult) {
        do {
            let data = try encoder.encode(result)
            let file = pendingDirectory.appendingPathComponent("\(result.id).json")
            try data.write(to: file)
        } catch {}
    }

    func retryPending() async {
        let reachable = await ping()
        guard reachable else { return }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: pendingDirectory.path)) ?? []
        for fileName in files {
            let url = pendingDirectory.appendingPathComponent(fileName)
            guard let data = try? Data(contentsOf: url),
                  let result = try? decoder.decode(RoundResult.self, from: data) else { continue }
            await report(result)
            try? FileManager.default.removeItem(at: url)
        }
    }
}
