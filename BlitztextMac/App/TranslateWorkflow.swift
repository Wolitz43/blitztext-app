import Foundation
import AppKit
import Observation

@Observable
@MainActor
final class TranslateWorkflow: Workflow {
    let type = WorkflowType.translate
    var phase: WorkflowPhase = .idle {
        didSet { onPhaseChange?(phase) }
    }
    var onOutput: WorkflowOutputHandler?
    var onPhaseChange: WorkflowPhaseChangeHandler?
    var onUsage: WorkflowUsageHandler?

    private let recorder = AudioRecorder()
    private let settings: TranslateSettings
    private let customTerms: [String]
    private let language: String
    private let llmBackend: LLMBackend
    private let transcriptionBackend: TranscriptionBackend
    private let localModelName: String
    private var processingTask: Task<Void, Never>?

    init(
        settings: TranslateSettings,
        customTerms: [String] = [],
        language: String = "de",
        llmBackend: LLMBackend = .remote,
        transcriptionBackend: TranscriptionBackend = .remote,
        localModelName: String = LocalTranscriptionService.recommendedFastModelName
    ) {
        self.settings = settings
        self.customTerms = customTerms
        self.language = language
        self.llmBackend = llmBackend
        self.transcriptionBackend = transcriptionBackend
        self.localModelName = localModelName
    }

    // MARK: - Recording State

    var isRecording: Bool { recorder.isRecording }
    var audioLevel: Float { recorder.audioLevel }

    // MARK: - Workflow Protocol

    func start() {
        phase = .running("Aufnahme läuft ...")
        recorder.startRecording()

        if let error = recorder.errorMessage {
            phase = .error(error)
        }
    }

    func stop() {
        if recorder.isRecording {
            recorder.stopRecording()
            guard !TranscriptionQualityService.shouldRejectRecording(duration: recorder.lastRecordingDuration) else {
                recorder.discardRecording()
                phase = .error("Keine Aufnahme erkannt.")
                return
            }
            processRecording()
        } else {
            processingTask?.cancel()
            phase = .idle
        }
    }

    func reset() {
        processingTask?.cancel()
        if recorder.isRecording {
            recorder.stopRecording()
        }
        recorder.discardRecording()
        phase = .idle
    }

    // MARK: - Two-Phase Processing: Whisper → Übersetzen

    private func processRecording() {
        guard let url = recorder.recordingURL else {
            phase = .error("Keine Aufnahme vorhanden.")
            return
        }

        phase = .running("Wird transkribiert ...")
        let recordingDuration = recorder.lastRecordingDuration
        let vocabularyHints = recordingDuration >= 0.9 ? customTerms : []
        let currentSettings = settings

        processingTask = Task {
            defer {
                try? FileManager.default.removeItem(at: url)
            }

            do {
                // Phase 1: Transkription (lokal oder remote)
                let rawText: String
                switch transcriptionBackend {
                case .local:
                    rawText = try await LocalTranscriptionService.shared.transcribe(
                        audioURL: url,
                        language: language,
                        modelName: localModelName
                    )
                    let record = UsageRecord(
                        workflowType: type,
                        model: "whisperkit",
                        backend: .local,
                        audioDurationSeconds: recordingDuration,
                        estimatedCostUSD: 0
                    )
                    onUsage?(record)
                case .remote:
                    let (transcribed, usageInfo) = try await TranscriptionService.transcribe(
                        audioURL: url,
                        customTerms: vocabularyHints,
                        language: language
                    )
                    rawText = transcribed
                    let cost = TokenPricing.cost(
                        model: usageInfo.model,
                        promptTokens: 0,
                        completionTokens: 0,
                        audioDurationSeconds: usageInfo.audioDurationSeconds
                    )
                    let record = UsageRecord(
                        workflowType: type,
                        model: usageInfo.model,
                        backend: .remote,
                        audioDurationSeconds: usageInfo.audioDurationSeconds,
                        estimatedCostUSD: cost
                    )
                    onUsage?(record)
                }

                let cleanedRawText = TranscriptionQualityService.cleanedTranscript(rawText)
                guard !TranscriptionQualityService.isLikelyArtifact(cleanedRawText, recordingDuration: recordingDuration) else {
                    phase = .error("Keine Aufnahme erkannt.")
                    return
                }

                if Task.isCancelled { return }

                // Phase 2: Übersetzen
                phase = .running("Wird übersetzt ...")

                let systemPrompt = buildTranslationPrompt(settings: currentSettings)
                let (translated, llmUsage) = try await LLMService.translate(
                    text: cleanedRawText,
                    systemPrompt: systemPrompt,
                    backend: llmBackend
                )
                let llmCost = TokenPricing.cost(
                    model: llmUsage.model,
                    promptTokens: llmUsage.promptTokens,
                    completionTokens: llmUsage.completionTokens,
                    audioDurationSeconds: 0
                )
                let llmRecord = UsageRecord(
                    workflowType: type,
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
                phase = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - System Prompt

    private func buildTranslationPrompt(settings: TranslateSettings) -> String {
        let targetLang = settings.targetLanguage.englishName

        var toneInstruction: String
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
