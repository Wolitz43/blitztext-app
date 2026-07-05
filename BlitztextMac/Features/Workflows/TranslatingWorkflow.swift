import Foundation
import Observation

@Observable
@MainActor
final class TranslatingWorkflow: Workflow {
    private let inner: any Workflow
    private let settings: TranslationStepSettings
    private let llmBackend: LLMBackend
    private var translationTask: Task<Void, Never>?

    var phase: WorkflowPhase = .idle {
        didSet { onPhaseChange?(phase) }
    }
    var onOutput: WorkflowOutputHandler?
    var onPhaseChange: WorkflowPhaseChangeHandler?
    var onUsage: WorkflowUsageHandler?

    var type: WorkflowType { inner.type }
    var isRecording: Bool { inner.isRecording }
    var audioLevel: Float { inner.audioLevel }

    init(inner: any Workflow, settings: TranslationStepSettings, llmBackend: LLMBackend) {
        self.inner = inner
        self.settings = settings
        self.llmBackend = llmBackend

        inner.onPhaseChange = { [weak self] phase in
            self?.handleInnerPhaseChange(phase)
        }
        inner.onUsage = { [weak self] record in
            self?.onUsage?(record)
        }
    }

    // MARK: - Workflow Protocol

    func start() {
        inner.start()
    }

    func stop() {
        inner.stop()
    }

    func reset() {
        translationTask?.cancel()
        inner.reset()
    }

    // MARK: - Interception

    private func handleInnerPhaseChange(_ innerPhase: WorkflowPhase) {
        guard case .done(let text) = innerPhase else {
            phase = innerPhase
            return
        }
        translate(text)
    }

    private func translate(_ originalText: String) {
        phase = .running("Wird übersetzt ...")
        let stepSettings = settings
        let backend = llmBackend
        let workflowType = type

        translationTask = Task {
            do {
                let systemPrompt = Self.buildTranslationPrompt(settings: stepSettings)
                let (translated, llmUsage) = try await LLMService.translate(
                    text: originalText,
                    systemPrompt: systemPrompt,
                    backend: backend
                )
                guard !Task.isCancelled else { return }
                let llmCost = TokenPricing.cost(
                    model: llmUsage.model,
                    promptTokens: llmUsage.promptTokens,
                    completionTokens: llmUsage.completionTokens,
                    audioDurationSeconds: 0
                )
                let llmRecord = UsageRecord(
                    workflowType: workflowType,
                    model: llmUsage.model,
                    backend: llmUsage.backend,
                    promptTokens: llmUsage.promptTokens,
                    completionTokens: llmUsage.completionTokens,
                    estimatedCostUSD: llmCost
                )
                onUsage?(llmRecord)

                let cleanedTranslation = TranscriptionQualityService.cleanedTranscript(translated)
                phase = .done(cleanedTranslation)
                onOutput?(cleanedTranslation)
            } catch {
                guard !Task.isCancelled else { return }
                // Übersetzung fehlgeschlagen: Originaltext nicht verwerfen, direkt als
                // fertiges Ergebnis melden (kein .error-Zwischenschritt, siehe
                // "Abweichung von der Spec" in den Global Constraints).
                phase = .done(originalText)
                onOutput?(originalText)
            }
        }
    }

    private static func buildTranslationPrompt(settings: TranslationStepSettings) -> String {
        let targetLang = settings.targetLanguage.englishName

        let toneInstruction: String
        switch settings.tone {
        case .formal:
            toneInstruction = "Use a formal, professional tone."
        case .neutral:
            toneInstruction = "Use a neutral, clear tone."
        case .casual:
            toneInstruction = "Use a casual, natural tone."
        }

        var prompt = """
        You are a professional translator.
        Translate the following text into \(targetLang).
        - Use natural, idiomatic \(targetLang)
        - Preserve the meaning and style
        - \(toneInstruction)
        - Return ONLY the translation, no explanations
        """

        if !settings.context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "\n\nContext: \(settings.context)"
        }

        return prompt
    }
}
