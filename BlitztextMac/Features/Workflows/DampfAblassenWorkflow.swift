import Foundation
import AppKit
import Observation

@Observable
@MainActor
final class DampfAblassenWorkflow: Workflow {
    let type = WorkflowType.dampfAblassen
    var phase: WorkflowPhase = .idle {
        didSet { onPhaseChange?(phase) }
    }
    var onOutput: WorkflowOutputHandler?
    var onPhaseChange: WorkflowPhaseChangeHandler?
    var onUsage: WorkflowUsageHandler?

    private let recorder = AudioRecorder()
    private let settings: DampfAblassenSettings
    private let customTerms: [String]
    private let language: String
    private let microphoneID: String?
    private let llmBackend: LLMBackend
    private let transcriptionBackend: TranscriptionBackend
    private let localModelName: String
    private var processingTask: Task<Void, Never>?

    init(
        settings: DampfAblassenSettings,
        customTerms: [String] = [],
        language: String = "de",
        microphoneID: String? = nil,
        llmBackend: LLMBackend = .remote,
        transcriptionBackend: TranscriptionBackend = .remote,
        localModelName: String = LocalTranscriptionService.recommendedFastModelName
    ) {
        self.settings = settings
        self.customTerms = customTerms
        self.language = language
        self.microphoneID = microphoneID
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
        recorder.startRecording(preferredDeviceID: microphoneID)

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

    // MARK: - Two-Phase Processing: Whisper -> GPT Rage Mode

    private func processRecording() {
        guard let url = recorder.recordingURL else {
            phase = .error("Keine Aufnahme vorhanden.")
            return
        }

        phase = .running("Wird transkribiert ...")
        let recordingDuration = recorder.lastRecordingDuration
        let vocabularyHints = recordingDuration >= 0.9 ? customTerms : []

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

                // Phase 2: GPT dampf ablassen
                phase = .running("Wird umformuliert ...")

                let (answer, llmUsage) = try await LLMService.dampfAblassen(
                    text: cleanedRawText,
                    systemPrompt: settings.systemPrompt,
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

                let cleanedAnswer = TranscriptionQualityService.cleanedTranscript(answer)
                guard cleanedAnswer != "KEINE_AUFNAHME_ERKANNT" else {
                    phase = .error("Keine Aufnahme erkannt.")
                    return
                }
                phase = .done(cleanedAnswer)
                onOutput?(cleanedAnswer)
            } catch {
                phase = .error(error.localizedDescription)
            }
        }
    }
}
