# Globale Zielsprache für die Übersetzung

Stand: 2026-07-06

## Kontext

Der globale Übersetzungs-Toggle (Spec
`2026-07-05-translate-global-toggle-design.md`) hat pro Workflow eine eigene
Übersetzungs-Konfiguration eingeführt: Jeder der 4 Workflow-Settings-Structs
(`TranscriptionSettings`, `TextImprovementSettings`, `DampfAblassenSettings`,
`EmojiTextSettings`) hält ein `TranslationStepSettings` mit `targetLanguage`,
`tone` und `context`.

In der Praxis ist die per-Workflow-Zielsprache unnötig: Man übersetzt in der
Regel in **eine** Sprache, egal über welchen Workflow. Die Zielsprache soll
deshalb **einmal global** eingestellt werden. Ton und Kontext bleiben
bewusst pro Workflow (Entscheidung vom 2026-07-06).

## Ziel

- Eine globale Zielsprache `translationTargetLanguage` in `AppSettings`,
  gültig für alle 4 Workflows.
- `TranslationStepSettings` enthält nur noch `tone` und `context`
  (pro Workflow, unverändert einstellbar).
- Die Zielsprache ist an zwei Orten wählbar:
  1. Settings, Tab „Anpassen", direkt beim globalen Toggle
     „Ausgabe übersetzen".
  2. Menüleisten-Popover, kompaktes Dropdown neben dem Übersetzen-Toggle.
- Keine Migration alter per-Workflow-Sprachen: Das Feature ist frisch
  gemerged und wurde nie produktiv genutzt; die globale Sprache startet mit
  dem Default Englisch.

## Nicht-Ziele

- Ton/Kontext bleiben pro Workflow (keine Globalisierung).
- Keine Erweiterung der wählbaren Sprachen
  (`TargetLanguage.selectable` bleibt: Englisch, Französisch, Spanisch,
  Italienisch).
- Kein neues Verhalten bei Übersetzungsfehlern (Originaltext wird weiterhin
  kommentarlos eingefügt — bekannte, separat zu behandelnde Einschränkung).

## Datenmodell (`WorkflowProtocol.swift`)

### AppSettings

Neues Feld nach dem Muster der bestehenden Felder (Default im Property,
`decodeIfPresent`-Fallback im Custom-Decoder, Eintrag in `CodingKeys` und
im Memberwise-Init):

```swift
var translationTargetLanguage: TargetLanguage = .english
```

### TranslationStepSettings

`targetLanguage` wird ersatzlos entfernt:

```swift
struct TranslationStepSettings: Codable {
    var tone: TranslateTone = .neutral
    var context: String = ""
}
```

Abwärtskompatibilität: `JSONDecoder` ignoriert unbekannte Schlüssel — alte
`settings.json`-Dateien mit `translation.targetLanguage` laden ohne Fehler,
der Wert wird verworfen.

## Workflow-Logik

### TranslatingWorkflow.swift

`init` bekommt die Zielsprache als eigenen Parameter:

```swift
init(inner: any Workflow,
     settings: TranslationStepSettings,
     targetLanguage: TargetLanguage,
     llmBackend: LLMBackend)
```

`buildTranslationPrompt` nutzt den neuen Parameter statt
`settings.targetLanguage`; Ton- und Kontext-Handling unverändert.

### AppState.swift

- Beim Wrappen der Workflows (`if appSettings.translationEnabled { ... }`)
  wird zusätzlich `targetLanguage: appSettings.translationTargetLanguage`
  übergeben.
- `workflowSubtitle` (Anzeige „→ Englisch" etc.) liest
  `appSettings.translationTargetLanguage.displayName` statt
  `translationStepSettings(for: type).targetLanguage`.
- `translationStepSettings(for:)` bleibt für Ton/Kontext bestehen.
- Workflows samt Wrapper werden bei jedem Workflow-Start frisch gebaut
  (verifiziert in `startWorkflow`, `AppState.swift:253-266`) — eine
  geänderte globale Sprache greift damit automatisch ab dem nächsten Lauf.

## UI

### SettingsContentView.swift (Tab „Anpassen")

- Unter dem globalen Toggle „Ausgabe übersetzen" erscheint einmalig ein
  Picker „Zielsprache" über `TargetLanguage.selectable`, gebunden an
  `$appState.appSettings.translationTargetLanguage`.
- `TranslationStepSettingsView` (in den 4 Workflow-Unterabschnitten) verliert
  den Sprach-Picker und zeigt nur noch Ton-Picker und Kontext-Feld.

### MenuBarView.swift (Popover)

Im `translationTogglePanel` neben dem An/Aus-Toggle ein kompaktes
Sprach-Dropdown (`Picker`/`Menu` im macOS-üblichen Kompaktstil) über
`TargetLanguage.selectable`, gebunden an
`$appState.appSettings.translationTargetLanguage`. Sichtbar unabhängig vom
Toggle-Zustand, damit man die Sprache vor dem Aktivieren wählen kann.

## Fehlerbehandlung

Unverändert: Schlägt die Übersetzung fehl, wird der Originaltext als
Ergebnis gemeldet (kein `.error`-Zwischenschritt).

## Verifikation

Es gibt kein Test-Target. Verifikation:

1. Build des Schemes `Blitztext (Debug)` erfolgreich
   (keine Referenzen mehr auf `TranslationStepSettings.targetLanguage`).
2. Manueller Check: Sprache im Popover ändern → Settings zeigen denselben
   Wert (und umgekehrt); Workflow-Lauf mit Toggle an übersetzt in die
   global gewählte Sprache; Untertitel der Workflow-Zeilen zeigen die
   globale Sprache.
3. Bestehende `settings.json` (Debug-Pfad `Blitztext Dev`) lädt ohne
   Verlust der übrigen Einstellungen.

## Betroffene Dateien

| Datei | Änderung |
|---|---|
| `BlitztextMac/Features/Workflows/WorkflowProtocol.swift` | `AppSettings.translationTargetLanguage` neu; `TranslationStepSettings.targetLanguage` entfernt |
| `BlitztextMac/Features/Workflows/TranslatingWorkflow.swift` | `targetLanguage`-Parameter, Prompt-Bau angepasst |
| `BlitztextMac/App/AppState.swift` | Wrapper-Aufbau + `workflowSubtitle` auf globales Feld |
| `BlitztextMac/Features/Settings/SettingsContentView.swift` | Globaler Sprach-Picker; Sprach-Picker aus `TranslationStepSettingsView` entfernt |
| `BlitztextMac/Features/MenuBar/MenuBarView.swift` | Sprach-Dropdown im `translationTogglePanel` |

Keine neuen Dateien → die xcodegen-/pbxproj-Problematik (siehe `CLAUDE.md`)
wird nicht berührt.
