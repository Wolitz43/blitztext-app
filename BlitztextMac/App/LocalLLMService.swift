import Foundation

// Foundation Models ist erst ab macOS 26 verfügbar.
// Wir kapseln alles hinter Availability-Checks, damit die App
// auch auf älteren Systemen kompiliert und läuft.

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Availability

enum LocalLLMAvailability: Equatable {
    case available
    case unavailableDeviceNotEligible
    case unavailableAppleIntelligenceNotEnabled
    case unavailableModelNotReady
    case unavailableUnknown(String)
    case unavailableOSNotSupported
}

// MARK: - Local LLM Service

enum LocalLLMService {

    /// Prüft, ob das On-Device-Modell auf diesem Mac verfügbar ist.
    static func checkAvailability() -> LocalLLMAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                return .available
            case .unavailable(.deviceNotEligible):
                return .unavailableDeviceNotEligible
            case .unavailable(.appleIntelligenceNotEnabled):
                return .unavailableAppleIntelligenceNotEnabled
            case .unavailable(.modelNotReady):
                return .unavailableModelNotReady
            case .unavailable(let reason):
                return .unavailableUnknown("\(reason)")
            @unknown default:
                return .unavailableUnknown("Unbekannter Status")
            }
        } else {
            return .unavailableOSNotSupported
        }
        #else
        return .unavailableOSNotSupported
        #endif
    }

    /// Ob das lokale Modell grundsätzlich nutzbar ist.
    static var isAvailable: Bool {
        checkAvailability() == .available
    }

    /// Lokalisierte Beschreibung des Verfügbarkeits-Status.
    static func availabilityDescription() -> String {
        switch checkAvailability() {
        case .available:
            return "Apple Intelligence ist bereit."
        case .unavailableDeviceNotEligible:
            return "Dieser Mac unterstützt Apple Intelligence nicht (Apple Silicon erforderlich)."
        case .unavailableAppleIntelligenceNotEnabled:
            return "Apple Intelligence ist nicht aktiviert. Bitte in den Systemeinstellungen einschalten."
        case .unavailableModelNotReady:
            return "Das Sprachmodell wird noch heruntergeladen. Bitte warten."
        case .unavailableUnknown(let reason):
            return "Apple Intelligence nicht verfügbar: \(reason)"
        case .unavailableOSNotSupported:
            return "macOS 26 oder neuer wird benötigt."
        }
    }

    // MARK: - Text Generation

    /// Verbessert Text mit dem lokalen Apple-LLM.
    /// Ersetzt `LLMService.improve()` wenn der User den lokalen Modus wählt.
    static func improve(
        text: String,
        systemPrompt: String
    ) async throws -> String {
        try await generate(userText: text, instructions: systemPrompt)
    }

    /// Dampf ablassen – lokale Version.
    static func dampfAblassen(
        text: String,
        systemPrompt: String
    ) async throws -> String {
        try await generate(userText: text, instructions: systemPrompt)
    }

    /// Emojis hinzufügen – lokale Version.
    static func addEmojis(
        text: String,
        systemPrompt: String
    ) async throws -> String {
        try await generate(userText: text, instructions: systemPrompt)
    }

    // MARK: - Core Generation

    private static func generate(
        userText: String,
        instructions: String
    ) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else {
            throw LLMError.apiError(availabilityDescription())
        }

        let availability = checkAvailability()
        guard availability == .available else {
            throw LLMError.apiError(availabilityDescription())
        }

        print("🧠 [LocalLLM] Starte lokale Textgenerierung...")
        print("🧠 [LocalLLM] Text-Länge: \(userText.count) Zeichen")
        print("🧠 [LocalLLM] Anweisungen: \(instructions.prefix(80))...")

        // Vereinfachte Anweisungen verwenden, die weniger wahrscheinlich
        // die Safety Guardrails auslösen
        let safeInstructions = Self.sanitizeInstructions(instructions)

        let session = LanguageModelSession(instructions: safeInstructions)

        do {
            let response = try await session.respond(to: userText)
            let result = response.content.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !result.isEmpty else {
                throw LLMError.noContent
            }

            print("🧠 [LocalLLM] Ergebnis: \(result.count) Zeichen")
            return result
        } catch let error as LanguageModelSession.GenerationError {
            print("🧠 [LocalLLM] GenerationError: \(error)")
            switch error {
            case .guardrailViolation:
                print("⚠️ [LocalLLM] Safety Guardrails ausgelöst!")
                throw LLMError.localModelUnavailable(
                    "Apple Intelligence hat den Text abgelehnt (Sicherheitsfilter). "
                    + "Bitte versuche es mit einer anderen Formulierung, "
                    + "oder wechsle zu OpenAI in den Einstellungen."
                )
            default:
                throw LLMError.apiError("Apple Intelligence Fehler: \(error.localizedDescription)")
            }
        }

        #else
        throw LLMError.apiError(availabilityDescription())
        #endif
    }

    /// Passt die Anweisungen an, damit sie weniger wahrscheinlich
    /// die Safety Guardrails des On-Device-Modells auslösen.
    private static func sanitizeInstructions(_ instructions: String) -> String {
        // Das On-Device-Modell reagiert empfindlich auf Anweisungen,
        // die nach "Manipulation" oder "Umschreiben" klingen.
        // Wir formulieren sie als hilfreiche Assistenz-Aufgabe.
        let prefix = """
        You are a helpful writing assistant. \
        The user will provide text that they wrote themselves. \
        Your job is to help improve their own writing. \
        Always respond with the improved text only, no explanations.

        """
        return prefix + instructions
    }
}
