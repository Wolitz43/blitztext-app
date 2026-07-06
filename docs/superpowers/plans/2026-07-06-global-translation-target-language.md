# Globale Übersetzungs-Zielsprache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Die Übersetzungs-Zielsprache wird einmal global eingestellt (Settings + Popover) statt viermal pro Workflow; Ton und Kontext bleiben pro Workflow.

**Architecture:** Neues Feld `AppSettings.translationTargetLanguage` als einzige Quelle der Wahrheit. `TranslatingWorkflow` bekommt die Sprache als Init-Parameter von `AppState`. Am Ende wird `TranslationStepSettings.targetLanguage` ersatzlos entfernt (alte `settings.json` lädt weiter, JSONDecoder ignoriert unbekannte Schlüssel). Umsetzung in 4 Tasks, jeder einzeln baubar: erst additiv das globale Feld, dann Logik-Umstellung, dann UI, zuletzt Entfernen des alten Felds.

**Tech Stack:** Swift 5.10, SwiftUI, macOS 14+, Xcode-Projekt `BlitztextMac/BlitztextMac.xcodeproj`, Scheme `Blitztext (Debug)`.

**Spec:** `docs/superpowers/specs/2026-07-06-global-translation-target-language-design.md`

## Global Constraints

- **NIEMALS `xcodegen generate` ausführen** — zerstört die manuell gepflegten Schemes im gitignorten `.xcodeproj` (siehe `CLAUDE.md`).
- **Keine neuen Dateien anlegen, keine Dateien verschieben/umbenennen** — das pbxproj referenziert feste Pfade; alle Änderungen erfolgen in bestehenden Dateien.
- Es gibt **kein Test-Target**. Verifikation pro Task: `xcodebuild -project BlitztextMac/BlitztextMac.xcodeproj -scheme "Blitztext (Debug)" -derivedDataPath .derivedData-blitztextmac-build build` muss mit `** BUILD SUCCEEDED **` enden. Arbeitsverzeichnis: Repo-Root `/Users/arndstielow/Documents/blitztext-app`.
- UI-Texte auf Deutsch, im Stil der bestehenden Views (Fontgrößen 10.5/11, `SectionLabel`, segmented Picker).
- Default-Zielsprache: Englisch (`.english`). Keine Migration alter per-Workflow-Sprachen.
- `TargetLanguage.selectable` (Englisch, Französisch, Spanisch, Italienisch) bleibt unverändert.
- Commit-Messages auf Deutsch im Repo-Stil (`feat:`/`chore:`), jeweils mit Trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Globales Feld `translationTargetLanguage` in `AppSettings`

**Files:**
- Modify: `BlitztextMac/Features/Workflows/WorkflowProtocol.swift:122-170` (struct `AppSettings`)

**Interfaces:**
- Consumes: bestehendes `enum TargetLanguage` (gleiche Datei, Zeile ~185), Fall `.english`.
- Produces: `AppSettings.translationTargetLanguage: TargetLanguage` — von Task 2 (AppState, TranslatingWorkflow) und Task 3 (UI-Bindings) genutzt.

Rein additiv, bricht nichts. `AppSettings` hat einen Custom-Decoder mit `decodeIfPresent`-Fallbacks — das neue Feld folgt exakt diesem Muster, damit alte `settings.json` ohne den Schlüssel weiter laden.

- [ ] **Step 1: Feld ergänzen**

In `BlitztextMac/Features/Workflows/WorkflowProtocol.swift` die struct `AppSettings` an vier Stellen erweitern (jeweils nach `translationEnabled`):

Property (nach Zeile `var translationEnabled: Bool = false`):

```swift
    var translationEnabled: Bool = false
    var translationTargetLanguage: TargetLanguage = .english
```

Memberwise-Init — Parameterliste und Zuweisung:

```swift
    init(
        hotkeyMode: HotkeyMode = .hold,
        hasSeenOnboarding: Bool = false,
        secureLocalModeEnabled: Bool = false,
        selectedLocalTranscriptionModelName: String = LocalTranscriptionService.recommendedFastModelName,
        hasAutoSelectedFastLocalModel: Bool = false,
        translationEnabled: Bool = false,
        translationTargetLanguage: TargetLanguage = .english
    ) {
        self.hotkeyMode = hotkeyMode
        self.hasSeenOnboarding = hasSeenOnboarding
        self.secureLocalModeEnabled = secureLocalModeEnabled
        self.selectedLocalTranscriptionModelName = selectedLocalTranscriptionModelName
        self.hasAutoSelectedFastLocalModel = hasAutoSelectedFastLocalModel
        self.translationEnabled = translationEnabled
        self.translationTargetLanguage = translationTargetLanguage
    }
```

CodingKeys:

```swift
    enum CodingKeys: String, CodingKey {
        case hotkeyMode
        case hasSeenOnboarding
        case secureLocalModeEnabled
        case selectedLocalTranscriptionModelName
        case hasAutoSelectedFastLocalModel
        case translationEnabled
        case translationTargetLanguage
    }
```

Custom-Decoder (nach der `translationEnabled`-Zeile):

```swift
        translationEnabled = try container.decodeIfPresent(Bool.self, forKey: .translationEnabled) ?? false
        translationTargetLanguage = try container.decodeIfPresent(
            TargetLanguage.self,
            forKey: .translationTargetLanguage
        ) ?? .english
```

- [ ] **Step 2: Build verifizieren**

Run (Repo-Root): `xcodebuild -project BlitztextMac/BlitztextMac.xcodeproj -scheme "Blitztext (Debug)" -derivedDataPath .derivedData-blitztextmac-build build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add BlitztextMac/Features/Workflows/WorkflowProtocol.swift
git commit -m "feat: globale Übersetzungs-Zielsprache als AppSettings-Feld

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `TranslatingWorkflow` und `AppState` nutzen die globale Sprache

**Files:**
- Modify: `BlitztextMac/Features/Workflows/TranslatingWorkflow.swift` (init, `buildTranslationPrompt`)
- Modify: `BlitztextMac/App/AppState.swift:119-124` (`workflowSubtitle`) und `:253-262` (Wrapper-Aufbau in `startWorkflow`)

**Interfaces:**
- Consumes: `AppSettings.translationTargetLanguage: TargetLanguage` (Task 1); bestehendes `TargetLanguage.englishName: String`, `TargetLanguage.displayName: String`.
- Produces: `TranslatingWorkflow.init(inner: any Workflow, settings: TranslationStepSettings, targetLanguage: TargetLanguage, llmBackend: LLMBackend)` — ab jetzt die einzige Init-Signatur.

Nach diesem Task liest keine Logik mehr `TranslationStepSettings.targetLanguage`; das Feld existiert nur noch für die UI (wird in Task 3/4 entfernt).

- [ ] **Step 1: `TranslatingWorkflow.swift` umstellen**

Stored Property, Init und Prompt-Bau ändern. Kopf der Klasse (Zeilen 6-34) neu:

```swift
final class TranslatingWorkflow: Workflow {
    private let inner: any Workflow
    private let settings: TranslationStepSettings
    private let targetLanguage: TargetLanguage
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

    init(
        inner: any Workflow,
        settings: TranslationStepSettings,
        targetLanguage: TargetLanguage,
        llmBackend: LLMBackend
    ) {
        self.inner = inner
        self.settings = settings
        self.targetLanguage = targetLanguage
        self.llmBackend = llmBackend

        inner.onPhaseChange = { [weak self] phase in
            self?.handleInnerPhaseChange(phase)
        }
        inner.onUsage = { [weak self] record in
            self?.onUsage?(record)
        }
    }
```

In `translate(_:)` den Prompt-Aufruf (Zeile ~70) anpassen — die Sprache wird zusätzlich lokal gebunden:

```swift
        let stepSettings = settings
        let language = targetLanguage
        let backend = llmBackend
        let workflowType = type

        translationTask = Task {
            do {
                let systemPrompt = Self.buildTranslationPrompt(
                    settings: stepSettings,
                    targetLanguage: language
                )
```

`buildTranslationPrompt` (Zeilen 107-134) — Signatur um `targetLanguage` erweitert, erste Zeile liest den Parameter statt `settings.targetLanguage`:

```swift
    private static func buildTranslationPrompt(
        settings: TranslationStepSettings,
        targetLanguage: TargetLanguage
    ) -> String {
        let targetLang = targetLanguage.englishName
```

(Rest der Methode — `toneInstruction`, Prompt-Text, Kontext-Anhang — unverändert.)

- [ ] **Step 2: `AppState.swift` umstellen**

`workflowSubtitle(for:)` (Zeile 119-124) — globale Sprache statt per-Workflow:

```swift
    func workflowSubtitle(for type: WorkflowType) -> String {
        let base = baseWorkflowSubtitle(for: type)
        guard appSettings.translationEnabled else { return base }
        let lang = appSettings.translationTargetLanguage.displayName
        return "\(base) → \(lang)"
    }
```

Wrapper-Aufbau in `startWorkflow` (Zeile 253-262) — neuen Parameter durchreichen:

```swift
        let workflow: any Workflow
        if appSettings.translationEnabled {
            workflow = TranslatingWorkflow(
                inner: builtWorkflow,
                settings: translationStepSettings(for: type),
                targetLanguage: appSettings.translationTargetLanguage,
                llmBackend: resolvedLLMBackend
            )
        } else {
            workflow = builtWorkflow
        }
```

`translationStepSettings(for:)` (Zeile 149-160) bleibt unverändert bestehen (liefert weiterhin Ton/Kontext pro Workflow).

- [ ] **Step 3: Build verifizieren**

Run: `xcodebuild -project BlitztextMac/BlitztextMac.xcodeproj -scheme "Blitztext (Debug)" -derivedDataPath .derivedData-blitztextmac-build build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Verifizieren, dass die Logik das alte Feld nicht mehr liest**

Run: `grep -rn "\.targetLanguage" BlitztextMac --include="*.swift"`
Expected: Treffer nur noch in `TranslatingWorkflow.swift` (`self.targetLanguage = targetLanguage` im Init) und `SettingsContentView.swift` (`$settings.targetLanguage` im UI-Binding, wird in Task 3 entfernt). **Keine** Treffer in `AppState.swift`.

- [ ] **Step 5: Commit**

```bash
git add BlitztextMac/Features/Workflows/TranslatingWorkflow.swift BlitztextMac/App/AppState.swift
git commit -m "feat: TranslatingWorkflow und AppState nutzen die globale Zielsprache

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: UI — globaler Sprach-Picker in Settings und Popover

**Files:**
- Modify: `BlitztextMac/Features/Settings/SettingsContentView.swift:670-681` (globale Übersetzungs-Sektion) und `:906-935` (`TranslationStepSettingsView`)
- Modify: `BlitztextMac/Features/MenuBar/MenuBarView.swift:219-249` (`translationTogglePanel`)

**Interfaces:**
- Consumes: `AppSettings.translationTargetLanguage` (Task 1), bestehendes `TargetLanguage.selectable: [TargetLanguage]` und `TargetLanguage.displayName`.
- Produces: keine neuen Schnittstellen (reine View-Änderungen).

- [ ] **Step 1: Globalen Sprach-Picker in `SettingsContentView.swift` einfügen**

Die Sektion „Übersetzung (global)" (Zeile 670-681) wird zu:

```swift
            // MARK: Übersetzung (global)
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Übersetzung")

                Toggle("Ausgabe übersetzen", isOn: $appState.appSettings.translationEnabled)
                    .toggleStyle(.switch)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Zielsprache")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Picker("", selection: $appState.appSettings.translationTargetLanguage) {
                        ForEach(TargetLanguage.selectable) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Text("Wenn aktiv, wird die Ausgabe jedes Workflows zusätzlich in die hier eingestellte Zielsprache übersetzt.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
```

(Beachte den geänderten Erklärtext: „in die hier eingestellte Zielsprache" statt „in die unten je Workflow eingestellte Zielsprache".)

- [ ] **Step 2: Sprach-Picker aus `TranslationStepSettingsView` entfernen**

`TranslationStepSettingsView` (Zeile 908-935) verliert den `targetLanguage`-Picker, Ton-Picker und Kontext-Feld bleiben:

```swift
private struct TranslationStepSettingsView: View {
    @Binding var settings: TranslationStepSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Übersetzung")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

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

- [ ] **Step 3: Sprach-Dropdown im Popover (`MenuBarView.swift`) ergänzen**

Im `translationTogglePanel` (Zeile 219-249) zwischen `Spacer` und `Toggle` ein kompaktes Menü-Dropdown einfügen; es ist unabhängig vom Toggle-Zustand bedienbar:

```swift
            Spacer(minLength: 4)

            Picker("", selection: $appState.appSettings.translationTargetLanguage) {
                ForEach(TargetLanguage.selectable) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()

            Toggle("", isOn: $appState.appSettings.translationEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
```

- [ ] **Step 4: Build verifizieren**

Run: `xcodebuild -project BlitztextMac/BlitztextMac.xcodeproj -scheme "Blitztext (Debug)" -derivedDataPath .derivedData-blitztextmac-build build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add BlitztextMac/Features/Settings/SettingsContentView.swift BlitztextMac/Features/MenuBar/MenuBarView.swift
git commit -m "feat: globaler Zielsprachen-Picker in Settings und Popover

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: `targetLanguage` aus `TranslationStepSettings` entfernen

**Files:**
- Modify: `BlitztextMac/Features/Workflows/WorkflowProtocol.swift:179-183` (struct `TranslationStepSettings`)

**Interfaces:**
- Consumes: nichts Neues; setzt voraus, dass nach Task 2+3 keine Referenz auf `TranslationStepSettings.targetLanguage` mehr existiert.
- Produces: finale Form `struct TranslationStepSettings: Codable { var tone: TranslateTone; var context: String }`.

Abwärtskompatibilität: `TranslationStepSettings` nutzt synthetisiertes Codable ohne Custom-Decoder — `JSONDecoder` ignoriert den alten `targetLanguage`-Schlüssel in bestehenden `settings.json` einfach.

- [ ] **Step 1: Vorbedingung prüfen — keine Referenzen mehr**

Run: `grep -rn "\.targetLanguage" BlitztextMac --include="*.swift"`
Expected: Treffer nur noch in `TranslatingWorkflow.swift` (`self.targetLanguage = targetLanguage` — das ist die neue globale Sprache, nicht das alte Feld). Kein Treffer mehr auf `TranslationStepSettings.targetLanguage` in `SettingsContentView.swift` oder `AppState.swift`. (Falls doch: Task 2/3 unvollständig — dort nacharbeiten, nicht hier.)

- [ ] **Step 2: Feld entfernen**

`TranslationStepSettings` (Zeile 179-183) wird zu:

```swift
struct TranslationStepSettings: Codable {
    var tone: TranslateTone = .neutral
    var context: String = ""
}
```

- [ ] **Step 3: Build verifizieren**

Run: `xcodebuild -project BlitztextMac/BlitztextMac.xcodeproj -scheme "Blitztext (Debug)" -derivedDataPath .derivedData-blitztextmac-build build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Funktions-Smoke (automatisierbar)**

App kurz starten und wieder beenden, um zu prüfen, dass die bestehende `settings.json` (Debug-Pfad `~/Library/Application Support/Blitztext Dev/`) fehlerfrei lädt:

Run: `.derivedData-blitztextmac-build/Build/Products/Debug/Blitztext\ Dev.app/Contents/MacOS/Blitztext\ Dev & sleep 8; kill %1`
Expected: Prozess läuft 8 Sekunden ohne Absturz, kein Fatal-Error-Output. (Interaktive UI-Prüfung — Picker-Sync Popover↔Settings, tatsächliche Übersetzung — bleibt manueller Test, siehe Plan-Abschluss.)

- [ ] **Step 5: Commit**

```bash
git add BlitztextMac/Features/Workflows/WorkflowProtocol.swift
git commit -m "chore: targetLanguage aus TranslationStepSettings entfernt (jetzt global)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Abschluss / Manueller Test (Mensch)

Nach Task 4 in `BlitztextMac/App/PLANNED_FEATURES.md` im Handoff-Abschnitt vermerken, dass die Zielsprache jetzt global ist (Checkliste Punkt 3/4 des alten Smoke-Tests entsprechend anpassen: statt „pro Workflow unterschiedliche Zielsprachen" jetzt „globale Zielsprache wirkt auf alle 4 Workflows; Ton/Kontext weiterhin pro Workflow").

Manuelle Prüfpunkte (kann keine KI-Session ausführen):
1. Popover: Sprach-Dropdown neben dem Übersetzen-Toggle sichtbar, Wechsel dort spiegelt sich sofort im Settings-Tab „Anpassen" (und umgekehrt).
2. Workflow-Lauf mit Toggle an → Ausgabe in der global gewählten Sprache; Untertitel der Workflow-Zeilen zeigen „→ <Sprache>".
3. Ton/Kontext pro Workflow wirken weiterhin (z.B. Formell vs. Locker).
