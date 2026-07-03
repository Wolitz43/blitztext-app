import Foundation
import AppKit
import Observation

@Observable
@MainActor
final class TextImprovementWorkflow: Workflow {
    let type = WorkflowType.textImprover
    var phase: WorkflowPhase = .idle {
        didSet { onPhaseChange?(phase) }
    }
    var onOutput: WorkflowOutputHandler?
    var onPhaseChange: WorkflowPhaseChangeHandler?
    var onUsage: WorkflowUsageHandler?

    private let recorder = AudioRecorder()
    private let settings: TextImprovementSettings
    private let language: String
    private let llmBackend: LLMBackend
    private let transcriptionBackend: TranscriptionBackend
    private let localModelName: String
    private var processingTask: Task<Void, Never>?

    init(
        settings: TextImprovementSettings,
        language: String = "de",
        llmBackend: LLMBackend = .remote,
        transcriptionBackend: TranscriptionBackend = .remote,
        localModelName: String = LocalTranscriptionService.recommendedFastModelName
    ) {
        self.settings = settings
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

    // MARK: - Two-Phase Processing: Whisper -> GPT

    private func processRecording() {
        guard let url = recorder.recordingURL else {
            phase = .error("Keine Aufnahme vorhanden.")
            return
        }

        phase = .running("Wird transkribiert ...")
        let recordingDuration = recorder.lastRecordingDuration
        let vocabularyHints = recordingDuration >= 0.9 ? settings.customTerms : []

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

                // Phase 2: GPT improvement
                phase = .running("Text wird verbessert ...")

                let (improved, llmUsage) = try await LLMService.improve(
                    text: cleanedRawText,
                    settings: settings,
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

                let cleanedImproved = TranscriptionQualityService.cleanedTranscript(improved)
                phase = .done(cleanedImproved)
                onOutput?(cleanedImproved)
            } catch {
                phase = .error(error.localizedDescription)
            }
        }
    }
}
