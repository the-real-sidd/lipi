import Foundation

/// Optional "AI cleanup" with Google Gemini, using the user's own free API key from AI Studio.
/// Only text is sent (never audio). Every call has a short timeout, and the caller falls back
/// to the on-device pipeline on any failure, so dictation never gets stuck on the network.
@MainActor
final class AIService: ObservableObject {
    static let shared = AIService()
    static let keyPage = URL(string: "https://aistudio.google.com/app/apikey")!

    enum Status: Equatable { case off, checking, ready(String), failed(String) }
    @Published private(set) var status: Status = .off
    @Published private(set) var hasKey = false

    private let host = "https://generativelanguage.googleapis.com/v1beta"
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.httpMaximumConnectionsPerHost = 2
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
    private var lastWarm = Date.distantPast

    private init() {
        hasKey = Keychain.read() != nil
        if hasKey { status = .ready(Settings.shared.aiModel) }
    }

    var isEnabled: Bool { hasKey && Settings.shared.aiEnabled }

    // MARK: Key management

    /// Saves a key from the clipboard (or given text) after checking it works.
    func connect(with raw: String) async -> Bool {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= 30, key.count <= 80, !key.contains(" ") else {
            status = .failed("That doesn't look like a Gemini API key. Copy it from AI Studio and try again.")
            return false
        }
        status = .checking
        do {
            let model = try await pickModel(key: key)
            Keychain.save(key)
            Settings.shared.aiModel = model
            Settings.shared.aiEnabled = true
            hasKey = true
            status = .ready(model)
            return true
        } catch {
            status = .failed(error.localizedDescription)
            return false
        }
    }

    func disconnect() {
        Keychain.delete()
        hasKey = false
        status = .off
    }

    func availableModels(key: String) async throws -> [String] {
        var request = URLRequest(url: URL(string: "\(host)/models?pageSize=200")!)
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw AIError.http(code, Self.message(from: data)) }
        struct List: Decodable { struct M: Decodable { let name: String; let supportedGenerationMethods: [String]? }; let models: [M]? }
        return (try JSONDecoder().decode(List.self, from: data).models ?? [])
            .filter { $0.supportedGenerationMethods?.contains("generateContent") ?? true }
            .map { $0.name.replacingOccurrences(of: "models/", with: "") }
    }

    /// Picks the newest stable "flash-lite" model (fastest), else the newest "flash". Google
    /// retires model names over time, so this never relies on a fixed list.
    private func pickModel(key: String) async throws -> String {
        let names = try await availableModels(key: key)
        func newest(_ pattern: String) -> String? {
            let rx = try! NSRegularExpression(pattern: pattern)
            return names.compactMap { name -> (Double, String)? in
                guard let m = rx.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                      let r = Range(m.range(at: 1), in: name), let v = Double(name[r]) else { return nil }
                return (v, name)
            }
            .max { $0.0 < $1.0 }?.1
        }
        if let m = newest(#"^gemini-(\d+(?:\.\d+)?)-flash-lite$"#) { return m }
        if names.contains("gemini-flash-lite-latest") { return "gemini-flash-lite-latest" }
        if let m = newest(#"^gemini-(\d+(?:\.\d+)?)-flash$"#) { return m }
        if names.contains("gemini-flash-latest") { return "gemini-flash-latest" }
        if let m = newest(#"^gemini-(\d+(?:\.\d+)?)-flash-lite-preview.*$"#) { return m }
        if let any = names.first(where: { $0.contains("flash") && !$0.contains("image") && !$0.contains("tts") && !$0.contains("live") && !$0.contains("audio") }) { return any }
        throw AIError.noModel
    }

    /// When Google retires a model mid-use, switch to the one it suggests (or the newest) once.
    private func recover(from message: String, key: String) async -> Bool {
        guard message.localizedCaseInsensitiveContains("no longer available") || message.localizedCaseInsensitiveContains("not found")
                || message.localizedCaseInsensitiveContains("deprecated") else { return false }
        var next: String?
        if let r = message.range(of: #"models/(gemini-[A-Za-z0-9.\-]+)"#, options: .regularExpression, range: message.index(message.startIndex, offsetBy: min(40, message.count))..<message.endIndex) {
            next = String(message[r]).replacingOccurrences(of: "models/", with: "")
        }
        if next == nil || next == Settings.shared.aiModel { next = try? await pickModel(key: key) }
        guard let next, next != Settings.shared.aiModel else { return false }
        Log.write("AI model \(Settings.shared.aiModel) retired, switching to \(next)")
        Settings.shared.aiModel = next
        status = .ready(next)
        return true
    }

    /// Gemini 3+ models think before answering unless told not to; dictation needs speed.
    private func thinkingConfig(for model: String) -> [String: Any]? {
        if Settings.shared.aiThinkingUnsupported { return nil }
        if model.contains("2.5-flash") && !model.contains("lite") { return ["thinkingBudget": 0] }
        if let major = Double(model.split(separator: "-").dropFirst().first ?? ""), major >= 3 { return ["thinkingLevel": "minimal"] }
        return nil
    }

    // MARK: Requests

    /// Opens the HTTPS connection while you're still speaking, so the real request skips the
    /// TLS handshake (saves ~200 ms).
    func warmUp() {
        guard isEnabled, Date().timeIntervalSince(lastWarm) > 20, let key = Keychain.read() else { return }
        lastWarm = Date()
        var request = URLRequest(url: URL(string: "\(host)/models/\(Settings.shared.aiModel)")!)
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        session.dataTask(with: request).resume()
    }

    struct Example { let input: String; let output: String }

    /// One-shot text generation. Throws on anything unexpected so callers can fall back.
    func generate(system: String, examples: [Example], input: String, maxTokens: Int, timeout: TimeInterval) async throws -> String {
        guard isEnabled, let key = Keychain.read() else { throw AIError.notConfigured }
        let started = Date()
        do {
            return try await request(system: system, examples: examples, input: input, maxTokens: maxTokens, timeout: timeout, key: key)
        } catch AIError.http(let code, let message) {
            let left = timeout - Date().timeIntervalSince(started)
            guard left > 1 else { throw AIError.http(code, message) }
            if code == 400, message.localizedCaseInsensitiveContains("thinking") {
                Settings.shared.aiThinkingUnsupported = true
            } else if !(await recover(from: message, key: key)) {
                throw AIError.http(code, message)
            }
            return try await request(system: system, examples: examples, input: input, maxTokens: maxTokens, timeout: left, key: key)
        }
    }

    private func request(system: String, examples: [Example], input: String, maxTokens: Int, timeout: TimeInterval, key: String) async throws -> String {
        let model = Settings.shared.aiModel
        var contents: [[String: Any]] = []
        for e in examples {
            contents.append(["role": "user", "parts": [["text": e.input]]])
            contents.append(["role": "model", "parts": [["text": e.output]]])
        }
        contents.append(["role": "user", "parts": [["text": input]]])
        var generation: [String: Any] = ["temperature": 0.1, "maxOutputTokens": maxTokens]
        if let thinking = thinkingConfig(for: model) { generation["thinkingConfig"] = thinking }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": contents,
            "generationConfig": generation,
        ]
        var request = URLRequest(url: URL(string: "\(host)/models/\(model):generateContent")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let message = Self.message(from: data)
            if (code == 401 || code == 403 || message.contains("isn't valid")) { status = .failed(message) }
            throw AIError.http(code, message)
        }
        struct Reply: Decodable {
            struct Candidate: Decodable { struct Content: Decodable { struct Part: Decodable { let text: String? }; let parts: [Part]? }; let content: Content?; let finishReason: String? }
            let candidates: [Candidate]?
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        let text = reply.candidates?.first?.content?.parts?.compactMap(\.text).joined() ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIError.empty }
        if case .failed = status { status = .ready(model) }
        return trimmed
    }

    private static func message(from data: Data) -> String {
        struct E: Decodable { struct Inner: Decodable { let message: String? }; let error: Inner? }
        let raw = (try? JSONDecoder().decode(E.self, from: data))?.error?.message ?? ""
        if raw.localizedCaseInsensitiveContains("API key not valid") { return "This API key isn't valid. Create a new one in AI Studio." }
        if raw.localizedCaseInsensitiveContains("quota") { return "Gemini's free limit was reached for now. Lipi uses on-device cleanup until it resets." }
        return raw.isEmpty ? "Gemini didn't respond." : raw
    }

    enum AIError: LocalizedError {
        case notConfigured, noModel, empty, http(Int, String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: "AI cleanup isn't set up."
            case .noModel: "This key can't use any Gemini text model."
            case .empty: "Gemini returned nothing."
            case .http(_, let message): message
            }
        }
    }
}

/// The API key is stored in a private file (permissions 600, readable only by your macOS user),
/// like `gh` and other developer tools do. Lipi never uses the login Keychain: it trusts only the
/// exact build that saved an item and asks for your Mac password after every update.
enum Keychain {
    private static let url = PersonalDictionary.url.deletingLastPathComponent().appendingPathComponent(".gemini-key")
    private static var cached: String??

    static func save(_ value: String) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(value.utf8), attributes: [.posixPermissions: 0o600])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        cached = .some(value)
    }

    static func read() -> String? {
        if let cached { return cached }
        let value = (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = (value?.isEmpty ?? true) ? nil : value
        cached = .some(result)
        return result
    }

    static func delete() {
        try? FileManager.default.removeItem(at: url)
        cached = .some(nil)
    }
}
