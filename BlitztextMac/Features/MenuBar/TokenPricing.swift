import Foundation

/// Zentrale Preistabelle für alle API-Aufrufe (Stand Juli 2026).
/// Alle Preise in USD.
enum TokenPricing {

    // MARK: - Token-Preise (pro Token)

    static func inputCostPerToken(model: String) -> Double {
        switch model {
        case "gpt-4o-mini": return 0.15 / 1_000_000
        case "gpt-4o":      return 2.50 / 1_000_000
        default:            return 0
        }
    }

    static func outputCostPerToken(model: String) -> Double {
        switch model {
        case "gpt-4o-mini": return 0.60 / 1_000_000
        case "gpt-4o":      return 10.00 / 1_000_000
        default:            return 0
        }
    }

    // MARK: - Audio-Preis (pro Sekunde)

    /// Whisper-1: $0.006 pro Minute → umgerechnet pro Sekunde
    static let whisperCostPerSecond: Double = 0.006 / 60.0

    // MARK: - Kosten berechnen

    static func cost(
        model: String,
        promptTokens: Int,
        completionTokens: Int,
        audioDurationSeconds: Double
    ) -> Double {
        // Lokale Modelle sind immer kostenlos
        guard model != "apple-intelligence", model != "whisperkit" else { return 0 }

        if audioDurationSeconds > 0 {
            return audioDurationSeconds * whisperCostPerSecond
        }

        let inputCost  = Double(promptTokens)     * inputCostPerToken(model: model)
        let outputCost = Double(completionTokens) * outputCostPerToken(model: model)
        return inputCost + outputCost
    }

    // MARK: - Hypothetische Remote-Kosten (für Ersparnis-Berechnung)

    /// Was ein lokaler Aufruf als Remote-Äquivalent gekostet hätte.
    static func hypotheticalRemoteCost(for record: UsageRecord) -> Double {
        guard record.backend == .local else { return 0 }

        if record.audioDurationSeconds > 0 {
            // WhisperKit lokal → Äquivalent wäre whisper-1
            return record.audioDurationSeconds * whisperCostPerSecond
        }

        // Apple Intelligence → Äquivalent wäre gpt-4o-mini
        let inputCost  = Double(record.promptTokens)     * inputCostPerToken(model: "gpt-4o-mini")
        let outputCost = Double(record.completionTokens) * outputCostPerToken(model: "gpt-4o-mini")

        // Falls keine Token-Daten vorhanden (Apple Intelligence trackt keine Tokens),
        // schätzen wir einen Durchschnittswert von 300 Tokens gesamt.
        if inputCost + outputCost == 0 {
            return 300 * inputCostPerToken(model: "gpt-4o-mini")
        }

        return inputCost + outputCost
    }

    // MARK: - Formatierung

    static func format(_ usd: Double) -> String {
        if usd == 0 { return "$0.00" }
        if usd < 0.001 { return String(format: "$%.5f", usd) }
        if usd < 0.01  { return String(format: "$%.4f", usd) }
        return String(format: "$%.3f", usd)
    }

    static func formatCent(_ usd: Double) -> String {
        if usd == 0 { return "0 ¢" }
        let cent = usd * 100
        if cent < 0.1  { return String(format: "%.4f ¢", cent) }
        if cent < 1.0  { return String(format: "%.3f ¢", cent) }
        return String(format: "%.2f ¢", cent)
    }
}
