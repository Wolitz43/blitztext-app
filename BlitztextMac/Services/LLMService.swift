import Foundation

enum LLMError: LocalizedError {
    case notConfigured
    case networkError(String)
    case apiError(String)
    case noContent
    case localModelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "OpenAI API Key fehlt. Bitte in den Einstellungen hinterlegen."
        case .networkError(let msg):
            return "Verbindungsproblem: \(msg)"
        case .apiError(let msg):
            return "Fehler von OpenAI: \(msg)"
        case .noContent:
            return "Keine Antwort erhalten. Bitte nochmal versuchen."
        case .localModelUnavailable(let msg):
            return "Lokales Sprachmodell nicht verfügbar: \(msg)"
        }
    }
}

/// Bestimmt, ob OpenAI (Cloud) oder Apple Intelligence (lokal) genutzt wird.
enum LLMBackend: String, Codable, CaseIterable {
    case remote   // OpenAI API
    case local    // Apple On-Device LLM (Foundation Models)

    var displayName: String {
        switch self {
        case .remote: return "OpenAI (Cloud)"
        case .local: return "Apple Intelligence (lokal)"
        }
    }
}

enum RewriteModel: String {
    case fastEdit = "gpt-4o-mini"
    case rageMode = "gpt-4o"
}

private struct OpenAIChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
}

private struct OpenAIChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message?
    }

    let choices: [Choice]?
}

private struct OpenAIErrorResponse: Decodable {
    struct APIError: Decodable {
        let message: String?
    }

    let error: APIError?
}

enum LLMService {
    private static let chatCompletionsURL = URL(string: "https://api.openai.com/v1/chat/completions")!

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 45
        return URLSession(configuration: configuration)
    }()

    static func improve(
        text: String,
        settings: TextImprovementSettings,
        model: RewriteModel = .fastEdit,
        backend: LLMBackend = .remote
    ) async throws -> String {
        let systemPrompt = buildSystemPrompt(settings: settings)
        switch backend {
        case .remote:
            return try await complete(
                text: text,
                systemPrompt: systemPrompt,
                model: model,
                temperature: 0.3
            )
        case .local:
            return try await LocalLLMService.improve(
                text: text,
                systemPrompt: systemPrompt
            )
        }
    }

    static func dampfAblassen(
        text: String,
        systemPrompt: String,
        model: RewriteModel = .rageMode,
        backend: LLMBackend = .remote
    ) async throws -> String {
        switch backend {
        case .remote:
            return try await complete(
                text: text,
                systemPrompt: systemPrompt,
                model: model,
                temperature: 0.4
            )
        case .local:
            return try await LocalLLMService.dampfAblassen(
                text: text,
                systemPrompt: systemPrompt
            )
        }
    }

    static func addEmojis(
        text: String,
        settings: EmojiTextSettings,
        model: RewriteModel = .fastEdit,
        backend: LLMBackend = .remote
    ) async throws -> String {
        let systemPrompt = buildEmojiSystemPrompt(density: settings.emojiDensity)
        switch backend {
        case .remote:
            return try await complete(
                text: text,
                systemPrompt: systemPrompt,
                model: model,
                temperature: 0.3
            )
        case .local:
            return try await LocalLLMService.addEmojis(
                text: text,
                systemPrompt: systemPrompt
            )
        }
    }

    private static func complete(
        text: String,
        systemPrompt: String,
        model: RewriteModel,
        temperature: Double
    ) async throws -> String {
        guard let apiKey = KeychainService.load(key: .openAIAPIKey) else {
            throw LLMError.notConfigured
        }

        // Debug: Log API key format (first 7 chars only for security)
        let keyPrefix = String(apiKey.prefix(7))
        print("🔑 [LLMService] Using API key starting with: \(keyPrefix)... (length: \(apiKey.count))")

        let payload = OpenAIChatRequest(
            model: model.rawValue,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: text),
            ],
            temperature: temperature
        )

        var request = URLRequest(url: chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45
        request.httpBody = try JSONEncoder().encode(payload)

        print("🌐 [LLMService] Sending request to OpenAI API...")
        print("📦 [LLMService] Model: \(model.rawValue), Text length: \(text.count) chars")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            print("❌ [LLMService] Invalid HTTP response")
            throw LLMError.networkError("Keine gültige Antwort")
        }

        print("📡 [LLMService] Response status: \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 else {
            let errorMessage = openAIErrorMessage(from: data) ?? "Status \(httpResponse.statusCode)"
            
            // Debug: Log full error response for debugging
            if let responseString = String(data: data, encoding: .utf8) {
                print("❌ [LLMService] OpenAI error response: \(responseString)")
            }
            
            // Special handling for common errors
            if httpResponse.statusCode == 401 {
                print("🔐 [LLMService] Authentication failed - API key may be invalid")
                throw LLMError.apiError("API-Key ungültig oder abgelaufen. Bitte prüfe deinen OpenAI API Key.")
            } else if httpResponse.statusCode == 429 {
                print("⏱️ [LLMService] Rate limit exceeded")
                throw LLMError.apiError("Zu viele Anfragen. Bitte warte einen Moment.")
            } else if httpResponse.statusCode == 402 {
                print("💳 [LLMService] Insufficient credits")
                throw LLMError.apiError("Keine Credits mehr. Bitte Credits im OpenAI Dashboard aufladen.")
            }
            
            throw LLMError.apiError(errorMessage)
        }

        let result = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
        guard let content = result.choices?.first?.message?.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.noContent
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func openAIErrorMessage(from data: Data) -> String? {
        (try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data))?.error?.message
    }

    private static func buildEmojiSystemPrompt(density: EmojiTextSettings.EmojiDensity) -> String {
        let densityInstruction: String
        switch density {
        case .wenig:
            densityInstruction = "Setze nur vereinzelt Emojis ein, maximal 1-2 pro Absatz."
        case .mittel:
            densityInstruction = "Setze regelmaessig passende Emojis ein, etwa alle 1-2 Saetze."
        case .viel:
            densityInstruction = "Setze grosszuegig Emojis ein, gerne mehrere pro Satz."
        }

        return "Du erhaeltst ein gesprochenes Transkript. Gib den Text moeglichst originalgetreu zurueck, aber fuege passende Emojis ein. \(densityInstruction) Korrigiere offensichtliche Sprach- und Grammatikfehler. Behalte den Stil und die Bedeutung bei. Gib NUR den Text mit Emojis zurueck, keine Erklaerungen."
    }

    private static func buildSystemPrompt(settings: TextImprovementSettings) -> String {
        if !settings.systemPrompt.isEmpty {
            var prompt = settings.systemPrompt
            if !settings.customTerms.isEmpty {
                prompt += "\n\nWichtig: Diese Eigennamen und Fachbegriffe muessen exakt so geschrieben werden: \(settings.customTerms.joined(separator: ", "))"
            }
            return prompt
        }

        var prompt = """
        Du bist ein Lektor und Schreibassistent. Verbessere den folgenden Text:
        - Korrigiere Rechtschreibung und Grammatik
        - Verbessere die Formulierung und den Lesefluss
        - Behalte die urspruengliche Bedeutung bei
        - Gib NUR den verbesserten Text zurueck, keine Erklaerungen
        """

        switch settings.tone {
        case .formal:
            prompt += "\n- Verwende einen formellen, professionellen Ton"
        case .neutral:
            prompt += "\n- Verwende einen neutralen, klaren Ton"
        case .casual:
            prompt += "\n- Verwende einen lockeren, natuerlichen Ton"
        }

        if !settings.customTerms.isEmpty {
            prompt += "\n\nWichtig: Diese Eigennamen und Fachbegriffe muessen exakt so geschrieben werden: \(settings.customTerms.joined(separator: ", "))"
        }

        if !settings.context.isEmpty {
            prompt += "\n\nKontext: \(settings.context)"
        }

        return prompt
    }
}
