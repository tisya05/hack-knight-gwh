import Foundation

@MainActor
final class TelemetryClient: TelemetryReporting {
    var pendingCount: Int {
        let rounds = (try? FileManager.default.contentsOfDirectory(
            atPath: pendingDirectory.path
        ).count) ?? 0
        let samples = (try? FileManager.default.contentsOfDirectory(
            atPath: pendingSamplesDirectory.path
        ).count) ?? 0
        return rounds + samples
    }

    private let baseURL: URL
    private let token: String
    private let pendingDirectory: URL
    private let pendingSamplesDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        self.pendingDirectory = docs.appendingPathComponent("pending_rounds")
        self.pendingSamplesDirectory = docs.appendingPathComponent("pending_samples")
        createDirectoryIfNeeded(at: pendingDirectory)
        createDirectoryIfNeeded(at: pendingSamplesDirectory)
        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        Task {
            await retryPending()
        }
    }

    convenience init() {
        let url = Config.backendBaseURL
        let token = Bundle.main.infoDictionary?["ECHORA_BACKEND_TOKEN"] as? String ?? ""
        self.init(baseURL: url, token: token)
    }

    func report(_ result: RoundResult) async {
        guard !token.isEmpty else { return }
        await retryPending()
        guard !(await send(result)) else { return }
        queuePending(result)
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
        guard let first = samples.first else { return }
        let roundId = first.roundId
        await retryPending()
        guard !(await send(samples)) else { return }
        queuePending(samples, roundId: roundId)
    }

    private func queuePending(_ result: RoundResult) {
        do {
            let data = try encoder.encode(result)
            let file = pendingDirectory.appendingPathComponent("\(result.id).json")
            try data.write(to: file, options: .atomic)
        } catch {
            print("Unable to queue round telemetry: \(error)")
        }
    }

    private func queuePending(_ samples: [RoundSample], roundId: String) {
        do {
            let data = try encoder.encode(samples)
            let file = pendingSamplesDirectory.appendingPathComponent("\(roundId).json")
            try data.write(to: file, options: .atomic)
        } catch {
            print("Unable to queue sample telemetry: \(error)")
        }
    }

    func retryPending() async {
        guard !token.isEmpty, await ping() else { return }

        for fileName in files(in: pendingDirectory) {
            let url = pendingDirectory.appendingPathComponent(fileName)
            guard let data = try? Data(contentsOf: url),
                  let result = try? decoder.decode(RoundResult.self, from: data) else {
                continue
            }
            if await send(result) {
                removeQueuedFile(url)
            }
        }

        for fileName in files(in: pendingSamplesDirectory) {
            let url = pendingSamplesDirectory.appendingPathComponent(fileName)
            guard let data = try? Data(contentsOf: url),
                  let samples = try? decoder.decode([RoundSample].self, from: data),
                  !samples.isEmpty else {
                continue
            }
            if await send(samples) {
                removeQueuedFile(url)
            }
        }
    }

    private func send(_ result: RoundResult) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/rounds"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-Echora-Token")
        do {
            request.httpBody = try encoder.encode(result)
            let (_, response) = try await URLSession.shared.data(for: request)
            return isSuccessful(response)
        } catch {
            return false
        }
    }

    private func send(_ samples: [RoundSample]) async -> Bool {
        guard let first = samples.first else { return false }
        var request = URLRequest(
            url: baseURL.appendingPathComponent("api/rounds/\(first.roundId)/samples")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-Echora-Token")
        do {
            request.httpBody = try encoder.encode(samples)
            let (_, response) = try await URLSession.shared.data(for: request)
            return isSuccessful(response)
        } catch {
            return false
        }
    }

    private func isSuccessful(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        return (200...299).contains(http.statusCode)
    }

    private func files(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)) ?? []
    }

    private func removeQueuedFile(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            print("Unable to remove queued telemetry: \(error)")
        }
    }

    private func createDirectoryIfNeeded(at url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        } catch {
            print("Unable to create telemetry queue: \(error)")
        }
    }
}
