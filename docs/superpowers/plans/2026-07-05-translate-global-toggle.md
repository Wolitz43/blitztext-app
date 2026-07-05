# Übersetzung als globaler Toggle — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ersetzt den bisherigen 5. Menüeintrag „Blitztext 🌍" (eigener `.translate`-Workflow) durch einen globalen Übersetzungs-Toggle, der als zusätzlicher Schritt auf die 4 bestehenden Workflows (Transkription, Textverbesserer, Dampf ablassen, Emoji-Text) anwendbar ist.

**Architecture:** Ein neuer `TranslatingWorkflow` implementiert das `Workflow`-Protokoll und wrapped optional den jeweils gestarteten Workflow. `AppState.startWorkflow` entscheidet anhand `appSettings.translationEnabled`, ob gewrapped wird. Meldet der innere Workflow `.done(text)`, hängt der Wrapper einen zusätzlichen Übersetzungs-Call an, bevor er selbst `.done(translatedText)` meldet. Jeder der 4 Workflows hat eine eigene `TranslationStepSettings` (Zielsprache/Ton/Kontext).

**Tech Stack:** Swift 5.9+, SwiftUI, AppKit, `@Observable`-Makro, macOS. Kein XCTest-Target im Projekt — Verifikation erfolgt über `xcodebuild` + manuellen Smoke-Test im Debug-Build (siehe Testing-Abschnitt der Spec).

## Global Constraints

- Referenz-Spec: `docs/superpowers/specs/2026-07-05-translate-global-toggle-design.md` — bei Widersprüchen zwischen Plan und Spec gilt dieser Plan (spätere, detailliertere Verfeinerung), Abweichungen sind unten explizit vermerkt.
- `AppSettings.translationEnabled: Bool = false` ist der einzige globale An/Aus-Schalter.
- `TranslationStepSettings { targetLanguage: TargetLanguage = .english, tone: TranslateTone = .neutral, context: String = "" }` wird pro Workflow dupliziert: `transcriptionSettings.translation`, `textImprovementSettings.translation`, `dampfAblassenSettings.translation`, `emojiTextSettings.translation`.
- `TargetLanguage` behält alle 8 Fälle (en/fr/es/it/pt/nl/pl/ja); UI-Picker verwenden ausschließlich `TargetLanguage.selectable = [.english, .french, .spanish, .italian]`.
- Kein Test-Target im Projekt — keine XCTest-Dateien anlegen. Jeder Task endet mit `xcodebuild`-Build-Check und/oder `grep`-Sanity-Check statt automatisierten Tests.
- Build-Kommando (aus `BlitztextMac/`-Verzeichnis): `xcodebuild -project BlitztextMac.xcodeproj -scheme "Blitztext (Debug)" -configuration Debug build`
- **Abweichung von der Spec (Sicherheitsgrund):** Der Übersetzungsfehler-Fallback zeigt **keinen** transienten `.error(...)`-Phasenwechsel mehr (wie in der Spec beschrieben). Grund: `AppState.handleWorkflowPhaseChange` löscht bei `.error` und `activeLaunchSource == .hotkeyBackground` sofort `activeWorkflow`/`activePasteTarget` und setzt `page = .main` — ein nachfolgendes `.done(originalText)` würde dann mit bereits gelöschtem Paste-Target ins Leere laufen und der Fallback-Text würde nicht eingefügt. Stattdessen: direkter Übergang von `.running("Wird übersetzt ...")` zu `.done(originalText)` ohne Zwischenschritt.
- `TranslateWorkflow.swift` und `TranslateSettings.swift` sind bereits gelöscht (vorheriger Commit). Alle anderen Dateien referenzieren diese Typen aktuell noch — das Projekt kompiliert bis Task 8 **nicht**. Das ist erwartet.

---

### Task 1: Datenmodell — WorkflowProtocol.swift

**Files:**
- Modify: `BlitztextMac/Features/Workflows/WorkflowProtocol.swift`

**Interfaces:**
- Produces: `TranslationStepSettings`, `TargetLanguage` (inkl. `.selectable`), `TranslateTone`, `WorkflowType` (ohne `.translate`), `Workflow`-Protokoll mit `audioLevel: Float { get }`, `AppSettings.translationEnabled`, `TranscriptionSettings.translation`, `TextImprovementSettings.translation`, `DampfAblassenSettings.translation`, `EmojiTextSettings.translation`.
- Consumes: nichts (Basis-Datei ohne eigene Abhängigkeiten auf andere Feature-Dateien).

- [ ] **Step 1: Datei komplett ersetzen**

Ersetze den **gesamten Inhalt** von `BlitztextMac/Features/Workflows/WorkflowProtocol.swift` durch:

```swift
import Foundation

// MARK: - Workflow Types

enum WorkflowType: String, CaseIterable, Identifiable, Codable {
    case transcription
    case localTranscription
    case textImprover
    case dampfAblassen
    case emojiText

    var id: String { rawValue }

    static var mainMenuCases: [WorkflowType] {
        allCases.filter { $0 != .localTranscription }
    }

    var displayName: String {
        switch self {
        case .transcription:     return "Blitztext"
        case .localTranscription: return "Blitztext Lokal"
        case .textImprover:      return "Blitztext+"
        case .dampfAblassen:     return "Blitztext $%&!"
        case .emojiText:         return "Blitztext :)"
        }
    }

    var icon: String {
        switch self {
        case .transcription:     return "mic.fill"
        case .localTranscription: return "lock.shield.fill"
        case .textImprover:      return "text.badge.checkmark"
        case .dampfAblassen:     return "flame.fill"
        case .emojiText:         return "face.smiling"
        }
    }

    var subtitle: String {
        switch self {
        case .transcription:     return "Sprache rein. Text raus."
        case .localTranscription: return "Nur lokal. Kein Server."
        case .textImprover:      return "Geschrieben sprechen."
        case .dampfAblassen:     return "Frust rein. Entspannt raus."
        case .emojiText:         return "Text rein. Emojis dazu."
        }
    }

    var hotkeyLabel: String {
        switch self {
        case .transcription:     return "fn + Shift"
        case .localTranscription: return "fn + Shift + Ctrl"
        case .textImprover:      return "fn + Control"
        case .dampfAblassen:     return "fn + Option"
        case .emojiText:         return "fn + Cmd"
        }
    }

    var accentColor: String {
        switch self {
        case .transcription:     return "blue"
        case .localTranscription: return "green"
        case .textImprover:      return "purple"
        case .dampfAblassen:     return "orange"
        case .emojiText:         return "cyan"
        }
    }
}

// MARK: - Workflow State

enum WorkflowPhase: Equatable {
    case idle
    case running(String)
    case done(String)
    case error(String)

    var isActive: Bool {
        switch self {
        case .idle: return false
        default: return true
        }
    }
}

enum WorkflowLaunchSource: Equatable {
    case manual
    case hotkeyBackground

    var presentsWorkflowPage: Bool {
        switch self {
        case .manual:
            return true
        case .hotkeyBackground:
            return false
        }
    }
}

typealias WorkflowOutputHandler = @MainActor (String) -> Void
typealias WorkflowPhaseChangeHandler = @MainActor (WorkflowPhase) -> Void
typealias WorkflowUsageHandler = @MainActor (UsageRecord) -> Void

// MARK: - Workflow Protocol

@MainActor
protocol Workflow: AnyObject, Observable {
    var type: WorkflowType { get }
    var phase: WorkflowPhase { get set }
    var isRecording: Bool { get }
    var audioLevel: Float { get }
    var onOutput: WorkflowOutputHandler? { get set }
    var onPhaseChange: WorkflowPhaseChangeHandler? { get set }
    var onUsage: WorkflowUsageHandler? { get set }

    func start()
    func stop()
    func reset()
}

// MARK: - App Settings

struct AppSettings: Codable {
    var hotkeyMode: HotkeyMode = .hold
    var hasSeenOnboarding: Bool = false
    var secureLocalModeEnabled: Bool = false
    var selectedLocalTranscriptionModelName: String = LocalTranscriptionService.recommendedFastModelName
    var hasAutoSelectedFastLocalModel: Bool = false
    var translationEnabled: Bool = false

    init(
        hotkeyMode: HotkeyMode = .hold,
        hasSeenOnboarding: Bool = false,
        secureLocalModeEnabled: Bool = false,
        selectedLocalTranscriptionModelName: String = LocalTranscriptionService.recommendedFastModelName,
        hasAutoSelectedFastLocalModel: Bool = false,
        translationEnabled: Bool = false
    ) {
        self.hotkeyMode = hotkeyMode
        self.hasSeenOnboarding = hasSeenOnboarding
        self.secureLocalModeEnabled = secureLocalModeEnabled
        self.selectedLocalTranscriptionModelName = selectedLocalTranscriptionModelName
        self.hasAutoSelectedFastLocalModel = hasAutoSelectedFastLocalModel
        self.translationEnabled = translationEnabled
    }

    enum CodingKeys: String, CodingKey {
        case hotkeyMode
        case hasSeenOnboarding
        case secureLocalModeEnabled
        case selectedLocalTranscriptionModelName
        case hasAutoSelectedFastLocalModel
        case translationEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hotkeyMode = try container.decodeIfPresent(HotkeyMode.self, forKey: .hotkeyMode) ?? .hold
        hasSeenOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasSeenOnboarding) ?? false
        secureLocalModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .secureLocalModeEnabled) ?? false
        selectedLocalTranscriptionModelName = try container.decodeIfPresent(
            String.self,
            forKey: .selectedLocalTranscriptionModelName
        ) ?? LocalTranscriptionService.recommendedFastModelName
        hasAutoSelectedFastLocalModel = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasAutoSelectedFastLocalModel
        ) ?? false
        translationEnabled = try container.decodeIfPresent(Bool.self, forKey: .translationEnabled) ?? false
    }
}

enum TranscriptionBackend: String, Codable {
    case remote
    case local
}

// MARK: - Translation Step Settings (shared by all 4 workflows)

struct TranslationStepSettings: Codable {
    var targetLanguage: TargetLanguage = .english
    var tone: TranslateTone = .neutral
    var context: String = ""
}

enum TargetLanguage: String, Codable, CaseIterable, Identifiable {
    case english    = "en"
    case french     = "fr"
    case spanish    = "es"
    case italian    = "it"
    case portuguese = "pt"
    case dutch      = "nl"
    case polish     = "pl"
    case japanese   = "ja"

    var id: String { rawValue }

    /// Nur diese 4 werden aktuell in der UI angeboten; die übrigen Fälle
    /// bleiben für spätere Erweiterung im Enum und in der Persistenz erhalten.
    static let selectable: [TargetLanguage] = [.english, .french, .spanish, .italian]

    var displayName: String {
        switch self {
        case .english:    return "Englisch"
        case .french:     return "Französisch"
        case .spanish:    return "Spanisch"
        case .italian:    return "Italienisch"
        case .portuguese: return "Portugiesisch"
        case .dutch:      return "Niederländisch"
        case .polish:     return "Polnisch"
        case .japanese:   return "Japanisch"
        }
    }

    var englishName: String {
        switch self {
        case .english:    return "English"
        case .french:     return "French"
        case .spanish:    return "Spanish"
        case .italian:    return "Italian"
        case .portuguese: return "Portuguese"
        case .dutch:      return "Dutch"
        case .polish:     return "Polish"
        case .japanese:   return "Japanese"
        }
    }
}

enum TranslateTone: String, Codable, CaseIterable, Identifiable {
    case formal
    case neutral
    case casual

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .formal:  return "Formell"
        case .neutral: return "Neutral"
        case .casual:  return "Locker"
        }
    }
}

// MARK: - Workflow Settings

struct TranscriptionSettings: Codable {
    var language: String = "de"
    var translation: TranslationStepSettings = TranslationStepSettings()

    enum CodingKeys: String, CodingKey {
        case language
        case translation
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? "de"
        translation = try container.decodeIfPresent(TranslationStepSettings.self, forKey: .translation) ?? TranslationStepSettings()
    }
}

struct DampfAblassenSettings: Codable {
    var systemPrompt: String = "Du erhältst ein emotional gesprochenes Transkript. Erkenne zuerst das eigentliche Ziel, Anliegen und den wahren Frust der Person. Formuliere daraus eine klare, respektvolle und wirksame Nachricht, mit der die Person ihr Ziel eher erreicht. Bewahre relevante Fakten, konkrete Probleme, Grenzen, Erwartungen und die nötige Dringlichkeit. Entferne Beleidigungen, Drohungen, Sarkasmus, Unterstellungen und unnötige Eskalation. Wenn mehrere Vorwürfe genannt werden, verdichte sie auf die entscheidenden Kernpunkte. Der Ton soll ruhig, menschlich, bestimmt und lösungsorientiert sein. Gib NUR die fertige Nachricht zurück."
    var customName: String = ""
    var translation: TranslationStepSettings = TranslationStepSettings()

    enum CodingKeys: String, CodingKey {
        case systemPrompt
        case customName
        case translation
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
        customName = try container.decode(String.self, forKey: .customName)
        translation = try container.decodeIfPresent(TranslationStepSettings.self, forKey: .translation) ?? TranslationStepSettings()
    }
}

struct EmojiTextSettings: Codable {
    var emojiDensity: EmojiDensity = .mittel
    var customName: String = ""
    var translation: TranslationStepSettings = TranslationStepSettings()

    enum EmojiDensity: String, Codable, CaseIterable, Identifiable {
        case wenig
        case mittel
        case viel

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .wenig: return "Wenig"
            case .mittel: return "Mittel"
            case .viel: return "Viel"
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case emojiDensity
        case customName
        case translation
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        emojiDensity = try container.decode(EmojiDensity.self, forKey: .emojiDensity)
        customName = try container.decode(String.self, forKey: .customName)
        translation = try container.decodeIfPresent(TranslationStepSettings.self, forKey: .translation) ?? TranslationStepSettings()
    }
}

struct TextImprovementSettings: Codable {
    var systemPrompt: String = ""
    var customTerms: [String] = []
    var context: String = ""
    var tone: TextTone = .neutral
    var customName: String = ""
    var translation: TranslationStepSettings = TranslationStepSettings()

    enum TextTone: String, Codable, CaseIterable, Identifiable {
        case formal
        case neutral
        case casual

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .formal: return "Formell"
            case .neutral: return "Neutral"
            case .casual: return "Locker"
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case systemPrompt
        case customTerms
        case context
        case tone
        case customName
        case translation
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
        customTerms = try container.decode([String].self, forKey: .customTerms)
        context = try container.decode(String.self, forKey: .context)
        tone = try container.decode(TextTone.self, forKey: .tone)
        customName = try container.decode(String.self, forKey: .customName)
        translation = try container.decodeIfPresent(TranslationStepSettings.self, forKey: .translation) ?? TranslationStepSettings()
    }
}
```

- [ ] **Step 2: Sanity-Grep — sicherstellen, dass keine `.translate`-Referenz mehr in dieser Datei übrig ist**

Run: `grep -n "translate\|Translate" BlitztextMac/Features/Workflows/WorkflowProtocol.swift`
Expected: keine Treffer (leere Ausgabe). Falls doch Treffer erscheinen, wurde Step 1 nicht vollständig übernommen.

- [ ] **Step 3: Commit**

```bash
git add BlitztextMac/Features/Workflows/WorkflowProtocol.swift
git commit -m "feat: Übersetzungs-Settings pro Workflow statt eigenem .translate-Case"
```

(Build-Check bewusst ausgelassen — das Projekt kompiliert erst wieder nach Task 8, siehe Global Constraints.)

---

### Task 2: TranslatingWorkflow (neue Datei)

**Files:**
- Create: `BlitztextMac/Features/Workflows/TranslatingWorkflow.swift`

**Interfaces:**
- Consumes: `Workflow` protocol, `TranslationStepSettings`, `LLMBackend`, `LLMService.translate(text:systemPrompt:model:backend:) async throws -> (String, LLMUsageInfo)`, `TokenPricing.cost(model:promptTokens:completionTokens:audioDurationSeconds:) -> Double`, `UsageRecord.init(workflowType:model:backend:promptTokens:completionTokens:estimatedCostUSD:)`, `TranscriptionQualityService.cleanedTranscript(_:) -> String` (alle bereits vorhanden aus Task 1 / bestehendem Code).
- Produces: `final class TranslatingWorkflow: Workflow`, `init(inner: any Workflow, settings: TranslationStepSettings, llmBackend: LLMBackend)` — wird in Task 4 (`AppState.startWorkflow`) verwendet.

- [ ] **Step 1: Datei anlegen**

```swift
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
```

- [ ] **Step 2: Sanity-Grep**

Run: `grep -c "func start\|func stop\|func reset" BlitztextMac/Features/Workflows/TranslatingWorkflow.swift`
Expected: `3`

- [ ] **Step 3: Commit**

```bash
git add BlitztextMac/Features/Workflows/TranslatingWorkflow.swift
git commit -m "feat: TranslatingWorkflow als Wrapper für optionale Übersetzung"
```

(Build-Check weiterhin ausgelassen — `AppState` referenziert diese neue Klasse erst ab Task 4, aber andere Dateien im Projekt referenzieren noch die gelöschten `TranslateWorkflow`/`TranslateSettings`-Typen.)

---

### Task 3: Hotkey für den Toggle — HotkeyService.swift + BlitztextMacApp.swift

**Files:**
- Modify: `BlitztextMac/Services/HotkeyService.swift`
- Modify: `BlitztextMac/App/BlitztextMacApp.swift`

**Interfaces:**
- Produces: `HotkeyService.onToggleTranslation: (() -> Void)?`
- Consumes: nichts Neues aus vorherigen Tasks (Änderung ist unabhängig von `WorkflowType.translate`, betrifft nur den `fn+T`-Handler).

- [ ] **Step 1: `HotkeyService.swift` — `handleFnT()` umbauen**

Ersetze in `BlitztextMac/Services/HotkeyService.swift` die Property-Deklarationen (aktuell nur `var onHotkeyEvent: ((HotkeyEvent) -> Void)?`) und die `handleFnT()`-Methode.

Ersetze:
```swift
    var onHotkeyEvent: ((HotkeyEvent) -> Void)?
```
durch:
```swift
    var onHotkeyEvent: ((HotkeyEvent) -> Void)?
    var onToggleTranslation: (() -> Void)?
```

Ersetze den Kommentar im `start()`-Body:
```swift
        // Escape key monitor for toggle mode
        // Also handles fn + T (keyCode 17) for translate workflow
```
durch:
```swift
        // Escape key monitor for toggle mode
        // Also handles fn + T (keyCode 17) to toggle translation on/off
```

Ersetze die komplette `handleFnT()`-Methode:
```swift
    private func handleFnT() {
        // fn + T ist ein keyDown-Event, kein flagsChanged.
        // Wir senden .down und sofort .up (kein Hold-Modus nötig da Taste losgelassen).
        onHotkeyEvent?(.down(.translate))
        onHotkeyEvent?(.up(.translate))
    }
```
durch:
```swift
    private func handleFnT() {
        onToggleTranslation?()
    }
```

- [ ] **Step 2: `BlitztextMacApp.swift` — Verdrahtung ergänzen**

In `applicationDidFinishLaunching`, direkt nach der bestehenden Zuweisung:
```swift
        appState.hotkeyService.onHotkeyEvent = { [weak self] event in
            self?.handleHotkeyEvent(event)
        }
```
ergänze:
```swift
        appState.hotkeyService.onHotkeyEvent = { [weak self] event in
            self?.handleHotkeyEvent(event)
        }
        appState.hotkeyService.onToggleTranslation = { [weak self] in
            self?.appState.appSettings.translationEnabled.toggle()
        }
```

- [ ] **Step 3: Sanity-Grep**

Run: `grep -n "translate\|Translate" BlitztextMac/Services/HotkeyService.swift`
Expected: keine Treffer.

Run: `grep -n "onToggleTranslation" BlitztextMac/App/BlitztextMacApp.swift`
Expected: 1 Treffer (die neue Zuweisung).

- [ ] **Step 4: Commit**

```bash
git add BlitztextMac/Services/HotkeyService.swift BlitztextMac/App/BlitztextMacApp.swift
git commit -m "feat: fn+T schaltet globalen Übersetzungs-Toggle statt Workflow zu starten"
```

---

### Task 4: AppState.swift — Wrapping-Logik & Settings-Persistenz

**Files:**
- Modify: `BlitztextMac/App/AppState.swift`

**Interfaces:**
- Consumes: `TranslatingWorkflow.init(inner:settings:llmBackend:)` (Task 2), `TranslationStepSettings` (Task 1), `WorkflowType` ohne `.translate` (Task 1).
- Produces: `AppState.translationStepSettings(for:) -> TranslationStepSettings` (privat, wird von `workflowSubtitle(for:)` und `startWorkflow` genutzt).

- [ ] **Step 1: `translateSettings`-Property entfernen**

Entferne aus der Property-Liste:
```swift
    var translateSettings: TranslateSettings {
        didSet { saveSettings() }
    }
```

- [ ] **Step 2: `init()` — Laden von `translateSettings` entfernen**

Ersetze:
```swift
    init() {
        self.appSettings = Self.loadAppSettings()
        self.transcriptionSettings = Self.loadTranscriptionSettings()
        self.textImprovementSettings = Self.loadTextImprovementSettings()
        self.dampfAblassenSettings = Self.loadDampfAblassenSettings()
        self.emojiTextSettings = Self.loadEmojiTextSettings()
        self.translateSettings = Self.loadTranslateSettings()
        refreshAccessibilityPermission()
        autoSelectFastLocalModelIfNeeded()
        prewarmLocalTranscriptionIfNeeded()
    }
```
durch:
```swift
    init() {
        self.appSettings = Self.loadAppSettings()
        self.transcriptionSettings = Self.loadTranscriptionSettings()
        self.textImprovementSettings = Self.loadTextImprovementSettings()
        self.dampfAblassenSettings = Self.loadDampfAblassenSettings()
        self.emojiTextSettings = Self.loadEmojiTextSettings()
        refreshAccessibilityPermission()
        autoSelectFastLocalModelIfNeeded()
        prewarmLocalTranscriptionIfNeeded()
    }
```

- [ ] **Step 3: `displayName(for:)` — `.translate`-Case entfernen**

Ersetze:
```swift
    func displayName(for type: WorkflowType) -> String {
        switch type {
        case .textImprover:
            let name = textImprovementSettings.customName.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? type.displayName : name
        case .dampfAblassen:
            let name = dampfAblassenSettings.customName.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? type.displayName : name
        case .emojiText:
            let name = emojiTextSettings.customName.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? type.displayName : name
        case .translate:
            let name = translateSettings.customName.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? type.displayName : name
        default:
            return type.displayName
        }
    }
```
durch:
```swift
    func displayName(for type: WorkflowType) -> String {
        switch type {
        case .textImprover:
            let name = textImprovementSettings.customName.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? type.displayName : name
        case .dampfAblassen:
            let name = dampfAblassenSettings.customName.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? type.displayName : name
        case .emojiText:
            let name = emojiTextSettings.customName.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? type.displayName : name
        default:
            return type.displayName
        }
    }
```

- [ ] **Step 4: `workflowSubtitle(for:)` — `.translate`-Case entfernen, Zielsprachen-Suffix ergänzen**

Ersetze die komplette Methode:
```swift
    func workflowSubtitle(for type: WorkflowType) -> String {
        switch type {
        case .transcription:
            if appSettings.secureLocalModeEnabled {
                let modelName = selectedLocalModelName
                return LocalTranscriptionService.isModelInstalled(modelName)
                    ? "Lokal: \(LocalTranscriptionModel.displayName(for: modelName))."
                    : "Lokales WhisperKit-Modell fehlt."
            }
            return "Online: Whisper über OpenAI."
        case .localTranscription:
            return "Nur lokal. Kein Server."
        case .textImprover, .dampfAblassen, .emojiText:
            if appSettings.secureLocalModeEnabled {
                if LocalLLMService.isAvailable {
                    return "Lokal: Apple Intelligence."
                }
                return "Apple Intelligence nicht verfügbar."
            }
            return type.subtitle
        case .translate:
            let lang = translateSettings.targetLanguage.displayName
            if appSettings.secureLocalModeEnabled {
                if LocalLLMService.isAvailable {
                    return "Lokal → \(lang)"
                }
                return "Apple Intelligence nicht verfügbar."
            }
            return "Sprache → \(lang)"
        }
    }
```
durch:
```swift
    func workflowSubtitle(for type: WorkflowType) -> String {
        let base = baseWorkflowSubtitle(for: type)
        guard appSettings.translationEnabled else { return base }
        let lang = translationStepSettings(for: type).targetLanguage.displayName
        return "\(base) → \(lang)"
    }

    private func baseWorkflowSubtitle(for type: WorkflowType) -> String {
        switch type {
        case .transcription:
            if appSettings.secureLocalModeEnabled {
                let modelName = selectedLocalModelName
                return LocalTranscriptionService.isModelInstalled(modelName)
                    ? "Lokal: \(LocalTranscriptionModel.displayName(for: modelName))."
                    : "Lokales WhisperKit-Modell fehlt."
            }
            return "Online: Whisper über OpenAI."
        case .localTranscription:
            return "Nur lokal. Kein Server."
        case .textImprover, .dampfAblassen, .emojiText:
            if appSettings.secureLocalModeEnabled {
                if LocalLLMService.isAvailable {
                    return "Lokal: Apple Intelligence."
                }
                return "Apple Intelligence nicht verfügbar."
            }
            return type.subtitle
        }
    }

    private func translationStepSettings(for type: WorkflowType) -> TranslationStepSettings {
        switch type {
        case .transcription, .localTranscription:
            return transcriptionSettings.translation
        case .textImprover:
            return textImprovementSettings.translation
        case .dampfAblassen:
            return dampfAblassenSettings.translation
        case .emojiText:
            return emojiTextSettings.translation
        }
    }
```

- [ ] **Step 5: `startWorkflow` — Wrapping-Logik einbauen**

Ersetze die komplette Methode (vom `func startWorkflow` bis zur schließenden `}` vor `func isWorkflowAvailable`):
```swift
    func startWorkflow(_ type: WorkflowType, source: WorkflowLaunchSource = .manual) {
        guard isWorkflowAvailable(type) else {
            if source == .manual {
                page = .settings
            }
            return
        }

        activeWorkflow?.stop()
        menuBarStatusResetTask?.cancel()
        workflowCleanupTask?.cancel()
        activeLaunchSource = source
        activePasteTarget = capturePasteTarget(for: source)

        switch type {
        case .transcription:
            let workflow = TranscriptionWorkflow(
                customTerms: textImprovementSettings.customTerms,
                language: transcriptionSettings.language,
                backend: appSettings.secureLocalModeEnabled ? .local : .remote,
                localModelName: selectedLocalModelName
            )
            configureWorkflowHandlers(workflow)
            activeWorkflow = workflow
            workflow.start()

        case .localTranscription:
            let workflow = TranscriptionWorkflow(
                type: .localTranscription,
                customTerms: textImprovementSettings.customTerms,
                language: transcriptionSettings.language,
                backend: .local,
                localModelName: selectedLocalModelName
            )
            configureWorkflowHandlers(workflow)
            activeWorkflow = workflow
            workflow.start()

        case .textImprover:
            let workflow = TextImprovementWorkflow(
                settings: textImprovementSettings,
                language: transcriptionSettings.language,
                llmBackend: resolvedLLMBackend,
                transcriptionBackend: appSettings.secureLocalModeEnabled ? .local : .remote,
                localModelName: selectedLocalModelName
            )
            configureWorkflowHandlers(workflow)
            activeWorkflow = workflow
            workflow.start()

        case .dampfAblassen:
            let workflow = DampfAblassenWorkflow(
                settings: dampfAblassenSettings,
                customTerms: textImprovementSettings.customTerms,
                language: transcriptionSettings.language,
                llmBackend: resolvedLLMBackend,
                transcriptionBackend: appSettings.secureLocalModeEnabled ? .local : .remote,
                localModelName: selectedLocalModelName
            )
            configureWorkflowHandlers(workflow)
            activeWorkflow = workflow
            workflow.start()

        case .emojiText:
            let workflow = EmojiTextWorkflow(
                settings: emojiTextSettings,
                customTerms: textImprovementSettings.customTerms,
                language: transcriptionSettings.language,
                llmBackend: resolvedLLMBackend,
                transcriptionBackend: appSettings.secureLocalModeEnabled ? .local : .remote,
                localModelName: selectedLocalModelName
            )
            configureWorkflowHandlers(workflow)
            activeWorkflow = workflow
            workflow.start()

        case .translate:
            let workflow = TranslateWorkflow(
                settings: translateSettings,
                customTerms: textImprovementSettings.customTerms,
                language: transcriptionSettings.language,
                llmBackend: resolvedLLMBackend,
                transcriptionBackend: appSettings.secureLocalModeEnabled ? .local : .remote,
                localModelName: selectedLocalModelName
            )
            configureWorkflowHandlers(workflow)
            activeWorkflow = workflow
            workflow.start()
        }

        page = source.presentsWorkflowPage ? .workflow : .main
    }
```
durch:
```swift
    func startWorkflow(_ type: WorkflowType, source: WorkflowLaunchSource = .manual) {
        guard isWorkflowAvailable(type) else {
            if source == .manual {
                page = .settings
            }
            return
        }

        activeWorkflow?.stop()
        menuBarStatusResetTask?.cancel()
        workflowCleanupTask?.cancel()
        activeLaunchSource = source
        activePasteTarget = capturePasteTarget(for: source)

        let builtWorkflow: any Workflow
        switch type {
        case .transcription:
            builtWorkflow = TranscriptionWorkflow(
                customTerms: textImprovementSettings.customTerms,
                language: transcriptionSettings.language,
                backend: appSettings.secureLocalModeEnabled ? .local : .remote,
                localModelName: selectedLocalModelName
            )

        case .localTranscription:
            builtWorkflow = TranscriptionWorkflow(
                type: .localTranscription,
                customTerms: textImprovementSettings.customTerms,
                language: transcriptionSettings.language,
                backend: .local,
                localModelName: selectedLocalModelName
            )

        case .textImprover:
            builtWorkflow = TextImprovementWorkflow(
                settings: textImprovementSettings,
                language: transcriptionSettings.language,
                llmBackend: resolvedLLMBackend,
                transcriptionBackend: appSettings.secureLocalModeEnabled ? .local : .remote,
                localModelName: selectedLocalModelName
            )

        case .dampfAblassen:
            builtWorkflow = DampfAblassenWorkflow(
                settings: dampfAblassenSettings,
                customTerms: textImprovementSettings.customTerms,
                language: transcriptionSettings.language,
                llmBackend: resolvedLLMBackend,
                transcriptionBackend: appSettings.secureLocalModeEnabled ? .local : .remote,
                localModelName: selectedLocalModelName
            )

        case .emojiText:
            builtWorkflow = EmojiTextWorkflow(
                settings: emojiTextSettings,
                customTerms: textImprovementSettings.customTerms,
                language: transcriptionSettings.language,
                llmBackend: resolvedLLMBackend,
                transcriptionBackend: appSettings.secureLocalModeEnabled ? .local : .remote,
                localModelName: selectedLocalModelName
            )
        }

        let workflow: any Workflow
        if appSettings.translationEnabled {
            workflow = TranslatingWorkflow(
                inner: builtWorkflow,
                settings: translationStepSettings(for: type),
                llmBackend: resolvedLLMBackend
            )
        } else {
            workflow = builtWorkflow
        }

        configureWorkflowHandlers(workflow)
        activeWorkflow = workflow
        workflow.start()

        page = source.presentsWorkflowPage ? .workflow : .main
    }
```

- [ ] **Step 6: `isWorkflowAvailable` — `.translate`-Case entfernen**

Ersetze:
```swift
    func isWorkflowAvailable(_ type: WorkflowType) -> Bool {
        switch type {
        case .localTranscription:
            return selectedLocalModelIsInstalled
        case .transcription:
            return appSettings.secureLocalModeEnabled
                ? selectedLocalModelIsInstalled
                : KeychainService.isConfigured
        case .textImprover, .dampfAblassen, .emojiText, .translate:
            if appSettings.secureLocalModeEnabled {
                return LocalLLMService.isAvailable
            }
            return KeychainService.isConfigured
        }
    }
```
durch:
```swift
    func isWorkflowAvailable(_ type: WorkflowType) -> Bool {
        switch type {
        case .localTranscription:
            return selectedLocalModelIsInstalled
        case .transcription:
            return appSettings.secureLocalModeEnabled
                ? selectedLocalModelIsInstalled
                : KeychainService.isConfigured
        case .textImprover, .dampfAblassen, .emojiText:
            if appSettings.secureLocalModeEnabled {
                return LocalLLMService.isAvailable
            }
            return KeychainService.isConfigured
        }
    }
```

- [ ] **Step 7: `configureWorkflowHandlers` — Signatur auf `any Workflow` ändern**

Ersetze:
```swift
    private func configureWorkflowHandlers<T: Workflow>(_ workflow: T) {
        workflow.onOutput = { [weak self] text in
            self?.handleWorkflowOutput(text)
        }
        workflow.onPhaseChange = { [weak self, weak workflow] phase in
            guard let self, let workflow else { return }
            self.handleWorkflowPhaseChange(phase, workflow: workflow)
        }
        workflow.onUsage = { [weak self] record in
            self?.usageTracker.track(record)
        }
    }
```
durch:
```swift
    private func configureWorkflowHandlers(_ workflow: any Workflow) {
        workflow.onOutput = { [weak self] text in
            self?.handleWorkflowOutput(text)
        }
        workflow.onPhaseChange = { [weak self, weak workflow] phase in
            guard let self, let workflow else { return }
            self.handleWorkflowPhaseChange(phase, workflow: workflow)
        }
        workflow.onUsage = { [weak self] record in
            self?.usageTracker.track(record)
        }
    }
```

- [ ] **Step 8: `loadTranslateSettings()` entfernen**

Entferne:
```swift
    private static func loadTranslateSettings() -> TranslateSettings {
        loadContainer()?.translate ?? TranslateSettings()
    }
```

- [ ] **Step 9: `saveSettings()` — `translate`-Feld entfernen**

Ersetze:
```swift
    private func saveSettings() {
        let container = SettingsContainer(
            app: appSettings,
            transcription: transcriptionSettings,
            textImprovement: textImprovementSettings,
            dampfAblassen: dampfAblassenSettings,
            emojiText: emojiTextSettings,
            translate: translateSettings
        )
        if let data = try? JSONEncoder().encode(container) {
            try? data.write(to: Self.settingsURL)
        }
    }
```
durch:
```swift
    private func saveSettings() {
        let container = SettingsContainer(
            app: appSettings,
            transcription: transcriptionSettings,
            textImprovement: textImprovementSettings,
            dampfAblassen: dampfAblassenSettings,
            emojiText: emojiTextSettings
        )
        if let data = try? JSONEncoder().encode(container) {
            try? data.write(to: Self.settingsURL)
        }
    }
```

- [ ] **Step 10: `SettingsContainer` — `translate`-Feld entfernen**

Ersetze:
```swift
private struct SettingsContainer: Codable {
    var app: AppSettings?
    var transcription: TranscriptionSettings
    var textImprovement: TextImprovementSettings
    var dampfAblassen: DampfAblassenSettings?
    var emojiText: EmojiTextSettings?
    var translate: TranslateSettings?
}
```
durch:
```swift
private struct SettingsContainer: Codable {
    var app: AppSettings?
    var transcription: TranscriptionSettings
    var textImprovement: TextImprovementSettings
    var dampfAblassen: DampfAblassenSettings?
    var emojiText: EmojiTextSettings?
}
```

- [ ] **Step 11: Sanity-Grep**

Run: `grep -n "translateSettings\|TranslateSettings\|TranslateWorkflow\|case .translate" BlitztextMac/App/AppState.swift`
Expected: keine Treffer.

- [ ] **Step 12: Commit**

```bash
git add BlitztextMac/App/AppState.swift
git commit -m "feat: AppState wrapped Workflows optional mit TranslatingWorkflow"
```

---

### Task 5: MenuBarStatusController.swift — `.translate`-Case entfernen

**Files:**
- Modify: `BlitztextMac/App/MenuBarStatusController.swift`

**Interfaces:**
- Consumes: `WorkflowType` ohne `.translate` (Task 1) — dieser Task macht die Datei wieder kompilierbar bezüglich exhaustiver Switches über `WorkflowType`.

- [ ] **Step 1: `drawActivityBadge` — `.translate`-Cases aus beiden `switch phase`-Blöcken entfernen**

Ersetze im `case .recording:`-Block:
```swift
            case .emojiText:
                values = [0.8, 0.92, 0.7, 1.0]
            case .translate:
                values = [0.7, 0.88, 1.0, 0.82]
            }
            badgeOpacity = values[frame % values.count]
            haloOpacity = 0.14 + (CGFloat(frame % 4) * 0.04)
```
durch:
```swift
            case .emojiText:
                values = [0.8, 0.92, 0.7, 1.0]
            }
            badgeOpacity = values[frame % values.count]
            haloOpacity = 0.14 + (CGFloat(frame % 4) * 0.04)
```

Ersetze im `case .processing:`-Block:
```swift
            case .emojiText:
                values = [0.54, 0.76, 0.88, 0.68]
            case .translate:
                values = [0.52, 0.74, 0.9, 0.74]
            }
            badgeOpacity = values[frame % values.count]
            haloOpacity = 0.12 + (CGFloat((frame + 2) % 4) * 0.03)
```
durch:
```swift
            case .emojiText:
                values = [0.54, 0.76, 0.88, 0.68]
            }
            badgeOpacity = values[frame % values.count]
            haloOpacity = 0.12 + (CGFloat((frame + 2) % 4) * 0.03)
```

- [ ] **Step 2: `recordingAlphaValues` — `.translate`-Case entfernen**

Ersetze:
```swift
        case .emojiText:
            let patterns: [[CGFloat]] = [
                [1.0, 0.7, 0.46, 0.28],
                [0.78, 1.0, 0.72, 0.42],
                [0.52, 0.82, 1.0, 0.66],
                [0.36, 0.58, 0.84, 1.0],
            ]
            return patterns[frame % patterns.count]
        case .translate:
            let patterns: [[CGFloat]] = [
                [1.0, 0.72, 0.5, 0.3],
                [0.76, 1.0, 0.74, 0.44],
                [0.54, 0.84, 1.0, 0.68],
                [0.38, 0.6, 0.86, 1.0],
            ]
            return patterns[frame % patterns.count]
        }
    }
```
durch:
```swift
        case .emojiText:
            let patterns: [[CGFloat]] = [
                [1.0, 0.7, 0.46, 0.28],
                [0.78, 1.0, 0.72, 0.42],
                [0.52, 0.82, 1.0, 0.66],
                [0.36, 0.58, 0.84, 1.0],
            ]
            return patterns[frame % patterns.count]
        }
    }
```

- [ ] **Step 3: `processingAlphaValues` — `.translate`-Case entfernen**

Ersetze:
```swift
        case .emojiText:
            let patterns: [[CGFloat]] = [
                [1.0, 0.8, 0.58, 0.4],
                [0.88, 1.0, 0.78, 0.54],
                [0.74, 0.9, 1.0, 0.7],
                [0.6, 0.76, 0.92, 1.0],
            ]
            return patterns[frame % patterns.count]
        case .translate:
            let patterns: [[CGFloat]] = [
                [1.0, 0.78, 0.56, 0.38],
                [0.86, 1.0, 0.76, 0.52],
                [0.72, 0.88, 1.0, 0.68],
                [0.58, 0.74, 0.9, 1.0],
            ]
            return patterns[frame % patterns.count]
        }
    }
```
durch:
```swift
        case .emojiText:
            let patterns: [[CGFloat]] = [
                [1.0, 0.8, 0.58, 0.4],
                [0.88, 1.0, 0.78, 0.54],
                [0.74, 0.9, 1.0, 0.7],
                [0.6, 0.76, 0.92, 1.0],
            ]
            return patterns[frame % patterns.count]
        }
    }
```

- [ ] **Step 4: `badgeSymbol(for:)` — `.translate`-Case entfernen**

Ersetze:
```swift
    private static func badgeSymbol(for type: WorkflowType) -> String {
        switch type {
        case .transcription:
            return "mic.fill"
        case .localTranscription:
            return "lock.shield.fill"
        case .textImprover:
            return "text.alignleft"
        case .dampfAblassen:
            return "flame.fill"
        case .emojiText:
            return "face.smiling"
        case .translate:
            return "globe"
        }
    }
```
durch:
```swift
    private static func badgeSymbol(for type: WorkflowType) -> String {
        switch type {
        case .transcription:
            return "mic.fill"
        case .localTranscription:
            return "lock.shield.fill"
        case .textImprover:
            return "text.alignleft"
        case .dampfAblassen:
            return "flame.fill"
        case .emojiText:
            return "face.smiling"
        }
    }
```

- [ ] **Step 5: Sanity-Grep**

Run: `grep -n "translate" BlitztextMac/App/MenuBarStatusController.swift`
Expected: keine Treffer.

- [ ] **Step 6: Commit**

```bash
git add BlitztextMac/App/MenuBarStatusController.swift
git commit -m "chore: .translate-Case aus MenuBarStatusController entfernen"
```

---

### Task 6: MenuBarView.swift — Toggle-UI & vereinheitlichte Active View

**Files:**
- Modify: `BlitztextMac/Features/MenuBar/MenuBarView.swift`

**Interfaces:**
- Consumes: `appState.appSettings.translationEnabled` (Task 1/4), `any Workflow` mit `audioLevel` (Task 1).
- Produces: `WorkflowActiveView` (neue, einzige Active View für alle 4 Workflows — ersetzt `TranscriptionActiveView`, `TextImproverActiveView`, `DampfAblassenActiveView`, `EmojiTextActiveView`, `TranslateActiveView`).

- [ ] **Step 1: Toggle-Panel zur `mainPage` hinzufügen**

Ersetze:
```swift
            transcriptionModePanel
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, appState.accessibilityPermissionGranted ? 6 : 4)

            if !appState.accessibilityPermissionGranted {
```
durch:
```swift
            transcriptionModePanel
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 6)

            translationTogglePanel
                .padding(.horizontal, 16)
                .padding(.bottom, appState.accessibilityPermissionGranted ? 6 : 4)

            if !appState.accessibilityPermissionGranted {
```

- [ ] **Step 2: `translationTogglePanel` als neue View ergänzen**

Füge direkt nach der bestehenden `transcriptionModePanel`-Property (nach ihrer schließenden `}` vor `private func modePanelSubtitle`) diese neue Property ein:

```swift
    private var translationTogglePanel: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(appState.appSettings.translationEnabled ? .blue : .secondary)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text("Übersetzen")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("Ausgabe zusätzlich in die Zielsprache übersetzen.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            Toggle("", isOn: $appState.appSettings.translationEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

```

- [ ] **Step 3: `workflowIconColor` — `.translate`-Case entfernen**

Ersetze:
```swift
    private func workflowIconColor(_ type: WorkflowType) -> Color {
        switch type {
        case .transcription:      return .blue
        case .localTranscription: return .green
        case .textImprover:       return .purple
        case .dampfAblassen:      return .orange
        case .emojiText:          return .cyan
        case .translate:          return .teal
        }
    }
```
durch:
```swift
    private func workflowIconColor(_ type: WorkflowType) -> Color {
        switch type {
        case .transcription:      return .blue
        case .localTranscription: return .green
        case .textImprover:       return .purple
        case .dampfAblassen:      return .orange
        case .emojiText:          return .cyan
        }
    }
```

- [ ] **Step 4: `workflowPage` — Content-Switch durch generische View ersetzen**

Ersetze:
```swift
                Divider()

                // Content
                switch workflow.type {
                case .transcription, .localTranscription:
                    if let w = workflow as? TranscriptionWorkflow {
                        TranscriptionActiveView(workflow: w)
                    }
                case .textImprover:
                    if let w = workflow as? TextImprovementWorkflow {
                        TextImproverActiveView(workflow: w)
                    }
                case .dampfAblassen:
                    if let w = workflow as? DampfAblassenWorkflow {
                        DampfAblassenActiveView(workflow: w)
                    }
                case .emojiText:
                    if let w = workflow as? EmojiTextWorkflow {
                        EmojiTextActiveView(workflow: w)
                    }
                case .translate:
                    if let w = workflow as? TranslateWorkflow {
                        TranslateActiveView(workflow: w)
                    }
                }

                Spacer(minLength: 0)
```
durch:
```swift
                Divider()

                // Content
                WorkflowActiveView(workflow: workflow)

                Spacer(minLength: 0)
```

- [ ] **Step 5: Alle 5 konkreten Active-View-Structs durch eine gemeinsame `WorkflowActiveView` ersetzen**

Entferne komplett die Structs `TranscriptionActiveView`, `TextImproverActiveView`, `DampfAblassenActiveView`, `EmojiTextActiveView` und `TranslateActiveView` (jeweils vom `// MARK: - ... Active View`-Kommentar bis zur schließenden `}` der jeweiligen Struct — das sind die 5 Blöcke direkt vor `// MARK: - Shared Result / Error Views`).

Füge an derselben Stelle **eine** neue Struct ein:

```swift
// MARK: - Workflow Active View

struct WorkflowActiveView: View {
    let workflow: any Workflow

    var body: some View {
        VStack(spacing: 0) {
            switch workflow.phase {
            case .idle, .running:
                if workflow.isRecording {
                    recordingView(onStop: { workflow.stop() })
                } else {
                    VStack(spacing: 12) {
                        Spacer().frame(height: 24)
                        ProgressView()
                            .scaleEffect(0.7)
                            .controlSize(.small)
                        if case .running(let msg) = workflow.phase {
                            Text(msg)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer().frame(height: 24)
                    }
                }

            case .done(let text):
                autoPasteView(text: text)

            case .error(let msg):
                errorView(message: msg) {
                    workflow.reset()
                    workflow.start()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private func recordingView(onStop: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 20)

            WaveformView(audioLevel: workflow.audioLevel, isRecording: true)
                .frame(height: 44)
                .padding(.horizontal, 24)

            // Monochrome stop button
            Button(action: onStop) {
                ZStack {
                    Circle()
                        .strokeBorder(.primary.opacity(0.2), lineWidth: 1.5)
                        .frame(width: 44, height: 44)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.primary.opacity(0.7))
                        .frame(width: 14, height: 14)
                }
            }
            .buttonStyle(.plain)

            Text("Ich höre zu … Klicke zum Stoppen.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Spacer().frame(height: 8)
        }
    }
}
```

Hinweis: Damit zeigt auch die reine Transkription jetzt die tatsächliche Phasen-Nachricht (z.B. „Wird transkribiert ...", bei aktivem Toggle danach „Wird übersetzt ...") statt der bisherigen fest codierten „Wird transkribiert …"-Meldung. Das ist beabsichtigt (siehe Task-Vorbemerkung zur Vereinheitlichung).

- [ ] **Step 6: Sanity-Grep**

Run: `grep -n "TranslateWorkflow\|TranslateActiveView\|TranslateSettings\|case .translate" BlitztextMac/Features/MenuBar/MenuBarView.swift`
Expected: keine Treffer.

Run: `grep -c "struct .*ActiveView" BlitztextMac/Features/MenuBar/MenuBarView.swift`
Expected: `1` (nur noch `WorkflowActiveView`).

- [ ] **Step 7: Commit**

```bash
git add BlitztextMac/Features/MenuBar/MenuBarView.swift
git commit -m "feat: globaler Übersetzungs-Toggle im Popover, vereinheitlichte Workflow Active View"
```

---

### Task 7: SettingsContentView.swift — Toggle & Pro-Workflow-Übersetzungssektionen

**Files:**
- Modify: `BlitztextMac/Features/Settings/SettingsContentView.swift`

**Interfaces:**
- Consumes: `appState.appSettings.translationEnabled`, `TranslationStepSettings`, `TargetLanguage.selectable`, `TranslateTone.allCases` (alle aus Task 1), `appState.transcriptionSettings.translation` / `.textImprovementSettings.translation` / `.dampfAblassenSettings.translation` / `.emojiTextSettings.translation`.
- Produces: `TranslationStepSettingsView` (privates, wiederverwendbares Subsection-View).

- [ ] **Step 1: Globalen Toggle nach der „Tastenkürzel"-Sektion einfügen**

Suche die Stelle direkt nach dem Ende der „Tastenkürzel"-`VStack` (nach `.pickerStyle(.segmented)` innerhalb des Mode-Pickers, vor `// MARK: Blitztext+`) und füge davor diese neue Sektion ein:

```swift
            // MARK: Übersetzung (global)
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Übersetzung")

                Toggle("Ausgabe übersetzen", isOn: $appState.appSettings.translationEnabled)
                    .toggleStyle(.switch)

                Text("Wenn aktiv, wird die Ausgabe jedes Workflows zusätzlich in die unten je Workflow eingestellte Zielsprache übersetzt.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // MARK: Blitztext (Transkription)
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Blitztext")

                TranslationStepSettingsView(settings: $appState.transcriptionSettings.translation)
            }

```

- [ ] **Step 2: Übersetzungs-Unterbereich in „Blitztext+" ergänzen**

Ersetze das Ende der „Blitztext+"-Sektion:
```swift
                // Context
                VStack(alignment: .leading, spacing: 8) {
                    Text("Kontext")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    TextField("z.B. \"E-Mails im Bereich Unternehmensberatung\"", text: $appState.textImprovementSettings.context)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }
            }
```
durch:
```swift
                // Context
                VStack(alignment: .leading, spacing: 8) {
                    Text("Kontext")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    TextField("z.B. \"E-Mails im Bereich Unternehmensberatung\"", text: $appState.textImprovementSettings.context)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }

                TranslationStepSettingsView(settings: $appState.textImprovementSettings.translation)
            }
```

- [ ] **Step 3: Übersetzungs-Unterbereich in „Blitztext $%&!" ergänzen**

Ersetze das Ende der „Blitztext $%&!"-Sektion:
```swift
                        .overlay(alignment: .topLeading) {
                            if appState.dampfAblassenSettings.systemPrompt.isEmpty {
                                Text("z.B. \"Formuliere den Text sachlich und freundlich um.\"")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.quaternary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 12)
                                    .allowsHitTesting(false)
                            }
                        }
                }
            }
```
durch:
```swift
                        .overlay(alignment: .topLeading) {
                            if appState.dampfAblassenSettings.systemPrompt.isEmpty {
                                Text("z.B. \"Formuliere den Text sachlich und freundlich um.\"")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.quaternary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 12)
                                    .allowsHitTesting(false)
                            }
                        }
                }

                TranslationStepSettingsView(settings: $appState.dampfAblassenSettings.translation)
            }
```

- [ ] **Step 4: „Blitztext 🌍"-Sektion durch Übersetzungs-Unterbereich in „Blitztext :)" ersetzen**

Ersetze:
```swift
            // MARK: Blitztext :)
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Blitztext :)")

                VStack(alignment: .leading, spacing: 8) {
                    Text("Emoji-Dichte")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Picker("", selection: $appState.emojiTextSettings.emojiDensity) {
                        ForEach(EmojiTextSettings.EmojiDensity.allCases) { density in
                            Text(density.displayName).tag(density)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            // MARK: Blitztext 🌍
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Blitztext 🌍")

                VStack(alignment: .leading, spacing: 8) {
                    Text("Zielsprache")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Picker("", selection: $appState.translateSettings.targetLanguage) {
                        ForEach(TranslateSettings.TargetLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Ton")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Picker("", selection: $appState.translateSettings.tone) {
                        ForEach(TranslateSettings.TranslateTone.allCases) { tone in
                            Text(tone.displayName).tag(tone)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
```
durch:
```swift
            // MARK: Blitztext :)
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Blitztext :)")

                VStack(alignment: .leading, spacing: 8) {
                    Text("Emoji-Dichte")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Picker("", selection: $appState.emojiTextSettings.emojiDensity) {
                        ForEach(EmojiTextSettings.EmojiDensity.allCases) { density in
                            Text(density.displayName).tag(density)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                TranslationStepSettingsView(settings: $appState.emojiTextSettings.translation)
            }
```

- [ ] **Step 5: `TranslationStepSettingsView` als neue private Struct ergänzen**

Füge am Ende der Datei, nach der `FlowLayout`-Struct, diese neue Struct ein:

```swift

// MARK: - Translation Step Settings (shared subsection)

private struct TranslationStepSettingsView: View {
    @Binding var settings: TranslationStepSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Übersetzung")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Picker("", selection: $settings.targetLanguage) {
                ForEach(TargetLanguage.selectable) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
            .pickerStyle(.segmented)

            Picker("", selection: $settings.tone) {
                ForEach(TranslateTone.allCases) { tone in
                    Text(tone.displayName).tag(tone)
                }
            }
            .pickerStyle(.segmented)

            TextField("Kontext (optional)", text: $settings.context)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
        }
    }
}
```

- [ ] **Step 6: Sanity-Grep**

Run: `grep -n "translateSettings\|TranslateSettings\|Blitztext 🌍" BlitztextMac/Features/Settings/SettingsContentView.swift`
Expected: keine Treffer.

- [ ] **Step 7: Commit**

```bash
git add BlitztextMac/Features/Settings/SettingsContentView.swift
git commit -m "feat: Übersetzungs-Einstellungen pro Workflow in den Settings"
```

---

### Task 8: Vollständiger Build & manueller Smoke-Test

**Files:** keine Code-Änderungen — nur Verifikation.

- [ ] **Step 1: Projektweiter Sanity-Grep auf Restreferenzen**

Run: `grep -rn "TranslateWorkflow\|TranslateSettings\|TranslateActiveView\|case .translate\|case translate$" BlitztextMac --include="*.swift"`
Expected: keine Treffer. Falls Treffer erscheinen, gehört jeweils die Datei zu einem der Tasks 1–7 nach — dort nachbessern und Task erneut committen.

- [ ] **Step 2: Vollständiger Build**

Run: `cd BlitztextMac && xcodebuild -project BlitztextMac.xcodeproj -scheme "Blitztext (Debug)" -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Manueller Smoke-Test im Debug-Build (aus der Spec übernommen)**

App im Debug-Scheme starten (Xcode Run oder Doppelklick auf das gebaute `.app`-Bundle) und der Reihe nach prüfen:

1. Popover öffnen → „Übersetzen"-Toggle ist sichtbar und standardmäßig aus.
2. Toggle im Popover an/aus schalten → Einstellungen-Tab „Anpassen" zeigt denselben Zustand (gleicher `appSettings.translationEnabled`-State).
3. Für jeden der 4 Workflows: Toggle an, Zielsprache in den Settings auf z.B. Englisch stellen, Aufnahme starten → „Wird übersetzt ..." erscheint nach der jeweiligen Vorverarbeitung, eingefügter Text ist auf Englisch. Toggle aus → Text bleibt Deutsch.
4. Für zwei verschiedene Workflows unterschiedliche Zielsprachen einstellen (z.B. Blitztext+ → Französisch, Blitztext :) → Spanisch) → jeweils die richtige Sprache wird verwendet.
5. `fn+T` drücken → Toggle wechselt sichtbar im Popover, ohne dass ein Workflow startet.
6. Bestehende `settings.json` unter `~/Library/Application Support/Blitztext Dev/settings.json` (falls vorhanden) vor dem Start sichern, App starten → keine Einstellungen gehen verloren (Migrations-Check aus Spec Abschnitt 2).
7. Übersetzung absichtlich fehlschlagen lassen (z.B. WLAN aus bei Remote-Backend) → Originaltext (Deutsch) wird trotzdem eingefügt, kein Absturz, kein hängender „Wird übersetzt ..."-Zustand.
8. Verbrauch-Tab im Settings zeigt einen zusätzlichen Eintrag für den Übersetzungs-Call, wenn Toggle an war.

- [ ] **Step 4: PLANNED_FEATURES.md aktualisieren**

Öffne `BlitztextMac/App/PLANNED_FEATURES.md` und ergänze unter „✅ Erledigt" einen neuen Eintrag für das heutige Datum:
```markdown
## ✅ Erledigt (05.07.2026)
- Übersetzung als globaler Toggle auf die 4 bestehenden Workflows (statt eigener 5. Menüeintrag)
```
(Direkt oberhalb des bestehenden „✅ Erledigt (03.07.2026)"-Blocks einfügen, oder als eigener neuer Block darüber — je nachdem was zum Zeitpunkt der Ausführung oben in der Datei steht.)

- [ ] **Step 5: Abschluss-Commit**

```bash
git add BlitztextMac/App/PLANNED_FEATURES.md
git commit -m "docs: Übersetzungs-Toggle in PLANNED_FEATURES.md als erledigt vermerkt"
```
