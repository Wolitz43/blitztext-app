import AVFoundation
import Observation

struct MicrophoneDevice: Identifiable, Equatable {
    let id: String      // AVCaptureDevice.uniqueID
    let name: String    // AVCaptureDevice.localizedName
}

@Observable
final class AudioRecorder: NSObject, AVCaptureFileOutputRecordingDelegate {
    var isRecording = false
    var recordingURL: URL?
    var errorMessage: String?
    var audioLevel: Float = 0
    var lastRecordingDuration: TimeInterval = 0

    private var session: AVCaptureSession?
    private var fileOutput: AVCaptureAudioFileOutput?
    private var levelTimer: Timer?
    private var currentFileURL: URL?
    private var finalizationSemaphore: DispatchSemaphore?

    private enum RecorderError: LocalizedError {
        case cannotAddInput
        case cannotAddOutput

        var errorDescription: String? {
            switch self {
            case .cannotAddInput:  return "Mikrofon-Eingang konnte nicht hinzugefügt werden."
            case .cannotAddOutput: return "Audio-Ausgabe konnte nicht hinzugefügt werden."
            }
        }
    }

    // MARK: - Geräte

    static func availableMicrophones() -> [MicrophoneDevice] {
        discoverySession().devices.map {
            MicrophoneDevice(id: $0.uniqueID, name: $0.localizedName)
        }
    }

    private static func discoverySession() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
    }

    private static func resolveDevice(preferredDeviceID: String?) -> AVCaptureDevice? {
        if let preferredDeviceID,
           let match = discoverySession().devices.first(where: { $0.uniqueID == preferredDeviceID }) {
            return match
        }
        // Stiller Fallback: gewähltes Gerät fehlt oder keins gewählt → System-Standard.
        return AVCaptureDevice.default(for: .audio)
    }

    private func makeRecordingURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("blitztext-\(UUID().uuidString).m4a")
    }

    // MARK: - Aufnahme

    func startRecording(preferredDeviceID: String? = nil) {
        errorMessage = nil
        lastRecordingDuration = 0
        recordingURL = nil
        if let currentFileURL {
            try? FileManager.default.removeItem(at: currentFileURL)
        }

        guard let device = Self.resolveDevice(preferredDeviceID: preferredDeviceID) else {
            errorMessage = "Kein Mikrofon gefunden."
            return
        }

        let session = AVCaptureSession()
        let output = AVCaptureAudioFileOutput()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw RecorderError.cannotAddInput }
            session.addInput(input)
            guard session.canAddOutput(output) else { throw RecorderError.cannotAddOutput }
            session.addOutput(output)
        } catch {
            errorMessage = "Aufnahme konnte nicht gestartet werden: \(error.localizedDescription)"
            return
        }

        output.audioSettings = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        let fileURL = makeRecordingURL()
        currentFileURL = fileURL
        finalizationSemaphore = DispatchSemaphore(value: 0)
        self.session = session
        self.fileOutput = output

        session.startRunning()
        output.startRecording(to: fileURL, outputFileType: .m4a, recordingDelegate: self)
        isRecording = true
        startMetering()
    }

    func stopRecording() {
        stopMetering()
        let duration = fileOutput?.recordedDuration.seconds ?? 0
        lastRecordingDuration = duration.isFinite ? duration : 0
        if fileOutput?.isRecording == true {
            fileOutput?.stopRecording()
            // Datei wird asynchron finalisiert; Delegate signalisiert den Semaphor.
            // Timeout als Sicherheitsnetz, damit die UI nie hängen bleibt.
            _ = finalizationSemaphore?.wait(timeout: .now() + 2)
        }
        session?.stopRunning()
        isRecording = false
        recordingURL = currentFileURL
        currentFileURL = nil
        session = nil
        fileOutput = nil
        finalizationSemaphore = nil
        audioLevel = 0
    }

    func discardRecording() {
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
            self.recordingURL = nil
        }

        if let currentFileURL {
            try? FileManager.default.removeItem(at: currentFileURL)
            self.currentFileURL = nil
        }
    }

    // MARK: - Pegel

    private func startMetering() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            let power = self.fileOutput?.connections.first?.audioChannels.first?.averagePowerLevel ?? -160
            let normalized = max(0, min(1, (power + 50) / 50))
            self.audioLevel = normalized
        }
    }

    private func stopMetering() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    // MARK: - AVCaptureFileOutputRecordingDelegate

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        finalizationSemaphore?.signal()
        if let error {
            Task { @MainActor in
                self.errorMessage = "Aufnahme fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }
}
