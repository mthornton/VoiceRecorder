import Foundation

/// A model the user can pick in Settings.
///
/// These ids were verified against OpenRouter's live `/api/v1/models` catalog.
/// The catalog changes, so Settings also accepts a free-text id — this list is a
/// convenience, not a constraint.
struct CuratedModel: Identifiable, Hashable {
    let id: String
    let name: String
    let note: String

    static let all: [CuratedModel] = [
        CuratedModel(
            id: "google/gemini-2.5-flash",
            name: "Gemini 2.5 Flash",
            note: "Fast and cheap. Good default."
        ),
        CuratedModel(
            id: "openai/gpt-5-mini",
            name: "GPT-5 mini",
            note: "Cheapest of these. Solid quality."
        ),
        CuratedModel(
            id: "anthropic/claude-haiku-4.5",
            name: "Claude Haiku 4.5",
            note: "Fast, strong at structured output."
        ),
        CuratedModel(
            id: "anthropic/claude-sonnet-4.5",
            name: "Claude Sonnet 4.5",
            note: "Highest quality. Costs more."
        ),
    ]

    static let defaultID = "google/gemini-2.5-flash"

    static func name(forID id: String) -> String {
        all.first { $0.id == id }?.name ?? id
    }
}

/// Models that accept audio input, for speaker-aware transcription.
///
/// Only a subset of OpenRouter's catalog takes audio at all, so this is a
/// separate list from the summarization models — picking a text-only model here
/// would fail every transcription. Ids verified against `/api/v1/models`
/// filtered by `input_modalities` containing `audio`.
struct CuratedTranscriptionModel: Identifiable, Hashable {
    let id: String
    let name: String
    let note: String

    static let all: [CuratedTranscriptionModel] = [
        CuratedTranscriptionModel(
            id: "google/gemini-2.5-flash",
            name: "Gemini 2.5 Flash",
            note: "Roughly a cent per hour. Good default."
        ),
        CuratedTranscriptionModel(
            id: "google/gemini-2.5-flash-lite",
            name: "Gemini 2.5 Flash Lite",
            note: "Cheapest. Weaker on difficult audio."
        ),
        CuratedTranscriptionModel(
            id: "google/gemini-2.5-pro",
            name: "Gemini 2.5 Pro",
            note: "Best with crosstalk and many speakers."
        ),
        CuratedTranscriptionModel(
            id: "openai/gpt-audio-mini",
            name: "GPT Audio Mini",
            note: "Alternative if Gemini struggles."
        ),
    ]

    static let defaultID = "google/gemini-2.5-flash"

    static func name(forID id: String) -> String {
        all.first { $0.id == id }?.name ?? id
    }
}

enum OpenRouterError: LocalizedError {
    case missingKey
    case invalidKey
    case rateLimited
    case insufficientCredit
    case http(Int, String)
    case emptyResponse
    case network(String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No OpenRouter API key. Add one in Settings."
        case .invalidKey:
            return "OpenRouter rejected the API key. Check it in Settings."
        case .rateLimited:
            return "OpenRouter is rate limiting requests. Try again shortly."
        case .insufficientCredit:
            return "Your OpenRouter account is out of credit."
        case .http(let code, let message):
            return message.isEmpty ? "OpenRouter returned HTTP \(code)." : message
        case .emptyResponse:
            return "The model returned an empty response."
        case .network(let detail):
            return detail
        }
    }
}

/// Minimal OpenRouter chat-completions client.
struct OpenRouterClient: Sendable {
    struct Message: Codable, Sendable {
        let role: String
        let content: String
    }

    private let baseURL = URL(string: "https://openrouter.ai/api/v1")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Checks a key against OpenRouter's key-info endpoint, so Settings can
    /// verify before the user relies on it. Returns the key's label if it has one.
    func validate(apiKey: String) async throws -> String? {
        var request = URLRequest(url: baseURL.appendingPathComponent("key"))
        request.httpMethod = "GET"
        applyHeaders(to: &request, apiKey: apiKey)

        let (data, response) = try await perform(request)
        try Self.checkStatus(response, data: data)

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = root["data"] as? [String: Any] else { return nil }
        return info["label"] as? String
    }

    /// Sends a chat completion and returns the assistant's text content.
    func complete(
        model: String,
        messages: [Message],
        apiKey: String,
        maxTokens: Int = 4096
    ) async throws -> String {
        try await send(
            model: model,
            messages: messages.map { ["role": $0.role, "content": $0.content] },
            apiKey: apiKey,
            maxTokens: maxTokens,
            timeout: 180
        )
    }

    /// Sends audio alongside a text instruction, for models that accept audio
    /// input. Used for speaker-aware transcription.
    ///
    /// OpenRouter takes audio as base64 inline in the request body — there is no
    /// URL or upload endpoint — which is why callers must downsample and chunk
    /// before getting here.
    func completeWithAudio(
        model: String,
        systemPrompt: String,
        userPrompt: String,
        audio: Data,
        audioFormat: String,
        apiKey: String,
        maxTokens: Int = 16_384
    ) async throws -> String {
        let content: [[String: Any]] = [
            ["type": "text", "text": userPrompt],
            [
                "type": "input_audio",
                "input_audio": [
                    "data": audio.base64EncodedString(),
                    "format": audioFormat,
                ],
            ],
        ]

        return try await send(
            model: model,
            messages: [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": content],
            ],
            apiKey: apiKey,
            maxTokens: maxTokens,
            // Uploading and transcribing a 15-minute chunk is slow; this is
            // generous on purpose so a normal run doesn't get killed mid-flight.
            timeout: 600
        )
    }

    private func send(
        model: String,
        messages: [[String: Any]],
        apiKey: String,
        maxTokens: Int,
        timeout: TimeInterval
    ) async throws -> String {
        guard !apiKey.isEmpty else { throw OpenRouterError.missingKey }

        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        applyHeaders(to: &request, apiKey: apiKey)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": maxTokens,
            "temperature": 0.2,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await perform(request)
        try Self.checkStatus(response, data: data)

        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String,
            !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw OpenRouterError.emptyResponse
        }

        return content
    }

    // MARK: - Plumbing

    private func applyHeaders(to request: inout URLRequest, apiKey: String) {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // OpenRouter uses these for attribution on its dashboard.
        request.setValue("https://github.com/mthornton/VoiceRecorder", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Voice Recorder", forHTTPHeaderField: "X-Title")
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw OpenRouterError.network("No internet connection.")
        } catch let error as URLError where error.code == .timedOut {
            throw OpenRouterError.network("The request to OpenRouter timed out.")
        } catch {
            throw OpenRouterError.network(error.localizedDescription)
        }
    }

    private static func checkStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200...299).contains(http.statusCode) else { return }

        // OpenRouter puts a human-readable reason in {"error":{"message":...}}.
        var message = ""
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = root["error"] as? [String: Any],
           let text = error["message"] as? String {
            message = text
        }

        switch http.statusCode {
        case 401, 403: throw OpenRouterError.invalidKey
        case 402: throw OpenRouterError.insufficientCredit
        case 429: throw OpenRouterError.rateLimited
        default: throw OpenRouterError.http(http.statusCode, message)
        }
    }
}
