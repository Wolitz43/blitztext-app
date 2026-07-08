# Automatische Spracherkennung + Mikrofon-Auswahl Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transkriptions-Sprache per Settings-Picker wählbar (inkl. „Automatisch" via Whisper-Auto-Detect) und Aufnahme-Mikrofon per Settings-Picker wählbar (inkl. „System-Standard" mit stillem Fallback).

**Architecture:** Neues Enum `TranscriptionLanguage` ersetzt den fest verdrahteten Sprach-String (leerer `whisperCode` = auto; Services können das bereits). `AudioRecorder` wechselt intern von `AVAudioRecorder` auf `AVCaptureSession` + `AVCaptureAudioFileOutput` (einziger Weg zur Geräteauswahl auf macOS) bei identischer öffentlicher Schnittstelle; die Datei-Finalisierung ist dort asynchron und wird per Delegate + Semaphor mit Timeout synchron gehalten, damit die Workflows unverändert direkt nach `stopRecording()` transkribieren können. Die Mikrofon-ID fließt analog zum bestehenden `language:`-Parameter durch die 4 Workflow-Inits.

**Tech Stack:** Swift 5.10, SwiftUI, AVFoundation (`AVCaptureSession`), WhisperKit (argmax-oss-swift 0.18.0), macOS 14+.

**Spec:** `docs/superpowers/specs/2026-07-08-auto-language-microphone-selection-design.md`

## Global Constraints

- **NIEMALS `xcodegen generate` ausführen** — zerstört die manuell gepflegten Schemes im gitignorten `.xcodeproj` (siehe `CLAUDE.md`).
- **Keine neuen Dateien, keine Verschiebungen/Umbenennungen** — pbxproj referenziert feste Pfade; alle Änderungen in bestehenden Dateien.
- Kein Test-Target. Verifikation pro Task (Repo-Root `/Users/arndstielow/Documents/blitztext-app`):
  `xcodebuild -project BlitztextMac/BlitztextMac.xcodeproj -scheme "Blitztext (Debug)" build 2>&1 | tail -3`
  muss `** BUILD SUCCEEDED **` liefern. **KEIN `-derivedDataPath` verwenden** — DerivedData im Repo/~/Documents bricht CodeSign an iCloud-xattrs (siehe `CLAUDE.md`). Gebaute App: `/Users/arndstielow/Library/Developer/Xcode/DerivedData/BlitztextMac-awjhkzjrrtvdzicadcqyqjhkirgn/Build/Products/Debug/Blitztext Dev.app`.
- Sprach-Default: `.automatic` für Neuinstallationen; bestehende `settings.json` mit `"language": "de"` dekodiert weiter als Deutsch.
- Mikrofon-Default: `nil` = System-Standard (heutiges Verhalten); fehlendes Gerät → stiller Fallback auf Standard.
- Aufnahmeformat bleibt `.m4a`/AAC, 16 kHz, mono.
- UI-Texte auf Deutsch im Stil der bestehenden Views (Labels Fontgröße 11, Hinweise 10.5).
- Commit-Messages auf Deutsch (`feat:`/`chore:`), Trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: `TranscriptionLanguage`-Enum + `AppSettings.selectedMicrophoneID` + AppState-Umstellung

**Files:**
- Modify: `BlitztextMac/Features/Workflows/WorkflowProtocol.swift` (struct `AppSettings` ~Zeile 122-177; struct `TranscriptionSettings` ~Zeile 253-273)
- Modify: `BlitztextMac/App/AppState.swift:206-250` (5 Workflow-Bau-Stellen)

**Interfaces:**
- Consumes: bestehende Muster in `AppSettings` (Property/Init/CodingKeys/`decodeIfPresent`).
- Produces: `enum TranscriptionLanguage: String, Codable, CaseIterable, Identifiable` mit `whisperCode: String` und `displayName: String`; `TranscriptionSettings.language: TranscriptionLanguage`; `AppSettings.selectedMicrophoneID: String?` — von Task 3 (Durchreichung) und Task 4 (UI-Bindings) genutzt.

- [ ] **Step 1: `TranscriptionLanguage` definieren**

In `WorkflowProtocol.swift` direkt VOR der struct `TranscriptionSettings` (im Bereich `// MARK: - Workflow Settings`) einfügen:

```swift
enum TranscriptionLanguage: String, Codable, CaseIterable, Identifiable {
    case automatic = "auto"
    case german    = "de"
    case english   = "en"
    case french    = "fr"
    case spanish   = "es"
    case italian   = "it"

    var id: String { rawValue }

    /// Whisper-Parameter: leer = Sprache automatisch erkennen
    /// (beide Services lassen den Parameter bei leerem Wert weg).
    var whisperCode: String { self == .automatic ? "" : rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Automatisch"
        case .german:    return "Deutsch"
        case .english:   return "Englisch"
        case .french:    return "Französisch"
        case .spanish:   return "Spanisch"
        case .italian:   return "Italienisch"
        }
    }
}
```

- [ ] **Step 2: `TranscriptionSettings.language` auf das Enum umstellen**

Die struct hat einen Custom-Decoder. Property und Decoder-Zeile ändern:

```swift
struct TranscriptionSettings: Codable {
    var language: TranscriptionLanguage = .automatic
    var translation: TranslationStepSettings = TranslationStepSettings()

    enum CodingKeys: String, CodingKey {
        case language
        case translation
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        language = (try? container.decodeIfPresent(TranscriptionLanguage.self, forKey: .language)) ?? .automatic
        translation = try container.decodeIfPresent(TranslationStepSettings.self, forKey: .translation) ?? TranslationStepSettings()
    }
}
```

Wichtig: `try?` statt `try` beim Sprach-Decode — ein unbekannter alter String-Wert darf nicht das gesamte Container-Decoding sprengen. Bestehendes `"de"` trifft den rawValue von `.german`.

- [ ] **Step 3: `AppSettings.selectedMicrophoneID` ergänzen**

An den vier bekannten Stellen der struct `AppSettings`, jeweils nach `translationTargetLanguage` (exakt dem bestehenden Muster folgend):

Property:

```swift
    var translationTargetLanguage: TargetLanguage = .english
    var selectedMicrophoneID: String? = nil
```

Memberwise-Init (Parameter + Zuweisung):

```swift
        translationTargetLanguage: TargetLanguage = .english,
        selectedMicrophoneID: String? = nil
```
```swift
        self.translationTargetLanguage = translationTargetLanguage
        self.selectedMicrophoneID = selectedMicrophoneID
```

CodingKeys:

```swift
        case translationTargetLanguage
        case selectedMicrophoneID
```

Custom-Decoder:

```swift
        selectedMicrophoneID = try container.decodeIfPresent(String.self, forKey: .selectedMicrophoneID)
```

- [ ] **Step 4: AppState auf `whisperCode` umstellen**

In `AppState.swift` an allen 5 Workflow-Bau-Stellen in `startWorkflow` (Zeilen 206-250, Cases `.transcription`, `.localTranscription`, `.textImprover`, `.dampfAblassen`, `.emojiText`) den Parameter ändern:

```swift
                language: transcriptionSettings.language.whisperCode,
```

(vorher: `language: transcriptionSettings.language,` — der Workflow-Parameter bleibt `String`.)

- [ ] **Step 5: Build verifizieren**

Run: `xcodebuild -project BlitztextMac/BlitztextMac.xcodeproj -scheme "Blitztext (Debug)" build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add BlitztextMac/Features/Workflows/WorkflowProtocol.swift BlitztextMac/App/AppState.swift
git commit -m "feat: TranscriptionLanguage-Enum mit Auto-Erkennung, Mikrofon-ID in AppSettings

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `AudioRecorder` auf `AVCaptureSession` umbauen

**Files:**
- Modify: `BlitztextMac/Services/AudioRecorder.swift` (kompletter Umbau, Datei ist 98 Zeilen)

**Interfaces:**
- Consumes: nichts aus anderen Tasks (Default-Parameter hält bestehende Aufrufer kompilierbar).
- Produces: `func startRecording(preferredDeviceID: String? = nil)`; `struct MicrophoneDevice: Identifiable, Equatable { let id: String; let name: String }`; `static func availableMicrophones() -> [MicrophoneDevice]`. Übrige Schnittstelle unverändert: `isRecording`, `audioLevel`, `recordingURL`, `errorMessage`, `lastRecordingDuration`, `stopRecording()`, `discardRecording()`.

**Kernproblem dieses Tasks:** `AVCaptureAudioFileOutput.stopRecording()` finalisiert die Datei **asynchron** (Delegate-Callback), aber alle 4 Workflows lesen `recordingURL` synchron direkt nach `stopRecording()` und transkribieren sofort. Lösung: Delegate signalisiert einen Semaphor; `stopRecording()` wartet darauf mit 2-s-Timeout. Die Wartezeit ist real wenige Millisekunden (lokales m4a-Finalisieren); der Timeout ist nur Sicherheitsnetz gegen UI-Hänger.

- [ ] **Step 1: Datei komplett ersetzen**

Neuer Inhalt von `BlitztextMac/Services/AudioRecorder.swift`:

```swift
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
```

Hinweise für den Implementer:
- `AVCaptureFileOutput` meldet beim normalen Stop teils einen „Fehler" mit
  Code `AVError.maximumDurationReached` o.ä. NICHT — aber falls beim
  manuellen Test ein harmloser Stop-„Fehler" als `errorMessage` auftaucht,
  dokumentieren, nicht wegfiltern (Review entscheidet).
- `session.startRunning()` blockiert kurz (~100 ms Session-Spin-up). Das ist
  eine bewusste Vereinfachung; nicht auf Background-Queues umbauen.
- Falls die Semaphor-Property-Zugriffe unter Swift 5.10 Concurrency-Warnungen
  erzeugen: gleiche Behandlung wie das bestehende `nonisolated`-Delegate-
  Muster der alten Datei; Warnungen im Report nennen.

- [ ] **Step 2: Build verifizieren**

Run: `xcodebuild -project BlitztextMac/BlitztextMac.xcodeproj -scheme "Blitztext (Debug)" build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Launch-Smoke (Verhalten mit Default-Gerät unverändert)**

Run: `"/Users/arndstielow/Library/Developer/Xcode/DerivedData/BlitztextMac-awjhkzjrrtvdzicadcqyqjhkirgn/Build/Products/Debug/Blitztext Dev.app/Contents/MacOS/Blitztext Dev" & sleep 8; kill %1`
Expected: läuft ~8 s ohne Absturz (Menüleisten-App, kein Fenster).

- [ ] **Step 4: Commit**

```bash
git add BlitztextMac/Services/AudioRecorder.swift
git commit -m "feat: AudioRecorder auf AVCaptureSession mit Mikrofon-Auswahl umgebaut

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: `microphoneID` durch die 4 Workflows + AppState

**Files:**
- Modify: `BlitztextMac/Features/Workflows/TranscriptionWorkflow.swift:23-51`
- Modify: `BlitztextMac/Features/Workflows/TextImprovementWorkflow.swift:16-52`
- Modify: `BlitztextMac/Features/Workflows/DampfAblassenWorkflow.swift:16-53`
- Modify: `BlitztextMac/Features/Workflows/EmojiTextWorkflow.swift:16-53`
- Modify: `BlitztextMac/App/AppState.swift:206-250` (5 Bau-Stellen)

**Interfaces:**
- Consumes: `AudioRecorder.startRecording(preferredDeviceID: String?)` (Task 2); `AppSettings.selectedMicrophoneID` (Task 1).
- Produces: alle 4 Workflow-Inits haben einen zusätzlichen Parameter `microphoneID: String? = nil`, direkt nach `language:`.

In jedem der 4 Workflow-Files exakt drei Edits (identisches Muster):

- [ ] **Step 1: `TranscriptionWorkflow.swift`**

Property (nach `private let language: String`):

```swift
    private let language: String
    private let microphoneID: String?
```

Init (Parameter nach `language:`, Zuweisung nach `self.language = language`):

```swift
    init(
        type: WorkflowType = .transcription,
        customTerms: [String] = [],
        language: String = "de",
        microphoneID: String? = nil,
        backend: TranscriptionBackend = .remote,
        localModelName: String = LocalTranscriptionService.recommendedFastModelName
    ) {
        self.type = type
        self.customTerms = customTerms
        self.language = language
        self.microphoneID = microphoneID
        self.backend = backend
        self.localModelName = localModelName
    }
```

`start()` (Zeile 46):

```swift
        recorder.startRecording(preferredDeviceID: microphoneID)
```

- [ ] **Step 2: `TextImprovementWorkflow.swift`**

Property nach `private let language: String`: `private let microphoneID: String?`

```swift
    init(
        settings: TextImprovementSettings,
        language: String = "de",
        microphoneID: String? = nil,
        llmBackend: LLMBackend = .remote,
        transcriptionBackend: TranscriptionBackend = .remote,
        localModelName: String = LocalTranscriptionService.recommendedFastModelName
    ) {
        self.settings = settings
        self.language = language
        self.microphoneID = microphoneID
        self.llmBackend = llmBackend
        self.transcriptionBackend = transcriptionBackend
        self.localModelName = localModelName
    }
```

`start()` (Zeile 47): `recorder.startRecording(preferredDeviceID: microphoneID)`

- [ ] **Step 3: `DampfAblassenWorkflow.swift`**

Property nach `private let language: String`: `private let microphoneID: String?`

```swift
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
```

`start()` (Zeile 50): `recorder.startRecording(preferredDeviceID: microphoneID)`

- [ ] **Step 4: `EmojiTextWorkflow.swift`**

Property nach `private let language: String`: `private let microphoneID: String?`

```swift
    init(
        settings: EmojiTextSettings,
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
```

`start()` (Zeile 50): `recorder.startRecording(preferredDeviceID: microphoneID)`

- [ ] **Step 5: AppState — `microphoneID` an allen 5 Bau-Stellen**

In `startWorkflow` (AppState.swift:206-250) bei allen 5 Cases direkt nach der `language:`-Zeile einfügen:

```swift
                microphoneID: appSettings.selectedMicrophoneID,
```

- [ ] **Step 6: Build verifizieren**

Run: `xcodebuild -project BlitztextMac/BlitztextMac.xcodeproj -scheme "Blitztext (Debug)" build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add BlitztextMac/Features/Workflows/TranscriptionWorkflow.swift BlitztextMac/Features/Workflows/TextImprovementWorkflow.swift BlitztextMac/Features/Workflows/DampfAblassenWorkflow.swift BlitztextMac/Features/Workflows/EmojiTextWorkflow.swift BlitztextMac/App/AppState.swift
git commit -m "feat: Mikrofon-ID wird analog zur Sprache durch die Workflows gereicht

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Settings-UI — Picker „Gesprochene Sprache" und „Mikrofon"

**Files:**
- Modify: `BlitztextMac/Features/Settings/SettingsContentView.swift` (neue Sektion zwischen `// MARK: Tastenkuerzel` [endet ~Zeile 668] und `// MARK: Übersetzung (global)` [~Zeile 670]; plus eine `@State`-Property in derselben View-Struct)

**Interfaces:**
- Consumes: `TranscriptionLanguage` (Task 1), `AppSettings.selectedMicrophoneID` (Task 1), `MicrophoneDevice` + `AudioRecorder.availableMicrophones()` (Task 2).
- Produces: keine neuen Schnittstellen (reine View-Änderung).

- [ ] **Step 1: `@State` für die Geräteliste ergänzen**

In der View-Struct, die die Sektion `// MARK: Tastenkuerzel` enthält (auffindbar per Suche nach `SectionLabel(text: "Tastenkürzel")`), bei den übrigen Properties:

```swift
    @State private var availableMicrophones: [MicrophoneDevice] = []
```

- [ ] **Step 2: Neue Sektion „Aufnahme" einfügen**

Zwischen dem Ende der Tastenkürzel-Sektion (`}` in Zeile ~668) und `// MARK: Übersetzung (global)`:

```swift
            // MARK: Aufnahme
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Aufnahme")

                // Gesprochene Sprache
                VStack(alignment: .leading, spacing: 8) {
                    Text("Gesprochene Sprache")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Picker("", selection: $appState.transcriptionSettings.language) {
                        ForEach(TranscriptionLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)

                    Text("Automatisch erkennt die gesprochene Sprache; bei sehr kurzen Äußerungen ist eine feste Sprache zuverlässiger.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Mikrofon
                VStack(alignment: .leading, spacing: 8) {
                    Text("Mikrofon")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Picker("", selection: $appState.appSettings.selectedMicrophoneID) {
                        Text("System-Standard").tag(String?.none)
                        ForEach(availableMicrophones) { mic in
                            Text(mic.name).tag(String?.some(mic.id))
                        }
                        if let selectedID = appState.appSettings.selectedMicrophoneID,
                           !availableMicrophones.contains(where: { $0.id == selectedID }) {
                            Text("Nicht verbunden").tag(String?.some(selectedID))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .onAppear {
                        availableMicrophones = AudioRecorder.availableMicrophones()
                    }

                    Text("Ist das gewählte Mikrofon nicht angeschlossen, wird automatisch der System-Standard verwendet.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
```

- [ ] **Step 3: Build verifizieren**

Run: `xcodebuild -project BlitztextMac/BlitztextMac.xcodeproj -scheme "Blitztext (Debug)" build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add BlitztextMac/Features/Settings/SettingsContentView.swift
git commit -m "feat: Settings-Picker für gesprochene Sprache und Mikrofon

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: WhisperKit-Auto-Detect verifizieren + Doku + Abschluss-Smoke

**Files:**
- Möglicherweise Modify: `BlitztextMac/Services/LocalTranscriptionService.swift:258-263` (nur falls Check es erfordert)
- Modify: `BlitztextMac/App/PLANNED_FEATURES.md` (Erledigt-Eintrag + Hinweise)

**Interfaces:**
- Consumes: `DecodingOptions` aus WhisperKit (argmax-oss-swift 0.18.0); bestehendes `LocalTranscriptionService.transcribe(audioURL:language:modelName:)`.
- Produces: keine neuen Schnittstellen.

- [ ] **Step 1: WhisperKit-`DecodingOptions` prüfen**

Die SPM-Quelle liegt im DerivedData-Checkout:

Run: `grep -rn "detectLanguage" /Users/arndstielow/Library/Developer/Xcode/DerivedData/BlitztextMac-awjhkzjrrtvdzicadcqyqjhkirgn/SourcePackages/checkouts/*/Sources/WhisperKit/Core/Text/DecodingTask.swift /Users/arndstielow/Library/Developer/Xcode/DerivedData/BlitztextMac-awjhkzjrrtvdzicadcqyqjhkirgn/SourcePackages/checkouts/*/Sources/WhisperKit/Core/Configurations.swift 2>/dev/null | head -20`

(Falls die Pfade nicht treffen: `grep -rn "struct DecodingOptions" .../SourcePackages/checkouts/ --include="*.swift"` und von dort navigieren.)

Zu klären: Erkennt WhisperKit bei `language: nil` automatisch (z.B. weil `detectLanguage` intern auf `language == nil` defaultet), oder muss `detectLanguage: true` explizit gesetzt werden?

- [ ] **Step 2 (nur falls nötig): `LocalTranscriptionService` anpassen**

Falls `detectLanguage` explizit gesetzt werden muss, in `transcribe` (Zeile 260-263):

```swift
        let decodeOptions = DecodingOptions(
            task: .transcribe,
            language: resolvedLanguage.isEmpty ? nil : resolvedLanguage,
            detectLanguage: resolvedLanguage.isEmpty
        )
```

(Parameterposition an die tatsächliche Init-Signatur anpassen.) Falls NICHT nötig: Ergebnis der Prüfung im Report festhalten, Datei unverändert lassen.

- [ ] **Step 3: PLANNED_FEATURES.md aktualisieren**

Im Abschnitt „✅ Erledigt (06.07.2026)" darüber einen neuen Abschnitt einfügen:

```markdown
## ✅ Erledigt (08.07.2026)
- Gesprochene Sprache einstellbar inkl. „Automatisch" (Whisper-Auto-Erkennung);
  Settings → Anpassen → „Aufnahme". Bestehende Installationen bleiben auf
  Deutsch, Neuinstallationen starten mit Automatisch.
- Mikrofon-Auswahl in den Settings (System-Standard + angeschlossene Geräte,
  stiller Fallback auf Standard wenn das Gerät fehlt). Aufnahme-Engine dafür
  von AVAudioRecorder auf AVCaptureSession umgestellt.
  Spec: `docs/superpowers/specs/2026-07-08-auto-language-microphone-selection-design.md`

### Hinweise
- Englischsprachige Lokal-Modelle (`*.en`) können nie auto-erkennen — sie
  transkribieren immer englisch; kein Fehler, nur Verhalten.
- Manuell noch zu prüfen (Mensch): Aufnahme über ein explizit gewähltes
  Mikrofon; Auto-Erkennung mit je einem deutschen und englischen Satz;
  Fallback nach Abziehen eines gewählten USB-Mikrofons; erste Silbe wird
  nicht abgeschnitten (AVCaptureSession-Spin-up beim Aufnahmestart).
```

In der Tabelle „📝 Transkriptions-Qualität & Komfort" die Zeile
„Sprache auto-erkennen" und in „🎙️ Aufnahme & Audio" die Zeile
„Mikrofon wählen" jeweils mit `✅` markieren (Spalte „Aufwand" durch
`✅ 08.07.2026` ersetzen). Ebenso in der „Top-5"-Tabelle die Zeilen 1
(Mikrofon-Auswahl) und 5 (Sprache auto-erkennen) mit ✅ versehen.

- [ ] **Step 4: Build + Launch-Smoke**

Run: `xcodebuild -project BlitztextMac/BlitztextMac.xcodeproj -scheme "Blitztext (Debug)" build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

Run: `"/Users/arndstielow/Library/Developer/Xcode/DerivedData/BlitztextMac-awjhkzjrrtvdzicadcqyqjhkirgn/Build/Products/Debug/Blitztext Dev.app/Contents/MacOS/Blitztext Dev" & sleep 8; kill %1`
Expected: läuft ~8 s ohne Absturz, bestehende `settings.json` lädt fehlerfrei.

- [ ] **Step 5: Commit**

```bash
git add BlitztextMac/App/PLANNED_FEATURES.md BlitztextMac/Services/LocalTranscriptionService.swift
git commit -m "chore: WhisperKit-Auto-Detect geprüft, Feature-Doku aktualisiert

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

(Falls `LocalTranscriptionService.swift` unverändert blieb, nur die Markdown-Datei stagen.)

---

## Abschluss / Manueller Test (Mensch)

Kann keine KI-Session ausführen — nach dem Merge zu prüfen:
1. Settings → Anpassen → „Aufnahme": beide Picker sichtbar, Geräteliste zeigt angeschlossene Mikrofone.
2. Bestimmtes Mikrofon wählen, Aufnahme starten → Aufnahme kommt von diesem Gerät (z.B. Headset vs. eingebaut gegensprechen).
3. „Automatisch" + deutscher Satz → deutscher Text; englischer Satz → englischer Text (remote und, mit multilingualem Modell, lokal).
4. Gewähltes USB-Mikrofon abziehen, Aufnahme starten → Aufnahme läuft über System-Standard, kein Fehler.
5. Erste Silbe direkt nach Hotkey-Druck sprechen → nicht abgeschnitten (Spin-up-Latenz der neuen Engine).
6. Waveform bewegt sich weiterhin während der Aufnahme (neuer Pegel-Pfad).
