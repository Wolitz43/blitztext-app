import Foundation

/// Ein einzelner API-Aufruf mit Kosteninformationen.
struct UsageRecord: Codable, Identifiable {
    let id: UUID
    let date: Date
    let workflowType: WorkflowType
    let model: String                    // z.B. "gpt-4o-mini", "whisper-1", "apple-intelligence"
    let backend: LLMBackend
    let promptTokens: Int                // 0 bei Whisper & lokalem Modell
    let completionTokens: Int            // 0 bei Whisper & lokalem Modell
    let audioDurationSeconds: Double     // 0 bei reinen LLM-Aufrufen
    let estimatedCostUSD: Double

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        workflowType: WorkflowType,
        model: String,
        backend: LLMBackend,
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        audioDurationSeconds: Double = 0,
        estimatedCostUSD: Double
    ) {
        self.id = id
        self.date = date
        self.workflowType = workflowType
        self.model = model
        self.backend = backend
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.audioDurationSeconds = audioDurationSeconds
        self.estimatedCostUSD = estimatedCostUSD
    }

    var totalTokens: Int { promptTokens + completionTokens }

    /// Lesbare Zusammenfassung für die UI.
    var summaryDescription: String {
        if audioDurationSeconds > 0 {
            let minutes = audioDurationSeconds / 60
            return String(format: "%.1f Sek. Audio", audioDurationSeconds)
        }
        if totalTokens > 0 {
            return "\(totalTokens) Tokens"
        }
        return "Lokal"
    }
}
