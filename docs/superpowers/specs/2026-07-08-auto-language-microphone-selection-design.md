# Automatische Spracherkennung + Mikrofon-Auswahl

Stand: 2026-07-08

## Kontext

Zwei Features aus der Empfehlungsliste (PLANNED_FEATURES.md, „Top-5"), als
ein Paket umgesetzt:

1. **Sprache auto-erkennen:** Die Transkriptions-Sprache ist fest auf
   `"de"` verdrahtet (`TranscriptionSettings.language`, ohne UI). Whisper
   kann die Sprache selbst erkennen — beide Services unterstützen das
   bereits: `TranscriptionService` lässt das `language`-Formularfeld bei
   leerem Wert weg (TranscriptionService.swift:105-108),
   `LocalTranscriptionService` setzt `DecodingOptions.language = nil`
   (LocalTranscriptionService.swift:258-263). Es fehlen nur Semantik
   („leer = automatisch") und UI.
2. **Mikrofon-Auswahl:** `AVAudioRecorder` unterstützt auf macOS keine
   Geräteauswahl — es nimmt immer das System-Standardmikrofon. Für echte
   Auswahl wird die Aufnahme-Engine auf `AVCaptureSession` umgestellt.

Entscheidungen vom 2026-07-08:
- Sprache: Picker mit „Automatisch" + festen Sprachen (Sicherheitsnetz
  gegen Fehl-Erkennung bei sehr kurzen Äußerungen). Default für
  Neuinstallationen: Automatisch; bestehende Einstellung („de") bleibt.
- Mikrofon: nur in den Settings (kein Popover-Dropdown), Eintrag
  „System-Standard" als Default, automatischer Fallback wenn das gewählte
  Gerät verschwindet.

## Ziele

- Neuer Settings-Picker „Gesprochene Sprache": Automatisch / Deutsch /
  Englisch / Französisch / Spanisch / Italienisch.
- Neuer Settings-Picker „Mikrofon": System-Standard + alle angeschlossenen
  Eingabegeräte; Auswahl wird über die Geräte-`uniqueID` persistiert.
- Aufnahme läuft über das gewählte Mikrofon; ist es nicht (mehr) vorhanden,
  lautlos über das Standardmikrofon.
- Keine neuen Dateien (pbxproj-Constraint, siehe CLAUDE.md).

## Nicht-Ziele

- Kein Mikrofon-Dropdown im Popover.
- Keine Live-Umschaltung während einer laufenden Aufnahme (Wechsel gilt ab
  der nächsten Aufnahme).
- Keine Code-Switching-Unterstützung (mehrere Sprachen in einer Aufnahme).
- Keine Migration: bestehende `settings.json` mit `"language": "de"` lädt
  als Deutsch weiter; das ist gewollt.

## Datenmodell (`WorkflowProtocol.swift`)

### TranscriptionLanguage (neues Enum, ersetzt den rohen String)

```swift
enum TranscriptionLanguage: String, Codable, CaseIterable, Identifiable {
    case automatic = "auto"
    case german    = "de"
    case english   = "en"
    case french    = "fr"
    case spanish   = "es"
    case italian   = "it"

    var id: String { rawValue }

    /// Whisper-Parameter: leer = Sprache automatisch erkennen.
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

### TranscriptionSettings

`var language: String = "de"` wird zu
`var language: TranscriptionLanguage = .automatic`.

Abwärtskompatibilität im Custom-Decoder: `try? decode` statt `try`, damit
ein unbekannter alter String-Wert nicht das ganze Container-Decoding
sprengt:

```swift
language = (try? container.decodeIfPresent(TranscriptionLanguage.self, forKey: .language)) ?? .automatic
```

Bestehendes `"de"` dekodiert als `.german` (rawValue-Treffer); fehlender
Schlüssel oder unbekannter Wert → `.automatic`.

### AppSettings

Neues Feld nach dem bestehenden Muster (Property, Memberwise-Init,
CodingKeys, `decodeIfPresent`-Fallback):

```swift
var selectedMicrophoneID: String? = nil   // nil = System-Standard
```

Persistiert `AVCaptureDevice.uniqueID`.

## AudioRecorder-Umbau (`Services/AudioRecorder.swift`)

Interner Wechsel `AVAudioRecorder` → `AVCaptureSession` +
`AVCaptureAudioFileOutput`. Die öffentliche Schnittstelle bleibt identisch
(`isRecording`, `audioLevel`, `recordingURL`, `errorMessage`,
`lastRecordingDuration`, `stopRecording()`, `discardRecording()`) — einzige
Signaturänderung:

```swift
func startRecording(preferredDeviceID: String? = nil)
```

- **Geräteauflösung:** `preferredDeviceID` über
  `AVCaptureDevice.DiscoverySession` auflösen; `nil` oder nicht gefunden →
  `AVCaptureDevice.default(for: .audio)` (heutiges Verhalten). Kein Fehler,
  kein Dialog — stiller Fallback wie besprochen.
- **Ausgabe:** `AVCaptureAudioFileOutput.startRecording(to:outputFileType:.m4a)`
  mit AAC-Audio-Settings wie bisher (16 kHz, mono) via
  `audioSettings`-Property des Outputs.
- **Pegel für die Waveform:** bestehender 0,05-s-Timer bleibt; liest statt
  `averagePower(forChannel:)` jetzt
  `connection.audioChannels.first?.averagePowerLevel` und normalisiert
  unverändert mit `(power + 50) / 50`.
- **Dauer:** `lastRecordingDuration` aus `output.recordedDuration`
  (CMTime → Sekunden).
- **Geräteliste** (gleiche Datei, kein neues File):

```swift
struct MicrophoneDevice: Identifiable, Equatable {
    let id: String      // uniqueID
    let name: String    // localizedName
}

static func availableMicrophones() -> [MicrophoneDevice]
```

  via `AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
  mediaType: .audio, position: .unspecified)` (macOS-14-API; `.builtInMicrophone`
  ist deprecated).
- **Berechtigung:** gleiche TCC-Kategorie (Mikrofon) wie bisher — kein
  neuer Berechtigungsdialog. `AVCaptureDevice.authorizationStatus(for: .audio)`
  wird nicht gesondert behandelt; das Systemverhalten entspricht dem
  heutigen `AVAudioRecorder`-Pfad.

## Durchreichung (`AppState.swift` + 4 Workflow-Dateien)

Analog zum bestehenden `language:`-Parameter:

- Die 4 Workflows (`TranscriptionWorkflow`, `TextImprovementWorkflow`,
  `DampfAblassenWorkflow`, `EmojiTextWorkflow`) bekommen einen Init-Parameter
  `microphoneID: String? = nil`, gespeichert als `private let`, und rufen
  `recorder.startRecording(preferredDeviceID: microphoneID)` auf.
- `AppState.startWorkflow` übergibt an allen 5 Bau-Stellen
  (AppState.swift:203-250):
  - `language: transcriptionSettings.language.whisperCode` (statt des
    bisherigen Strings)
  - `microphoneID: appSettings.selectedMicrophoneID`
- Die Workflow-Parameter `language: String` bleiben Strings — die Services
  sind unverändert (leer = auto ist dort schon implementiert).

## UI (`SettingsContentView.swift`, Tab „Anpassen", allgemeiner Bereich)

Zwei neue Picker im Stil der bestehenden Sektionen (Labels Fontgröße 11,
`.menu`-Style wegen 6+ Einträgen):

1. **„Gesprochene Sprache"** — `ForEach(TranscriptionLanguage.allCases)`,
   gebunden an `$appState.transcriptionSettings.language`. Kurzer
   Hinweistext: „Automatisch erkennt die gesprochene Sprache; bei sehr
   kurzen Äußerungen ist eine feste Sprache zuverlässiger."
2. **„Mikrofon"** — erster Eintrag „System-Standard" (tag `String?.none`),
   dann `AudioRecorder.availableMicrophones()`, gebunden an
   `$appState.appSettings.selectedMicrophoneID` (`String?`-Tags). Die
   Geräteliste wird beim Erscheinen der View (`onAppear`) neu geladen; ist
   das gespeicherte Gerät gerade nicht angeschlossen, wird es als
   „Nicht verbunden"-Eintrag mit angezeigt, damit die Auswahl nicht
   stillschweigend umspringt.

## Fehlerbehandlung

- Gewähltes Mikrofon fehlt beim Aufnahmestart → stiller Fallback auf
  System-Standard (kein Abbruch, keine Meldung — bewusste Entscheidung).
- `AVCaptureSession`-Fehler beim Start → bestehender Pfad
  (`errorMessage`, Workflow bricht ab) bleibt erhalten.
- Übersetzungs- und LLM-Pfade sind nicht betroffen.

## Implementierungs-Checks (in den Plan aufzunehmen)

1. **WhisperKit-Auto-Detect verifizieren:** prüfen, ob
   `DecodingOptions(language: nil)` in der eingesetzten Version
   (argmax-oss-swift 0.18.0) automatisch erkennt oder zusätzlich
   `detectLanguage: true` braucht — ggf. in
   `LocalTranscriptionService.transcribe` ergänzen.
2. **Hinweis dokumentieren:** englischsprachige Lokal-Modelle (`*.en`)
   können nie auto-erkennen; Verhalten ist dann wie bisher (Modell
   transkribiert englisch). Kein Blocker.
3. **AVCaptureAudioFileOutput + audioSettings:** exakte AAC-Settings
   (Format, Sample-Rate, Kanäle) gegen das heutige Ausgabeformat prüfen,
   damit Whisper-Kompatibilität (m4a, 16 kHz, mono) erhalten bleibt.

## Verifikation

Kein Test-Target. Pro Task: Debug-Build grün
(`xcodebuild -project BlitztextMac/BlitztextMac.xcodeproj -scheme "Blitztext (Debug)" build`,
Standard-DerivedData — **kein** `-derivedDataPath` im Repo, siehe CLAUDE.md).
Abschließend Launch-Smoke (App ~8 s starten). Manuell (Mensch): Aufnahme
mit gewähltem Mikrofon, Auto-Erkennung mit deutschem und englischem Satz,
Fallback nach Abziehen eines USB-Mikrofons.

## Betroffene Dateien (keine neuen Dateien)

| Datei | Änderung |
|---|---|
| `BlitztextMac/Features/Workflows/WorkflowProtocol.swift` | `TranscriptionLanguage` neu, `TranscriptionSettings.language` als Enum, `AppSettings.selectedMicrophoneID` |
| `BlitztextMac/Services/AudioRecorder.swift` | Umbau auf `AVCaptureSession`, `preferredDeviceID`, `availableMicrophones()` |
| `BlitztextMac/Features/Workflows/{Transcription,TextImprovement,DampfAblassen,EmojiText}Workflow.swift` | Init-Parameter `microphoneID`, Durchreichung an den Recorder |
| `BlitztextMac/App/AppState.swift` | `whisperCode` + `microphoneID` an den 5 Bau-Stellen |
| `BlitztextMac/Features/Settings/SettingsContentView.swift` | Picker „Gesprochene Sprache" + „Mikrofon" |
| ggf. `BlitztextMac/Services/LocalTranscriptionService.swift` | nur falls Check 1 `detectLanguage: true` erfordert |
