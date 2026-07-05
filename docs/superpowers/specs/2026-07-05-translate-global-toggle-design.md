# Übersetzung als globaler Toggle statt eigener Workflow

Stand: 2026-07-05

## Kontext

Blitztext hat aktuell 4 Haupt-Workflows im Menü (Transkription, Textverbesserer
„Blitztext+", Dampf ablassen, Emoji-Text) plus einen 5. Eintrag „Blitztext 🌍"
(`.translate`), der ausschließlich Deutsch → Zielsprache übersetzt. Dieser
5. Eintrag ist bereits (uncommitted) vollständig implementiert
(`TranslateWorkflow.swift`, `TranslateSettings.swift`, Integration in
`AppState`, `MenuBarView`, `SettingsContentView`, `HotkeyService`).

Diese Form wurde verworfen: ein isolierter „nur Übersetzen"-Eintrag ist die
falsche Form. Stattdessen soll Übersetzung ein **Modifier** sein, der auf die
4 bestehenden Workflows anwendbar ist — man nimmt z.B. weiterhin
„Blitztext+" (Textverbesserer), bekommt aber zusätzlich eine Übersetzung des
Ergebnisses, wenn ein globaler Schalter aktiv ist.

## Ziel

- Ein globaler Toggle (`translationEnabled`) entscheidet, ob die Ausgabe
  eines Workflow-Laufs zusätzlich übersetzt wird — für **alle 4** Workflows
  (auch reine Transkription, die aktuell keinen LLM-Schritt hat).
- Jeder der 4 Workflows hat eine **eigene** Übersetzungs-Konfiguration
  (Zielsprache, Ton, Kontext) — keine gemeinsame Einstellung.
- Der bisherige 5. Menüeintrag (`.translate`, `TranslateWorkflow`,
  `TranslateSettings`, zugehöriger Hotkey `fn+T` als Workflow-Start) entfällt
  vollständig.

## Architektur

### TranslatingWorkflow (neu)

Neue Datei `BlitztextMac/Features/Workflows/TranslatingWorkflow.swift`:

```swift
@Observable
@MainActor
final class TranslatingWorkflow: Workflow {
    private let inner: any Workflow
    private let settings: TranslationStepSettings
    private let llmBackend: LLMBackend
    // type, isRecording etc. delegieren an inner
}
```

- `type`, `isRecording`, `audioLevel` (falls vorhanden) werden 1:1 an `inner`
  weitergereicht.
- `start()` / `stop()` / `reset()` rufen nur die entsprechende Methode auf
  `inner` auf.
- Vor `inner.start()` hängt sich der Wrapper an `inner.onPhaseChange`,
  `inner.onOutput`, `inner.onUsage`:
  - Phasenwechsel von `inner` werden 1:1 durchgereicht, **außer**
    `.done(text)`: hier setzt der Wrapper `phase = .running("Wird übersetzt ...")`,
    ruft `LLMService.translate(text:systemPrompt:backend:)` auf (gleiche
    Logik/Prompt-Aufbau wie im bisherigen `TranslateWorkflow.buildTranslationPrompt`)
    und setzt danach `.done(translatedText)` + `onOutput?(translatedText)`.
  - `onUsage`-Records von `inner` werden durchgereicht; zusätzlich meldet der
    Wrapper einen eigenen `UsageRecord` für den Übersetzungs-Call.
  - Schlägt die Übersetzung fehl: siehe Abschnitt „Fehlerbehandlung" unten —
    kein Datenverlust, Fallback auf Originaltext.

### AppState.startWorkflow

Baut den jeweiligen Workflow wie bisher, wrapped ihn danach optional:

```swift
var workflow: any Workflow = /* wie bisher je nach `type` gebaut */
if appSettings.translationEnabled, let stepSettings = translationStepSettings(for: type) {
    workflow = TranslatingWorkflow(inner: workflow, settings: stepSettings, llmBackend: resolvedLLMBackend)
}
configureWorkflowHandlers(workflow)
activeWorkflow = workflow
workflow.start()
```

`translationStepSettings(for:)` liest je nach `type` das passende
`.translation`-Feld aus `transcriptionSettings` / `textImprovementSettings` /
`dampfAblassenSettings` / `emojiTextSettings`.

Die 4 bestehenden Workflow-Klassen (`TranscriptionWorkflow`,
`TextImprovementWorkflow`, `DampfAblassenWorkflow`, `EmojiTextWorkflow`)
bleiben unverändert.

### Entfernt

- `TranslateWorkflow.swift`, `TranslateSettings.swift`
- `WorkflowType.translate` (Case, `displayName`, `icon`, `subtitle`,
  `hotkeyLabel`, `accentColor`)
- `AppState.translateSettings`, zugehörige Load/Save-Funktionen
- `translate`-Feld in `SettingsContainer`
- `.translate`-Icon-Handling in `MenuBarStatusController.swift`
- Zugehörige UI (Menüeintrag, `TranslateActiveView` falls vorhanden)

## Datenmodell / Settings

### TranslationStepSettings (neu, ersetzt Kern von TranslateSettings)

```swift
struct TranslationStepSettings: Codable {
    var targetLanguage: TargetLanguage = .english
    var tone: TranslateTone = .neutral
    var context: String = ""
}
```

Kein `enabled`-Feld hier — *ob* übersetzt wird, entscheidet ausschließlich
der globale Toggle (`appSettings.translationEnabled`). Pro Workflow wird nur
konfiguriert, *in welche Sprache/welchem Ton*.

`TargetLanguage` und `TranslateTone` wandern unverändert (nur der Ort ändert
sich) aus `TranslateSettings.swift` z.B. nach `WorkflowProtocol.swift`, wo die
übrigen Settings-Structs liegen.

`TargetLanguage` behält alle 8 bestehenden Fälle (Englisch, Französisch,
Spanisch, Italienisch, Portugiesisch, Niederländisch, Polnisch, Japanisch)
für spätere Erweiterung, aber es gilt:

```swift
extension TargetLanguage {
    static let selectable: [TargetLanguage] = [.english, .french, .spanish, .italian]
}
```

Alle UI-Picker verwenden `TargetLanguage.selectable` statt `allCases`. Nur
Englisch, Französisch, Spanisch und Italienisch sind aktuell auswählbar.

### Erweiterung der 4 bestehenden Settings-Structs

```swift
struct TranscriptionSettings: Codable {
    var language: String = "de"
    var translation: TranslationStepSettings = .init()
}
// analog: TextImprovementSettings, DampfAblassenSettings, EmojiTextSettings
// bekommen jeweils ein zusätzliches `var translation: TranslationStepSettings = .init()`
```

### AppSettings

Neues Feld:

```swift
var translationEnabled: Bool = false
```

Ergänzt `CodingKeys` und das bestehende `init(from:)` von `AppSettings`
(analog zu den anderen optionalen Feldern dort), damit alte `settings.json`
ohne dieses Feld weiterhin sauber lädt.

### Migrations-Vorsicht (wichtig)

`TranscriptionSettings`, `TextImprovementSettings`, `DampfAblassenSettings`,
`EmojiTextSettings` nutzen aktuell **synthesized** `Codable` ohne eigenes
`init(from:)`. Ein neues nicht-optionales Feld (`translation`) würde beim
Laden einer alten, bereits gespeicherten `settings.json` (Feld fehlt im JSON)
zu einem kompletten Decode-Fehlschlag führen → `loadContainer()` liefert
`nil` → **alle** Settings fallen auf Defaults zurück, nicht nur das neue
Feld.

Deshalb bekommen alle 4 Structs ein eigenes `init(from:)` mit
`decodeIfPresent(TranslationStepSettings.self, forKey: .translation) ?? .init()`,
nach demselben Muster, das `AppSettings` bereits für seine eigenen optionalen
Felder verwendet.

### SettingsContainer

Das `translate: TranslateSettings?`-Feld wird ersatzlos entfernt (war schon
optional, kein Migrationsproblem).

## UI-Änderungen

- **Popover-Hauptseite** (`MenuBarView.swift`): neuer Toggle „Übersetzen" im
  Bereich der Modus-Auswahl, bindet an `appState.appSettings.translationEnabled`.
  Ist er an, hängen die Untertitel der 4 Workflow-Buttons `→ <Zielsprache>` an
  (z.B. „Geschrieben sprechen. → Englisch"), Zielsprache aus dem jeweiligen
  `translation.targetLanguage`.
- **Settings** (`SettingsContentView.swift`): derselbe Toggle (gleicher
  State, gespiegelt), zusätzlich pro Workflow-Sektion (Textverbesserer, Dampf
  ablassen, Emoji-Text, Transkription) ein neuer Unterbereich „Übersetzung"
  mit Picker für Zielsprache (`TargetLanguage.selectable`), Picker für Ton
  (formal/neutral/locker) und Textfeld für Kontext.
- **`.translate`-Menüeintrag**: vollständig entfernt (inkl. zugehöriger
  aktiver Ansicht, falls als eigene View existent).
- **Menübar-Status-Icon** (`MenuBarStatusController.swift`): `.translate`-Case
  aus allen `switch`-Statements entfernt (Icon-Patterns, SF-Symbol-Mapping).

## Hotkey für den Toggle

`fn+T` bleibt als Kombination bestehen, wechselt aber die Bedeutung: statt
einen `.translate`-Workflow zu starten, schaltet er
`appSettings.translationEnabled` um.

- **`HotkeyService`**: `handleFnT()` feuert nicht mehr
  `onHotkeyEvent?(.down(.translate))` / `.up(.translate)`, sondern einen
  neuen, eigenständigen Closure `var onToggleTranslation: (() -> Void)?`, der
  bei `fn+T` (keyDown) einmal aufgerufen wird. Das entkoppelt den Toggle vom
  `HotkeyEvent`/`WorkflowType`-Mechanismus, der nur noch die 4 echten
  Workflows kennt.
- **`AppDelegate`** (`BlitztextMacApp.swift`): verdrahtet
  `appState.hotkeyService.onToggleTranslation = { [weak self] in
  self?.appState.appSettings.translationEnabled.toggle() }`, analog zur
  bestehenden `onHotkeyEvent`-Verdrahtung.
- Kein zusätzliches visuelles Feedback über den Menübar-Status (kein
  Recording/Processing-State für einen reinen Settings-Toggle).

## Fehlerbehandlung

Schlägt der Übersetzungs-Call in `TranslatingWorkflow` fehl (Netzwerkfehler,
Apple Intelligence nicht verfügbar, etc.), wird die bereits fertige Ausgabe
des inneren Workflows **nicht verworfen**: der Wrapper fällt auf den
unübersetzten Originaltext zurück (der wird normal eingefügt/kopiert), zeigt
aber kurz `.error("Übersetzung fehlgeschlagen – Originaltext eingefügt")`,
bevor er auf `.done(originalText)` wechselt. So geht die eigentliche
Aufnahme/Verbesserung nie verloren, nur die Übersetzung selbst fällt aus.

Der Verfügbarkeits-Check (`AppState.isWorkflowAvailable`) bleibt unverändert
— Übersetzung nutzt dasselbe LLM-Backend (`resolvedLLMBackend`) wie der
jeweilige Workflow selbst, kein zusätzlicher Konfigurationscheck nötig.

## Testing (manuell, wie bisher im Projekt üblich)

Kein eigenes Test-Target im Projekt (nur SPM-Dependency-Tests) — Verifikation
läuft wie bei den bisherigen Features manuell im Debug-Build:

1. Build im Debug-Scheme.
2. Toggle im Popover an/aus schalten, Sync mit Settings-Ansicht prüfen.
3. Für jeden der 4 Workflows: Toggle an → Aufnahme starten → „Wird übersetzt
   ..." erscheint, eingefügter Text kommt in der konfigurierten Zielsprache
   an; Toggle aus → Text bleibt deutsch.
4. Pro Workflow unterschiedliche Zielsprache einstellen, prüfen dass jeweils
   die richtige verwendet wird.
5. `fn+T` drücken → Toggle wechselt, UI (Popover + Settings) aktualisiert
   sich synchron.
6. Bestehende `settings.json` (vor diesem Feature gespeichert) laden → App
   startet ohne Reset auf Defaults (Migrations-Check).
7. Übersetzung absichtlich fehlschlagen lassen (z.B. Flugmodus bei
   Remote-Backend) → Originaltext wird trotzdem eingefügt, Fehlermeldung kurz
   sichtbar.
8. Usage-Tracker zeigt zusätzlichen Eintrag für den Übersetzungs-Call.

## Betroffene Dateien

- Neu: `BlitztextMac/Features/Workflows/TranslatingWorkflow.swift`
- Gelöscht: `BlitztextMac/App/TranslateWorkflow.swift`,
  `BlitztextMac/App/TranslateSettings.swift`
- Geändert: `BlitztextMac/Features/Workflows/WorkflowProtocol.swift`
  (Settings-Structs, `TranslationStepSettings`, `TargetLanguage`,
  `TranslateTone`, `WorkflowType` ohne `.translate`)
- Geändert: `BlitztextMac/App/AppState.swift` (Wrapping-Logik,
  Settings-Persistenz, `translateSettings` entfernt)
- Geändert: `BlitztextMac/App/BlitztextMacApp.swift` (Hotkey-Verdrahtung)
- Geändert: `BlitztextMac/Services/HotkeyService.swift`
  (`onToggleTranslation`)
- Geändert: `BlitztextMac/Features/MenuBar/MenuBarView.swift` (Toggle,
  Untertitel-Anpassung, Entfernen des `.translate`-Eintrags)
- Geändert: `BlitztextMac/Features/Settings/SettingsContentView.swift`
  (Toggle, Übersetzungs-Unterbereich pro Workflow)
- Geändert: `BlitztextMac/App/MenuBarStatusController.swift` (`.translate`
  aus allen Switches entfernt)
- Geändert: `BlitztextMac/Services/LLMService.swift` (bestehende
  `translate()`-Methode bleibt, wird jetzt von `TranslatingWorkflow` statt
  `TranslateWorkflow` aufgerufen)
