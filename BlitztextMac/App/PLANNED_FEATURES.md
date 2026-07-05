# Blitztext – Geplante Features
# Stand: 05.07.2026

## ✅ Erledigt (05.07.2026)
- Übersetzung als globaler Toggle auf die 4 bestehenden Workflows (statt eigener 5. Menüeintrag)

## ✅ Erledigt (03.07.2026)
- Kein Auto-Paste wenn Workflow über Popover gestartet wird (nur bei Hotkey)
- Usage-Tracker: Token-Verbrauch und API-Kosten werden getrackt und angezeigt


---


## Projekt-Setup: Debug vs. Release

### Zwei Xcode-Schemes
Das Projekt hat zwei separate Schemes:

| Scheme                  | Konfiguration | Zweck                              |
|-------------------------|---------------|------------------------------------|
| `Blitztext (Debug)`     | Debug         | Entwicklung & Testen in Xcode      |
| `Blitztext (Release)`   | Release       | Produktiv-Build nach /Applications |

Umschalten: Scheme-Dropdown oben in Xcode → gewünschtes Scheme wählen → Cmd+B

### Unterschiede Debug vs. Release

#### Datenpfade (AppSupportPaths.swift)
```swift
#if DEBUG
// ~/Library/Application Support/Blitztext Dev/
#else
// ~/Library/Application Support/Blitztext/
#endif
```
Debug und Release haben **getrennte Daten** (Settings, usage.json, Modelle).
Änderungen im Debug-Build beeinflussen die Release-Version nicht.

#### Auto-Paste-Verhalten (AppState.swift)
- **Debug & Release**: Kein Auto-Paste wenn Workflow über den Popover gestartet wird
- **Debug & Release**: Auto-Paste nur bei Hotkey-Start im Hintergrund (`.hotkeyBackground`)
- Kein `#if DEBUG`-Block mehr im Paste-Code – Verhalten ist in beiden Builds identisch

### Build Script (Release → /Applications)
In den Xcode Build Phases ist ein Run Script hinterlegt, das bei jedem
Release-Build die App automatisch nach /Applications kopiert und die
Quarantäne-Attribute entfernt (damit macOS die App nicht blockiert):

```bash
if [ "${CONFIGURATION}" = "Release" ]; then
    APP_NAME="${PRODUCT_NAME}.app"
    SOURCE="${BUILT_PRODUCTS_DIR}/${APP_NAME}"
    DEST="/Applications/${APP_NAME}"

    if [ -d "$DEST" ]; then
        rm -rf "$DEST"
    fi

    cp -R "$SOURCE" "$DEST"
    xattr -cr "$DEST"

    echo "✅ ${APP_NAME} wurde nach /Applications kopiert."
fi
```

### Workflow für einen Release-Build
1. Scheme auf **„Blitztext (Release)"** umstellen
2. **Cmd+B**
3. App ist automatisch in `/Applications` aktualisiert und startbereit


---


## Feature 1: Übersetzer-Workflow „Blitztext 🌍"

### Konzept
Deutsch sprechen → Transkription → LLM übersetzt → Englischer Text wird eingefügt.
Unterstützt beide Backends (Apple Intelligence lokal / OpenAI remote).

### Flow
Phase 1: 🎤 Audio aufnehmen
Phase 2: 📝 Transkription (WhisperKit lokal ODER Whisper API)
Phase 3: 🌍 Übersetzung (Apple Intelligence lokal ODER OpenAI gpt-4o-mini)
Phase 4: 📋 Einfügen (Paste)

### Neue Dateien
- TranslateWorkflow.swift     → Kopie von TextImprovementWorkflow, Phase 2 = Übersetzung
- TranslateSettings.swift     → Zielsprache, Ton (formal/casual), Kontext

### TranslateSettings (geplant)
```swift
struct TranslateSettings: Codable {
    var customName: String = ""
    var targetLanguage: TargetLanguage = .english
    var tone: TranslateTone = .neutral
    var context: String = ""

    enum TargetLanguage: String, Codable, CaseIterable {
        case english = "en"
        case french = "fr"
        case spanish = "es"
        case italian = "it"
        case portuguese = "pt"

        var displayName: String {
            switch self {
            case .english:    return "Englisch"
            case .french:     return "Französisch"
            case .spanish:    return "Spanisch"
            case .italian:    return "Italienisch"
            case .portuguese: return "Portugiesisch"
            }
        }
    }

    enum TranslateTone: String, Codable, CaseIterable {
        case formal, neutral, casual
    }
}
```

### Zu ändernde Dateien
- WorkflowProtocol.swift       → Neuer case .translate
- LLMService.swift             → Neue translate()-Methode mit backend-Parameter
- LocalLLMService.swift        → Neue translate()-Methode
- AppState.swift               → translateSettings, startWorkflow, isWorkflowAvailable
- SettingsContainer (privat)   → Neues translateSettings-Feld
- MenuBarView.swift            → Neuer Button im Hauptmenü
- SettingsContentView.swift    → Zielsprache-Picker in den Einstellungen

### WorkflowType-Erweiterung (geplant)
```swift
case translate

var displayName: String {
    case .translate: return "Blitztext 🌍"
}
var icon: String {
    case .translate: return "globe"
}
var subtitle: String {
    case .translate: return "Deutsch rein. Englisch raus."
}
```

### System-Prompt (Entwurf)
```
Du bist ein professioneller Übersetzer.
Übersetze den folgenden deutschen Text ins [Zielsprache].
- Verwende natürliches, idiomatisches [Zielsprache]
- Behalte den Ton und Stil bei
- Gib NUR die Übersetzung zurück, keine Erklärungen
```

### Empfohlenes Modell
- Remote: gpt-4o-mini (günstig, ausreichend gut für Übersetzungen)
- Lokal: Apple Intelligence (Basisqualität, für einfache Texte OK)

### Kosten (geschätzt, 100 Wörter Deutsch → Englisch)
- gpt-4o-mini: ~$0,00009 pro Aufruf (~0,008 Cent)
- gpt-4o:      ~$0,0016  pro Aufruf (~0,15 Cent)
- 1.000 Übersetzungen/Monat mit gpt-4o-mini: ~$0,09 (~8 Cent)

### Hinweis Apple Intelligence
- Für einfache, klare Sätze ausreichend
- Bei Redewendungen/Idiomatik oft zu wörtlich
- Safety Guardrails bei Übersetzungen unwahrscheinlich


---


## Feature 2: Kosten-Tracking / Usage-Tracker

### Konzept
Alle OpenAI API-Aufrufe tracken (Tokens + geschätzte Kosten).
Lokale Aufrufe als $0,00 erfassen zum Vergleich.

### Datenquelle
OpenAI API gibt bei jeder Antwort usage-Objekt zurück:
```json
{
  "usage": {
    "prompt_tokens": 220,
    "completion_tokens": 120,
    "total_tokens": 340
  }
}
```
Dieses Feld wird aktuell im LLMService ignoriert.
Auch TranscriptionService (Whisper) hat Kosten: $0,006/Minute Audio.

### Datenmodell (geplant)
```swift
struct UsageRecord: Codable, Identifiable {
    let id: UUID
    let date: Date
    let workflowType: WorkflowType
    let model: String               // z.B. "gpt-4o-mini", "whisper-1"
    let promptTokens: Int
    let completionTokens: Int
    let estimatedCostUSD: Double
    let backend: LLMBackend          // .remote oder .local
}

@Observable
class UsageTracker {
    var records: [UsageRecord] = []

    var costToday: Double { ... }
    var costThisWeek: Double { ... }
    var costThisMonth: Double { ... }
    var totalCalls: Int { ... }
    var localSavings: Double { ... }  // Was im lokalen Modus gespart wurde
}
```

### Preis-Tabelle (Stand Juli 2026)
```swift
enum TokenPricing {
    static func costPerToken(model: String, isOutput: Bool) -> Double {
        switch model {
        case "gpt-4o-mini":
            return isOutput ? 0.60 / 1_000_000 : 0.15 / 1_000_000
        case "gpt-4o":
            return isOutput ? 10.00 / 1_000_000 : 2.50 / 1_000_000
        case "whisper-1":
            return 0.006 / 60  // $0,006 pro Minute, umgerechnet pro Sekunde
        default:
            return 0
        }
    }
}
```

### Zu ändernde Dateien
- LLMService.swift             → usage-Feld aus API-Antwort auslesen, an Tracker melden
- TranscriptionService.swift   → Audio-Dauer tracken für Whisper-Kosten
- UsageTracker.swift           → Neue Datei: Tracking-Logik + Persistenz
- UsageRecord.swift            → Neue Datei: Datenmodell
- AppState.swift               → UsageTracker als Property
- SettingsContentView.swift    → Kosten-Sektion in den Einstellungen
- AppSupportPaths.swift        → Neuer Pfad für usage.json

### Anzeige-Optionen
A) In den Einstellungen: Gesamtübersicht (heute/Woche/Monat)
B) Nach jedem Workflow: Kurze Token/Kosten-Info
C) Beides (empfohlen)

### Persistenz
- JSON-Datei in ~/Library/Application Support/Blitztext[Dev]/usage.json
- Alte Records nach 90 Tagen automatisch löschen


---


## Weitere geplante Features (Ideenliste)

### Leicht (1-2 Tage)
- Verlauf / History: Alle Transkriptionen speichern
- Sound-Feedback: Ton bei Start/Stop/Erfolg
- Automatische Spracherkennung (Whisper language=auto)

### Mittel (3-5 Tage)
- Zusammenfassen-Workflow „Blitztext TL;DR"
- E-Mail-Workflow mit Anrede/Grußformel
- Eigene Workflows mit Custom System-Prompts
- Streaming-Ausgabe (OpenAI stream: true)

### Größer (1-2 Wochen)
- Korrekturlesen: Markierten Text lesen (Cmd+C), verbessern, einfügen (Cmd+V)
- Widget / Live Activity für macOS
- iPad-Companion-App (gleiche Cloud-Services, eigene UI)


---


## Marktvergleich: Features kostenpflichtiger Konkurrenz-Apps
### Stand: 03.07.2026
### Verglichene Apps: SuperWhisper, Wispr Flow, MacWhisper, Cleft

### 🟢 Bereits in Blitztext vorhanden
- Sprache → Text (Transkription)
- LLM-Verbesserung / Umformulierung
- Lokale Modelle (WhisperKit + Apple Intelligence)
- Hotkeys im Hintergrund
- Auto-Paste in andere Apps
- Kosten-Tracking
- Mehrere Workflow-Modi

---

### 🔴 Fehlende Features – nach Kategorie

#### 📝 Transkriptions-Qualität & Komfort

| Feature | Apps die es haben | Aufwand |
|---|---|---|
| Automatische Interpunktion – Whisper gibt oft keinen Punkt am Satzende | SuperWhisper, MacWhisper | Leicht |
| Sprache auto-erkennen – nicht manuell auf „de" festlegen | Alle | Leicht |
| Mehrere Sprachen gleichzeitig – Code-Switching DE/EN | SuperWhisper Pro | Mittel |
| Stille-Erkennung – Aufnahme stoppt automatisch nach X Sek. Pause | Wispr Flow, SuperWhisper | Mittel |

#### 🖥️ System-Integration

| Feature | Apps die es haben | Aufwand |
|---|---|---|
| Markierten Text verbessern – Cmd+C → LLM → Cmd+V | SuperWhisper, Wispr Flow | Mittel |
| Cursor-Position erkennen – Text direkt an Cursor einfügen | Wispr Flow | Groß |
| Kontext-aware – App erkennt fokussierte App, passt Stil an | Wispr Flow Pro | Groß |
| Systemweite Textbausteine – Shortcuts für häufige Phrasen | TextExpander, Raycast | Mittel |

#### 🎙️ Aufnahme & Audio

| Feature | Apps die es haben | Aufwand |
|---|---|---|
| Mikrofon wählen – nicht immer Standard-Mikrofon | MacWhisper, SuperWhisper | Leicht |
| Audio-Datei importieren – .mp3/.m4a transkribieren | MacWhisper | Mittel |
| Rauschunterdrückung – vor dem Senden an Whisper | SuperWhisper Pro | Groß |
| Live-Transkription – Text erscheint während man spricht | Wispr Flow | Groß |

#### 📋 Verlauf & Verwaltung

| Feature | Apps die es haben | Aufwand |
|---|---|---|
| Transkriptions-Verlauf – alle vergangenen Texte durchsuchen | MacWhisper, SuperWhisper | Leicht |
| Favoriten / Pins – wichtige Transkriptionen markieren | MacWhisper | Leicht |
| Export – Verlauf als .txt/.csv exportieren | MacWhisper | Leicht |
| iCloud Sync – Verlauf geräteübergreifend | SuperWhisper Pro | Groß |

#### 🤖 KI & Prompts

| Feature | Apps die es haben | Aufwand |
|---|---|---|
| Custom Workflows – eigene System-Prompts per GUI erstellen | SuperWhisper, Wispr Flow | Mittel |
| Prompt-Templates – vordefinierte Vorlagen (Meeting-Notizen, E-Mail etc.) | SuperWhisper | Mittel |
| Übersetzung – Sprache X → Sprache Y | SuperWhisper, Wispr Flow | ✅ geplant (Feature 1) |
| Zusammenfassung – langer Text → Kernpunkte | SuperWhisper | Mittel |
| Formatierung – Output als Bullet-List, Tabelle etc. | SuperWhisper Pro | Mittel |

#### 💰 Monetarisierung & Distribution

| Feature | Apps die es haben | Aufwand |
|---|---|---|
| Freemium-Modell – X Minuten gratis, dann Abo | SuperWhisper, Wispr Flow | Groß |
| Eigene API-Key-Option | MacWhisper | ✅ vorhanden |
| App Store Distribution | SuperWhisper, MacWhisper | Groß |

---

### Top-5 Empfehlungen nach Aufwand/Nutzen

| Prio | Feature | Warum |
|---|---|---|
| 1 | 🎤 Mikrofon-Auswahl | Leicht, sehr häufig nachgefragt |
| 2 | ⏱️ Stille-Erkennung | Kein manuelles Stoppen mehr nötig, großer UX-Gewinn |
| 3 | 📋 Transkriptions-Verlauf | Alle bisherigen Texte durchsuchbar |
| 4 | ✏️ Markierten Text verbessern | Killer-Feature, das Wispr Flow groß gemacht hat |
| 5 | 🌐 Sprache auto-erkennen | `language=auto` statt fix auf Deutsch, ein Einzeiler |

---


## Feature X: Ollama-Support (lokale KI als drittes Backend)

### Konzept
Ollama als drittes LLM-Backend neben OpenAI (remote) und Apple Intelligence (lokal).
Ollama läuft als lokaler HTTP-Server auf dem Mac und ist vollständig kostenlos.
Die API ist OpenAI-kompatibel → minimale Code-Änderungen nötig.

### Technische Grundlage
- Ollama läuft auf: `http://localhost:11434`
- API-Endpunkt: `http://localhost:11434/v1/chat/completions`
- Identisches Request/Response-Format wie OpenAI Chat Completions
- Kein API-Key nötig

### Qualitätsvergleich (Stand Juli 2026)

| Modell            | Qualität       | RAM-Bedarf | Geschwindigkeit |
|-------------------|----------------|------------|-----------------|
| gpt-4o-mini       | ⭐⭐⭐⭐⭐      | –          | schnell         |
| llama3.2:3b       | ⭐⭐⭐          | ~4 GB      | mittel          |
| llama3.1:8b       | ⭐⭐⭐⭐        | ~8 GB      | langsamer       |
| mistral:7b        | ⭐⭐⭐⭐        | ~8 GB      | mittel          |
| llama3.3:70b      | ⭐⭐⭐⭐⭐      | ~48 GB     | sehr langsam    |

Empfehlung für Blitztext-Aufgaben:
- Einfache Textkorrekturen: `llama3.2:3b` (schnell, wenig RAM)
- Bessere Qualität: `mistral:7b` (gut für Deutsch)
- Dampf ablassen / komplexe Umformulierung: weiterhin GPT-4o empfohlen

### Benötigte Code-Änderungen

#### `LLMBackend` (WorkflowProtocol.swift)
```swift
enum LLMBackend: String, Codable, CaseIterable {
    case remote   // OpenAI API
    case local    // Apple Intelligence
    case ollama   // Lokales Ollama
}
```

#### `LLMService.swift`
```swift
private static let ollamaURL = URL(string: "http://localhost:11434/v1/chat/completions")!

// Neue complete()-Variante für Ollama (kein API-Key, andere baseURL)
// Ansonsten identisch mit der remote-Variante
```

#### Neue Einstellung (AppSettings oder eigene OllamaSettings)
```swift
struct OllamaSettings: Codable {
    var model: String = "llama3.2:3b"   // Frei einstellbar
    var baseURL: String = "http://localhost:11434"  // Für custom Instanzen
}
```

#### Zu ändernde Dateien
- `WorkflowProtocol.swift`   → neuer case `.ollama` in `LLMBackend`
- `LLMService.swift`         → neue `completeOllama()`-Methode
- `AppState.swift`           → `ollamaSettings`, `resolvedLLMBackend` erweitern
- `SettingsContentView.swift` → Ollama-Sektion (URL + Modell-Name + Verbindungstest)
- `MenuBarView.swift`        → Ollama als Option im Modus-Panel

#### Verbindungstest-Endpoint
```swift
// Prüfen ob Ollama läuft:
GET http://localhost:11434/api/tags
// Gibt installierte Modelle zurück → für Picker in den Einstellungen nutzbar
```

### Voraussetzungen für den Nutzer
1. Ollama installieren: https://ollama.com (kostenlos, ~500 MB)
2. Modell laden: `ollama pull llama3.2:3b` im Terminal
3. Ollama startet automatisch beim Login

### Pros & Cons
Pros:
- Vollständig kostenlos nach einmaligem Download
- Datenschutz – nichts verlässt den Mac
- Kein API-Key nötig
- Usage-Tracker zeigt $0.00 (aber lokale Aufrufe werden trotzdem gezählt)

Cons:
- Ollama muss separat installiert sein (externe Abhängigkeit)
- Qualität bei komplexen Umformulierungen schlechter als GPT-4o-mini
- Langsamere Antwortzeiten je nach Mac-Hardware und Modell
- App muss prüfen ob Ollama überhaupt läuft (Fehlerbehandlung nötig)

---


## Plattform-Erweiterung: Windows-Version?
### Bewertung: Sehr hoher Aufwand – aktuell nicht empfohlen

### Das grundlegende Problem
Blitztext ist tief in Apple-Technologien verankert. Fast jede Kernfunktion
nutzt macOS-exklusive Frameworks – eine Windows-Version wäre faktisch
ein kompletter Neubau:

| Komponente | macOS (aktuell) | Windows-Äquivalent |
|---|---|---|
| UI | SwiftUI | – (Swift läuft nicht auf Windows) |
| Menüleisten-Icon | NSStatusItem | System Tray (Win32 API) |
| Audio-Aufnahme | AVFoundation | WASAPI / NAudio |
| Lokale Transkription | WhisperKit | Whisper.net / faster-whisper |
| Lokales LLM | Apple Intelligence | Ollama / llama.cpp |
| Auto-Paste | CGEvent + Accessibility API | SendInput / UI Automation |
| Keychain | Security.framework | Windows Credential Store |
| Hotkeys global | NSEvent global monitor | RegisterHotKey Win32 |
| App Support Pfade | ~/Library/Application Support | %APPDATA% |

Swift läuft zwar offiziell auf Windows, aber SwiftUI und alle
Apple-Frameworks fehlen vollständig → praktisch 100% Code-Neubau.

### Optionen für eine Windows-Version

#### Option A – Kompletter Neubau (C# + WinUI 3)
- Aufwand: 3-6 Monate
- Ergebnis: Native Windows-App, gute Performance
- Problem: Zwei komplett separate Codebases, doppelter Wartungsaufwand dauerhaft

#### Option B – Cross-Platform Framework (Electron / Flutter)
- Aufwand: 2-4 Monate
- Ergebnis: Eine Codebase für beide Plattformen
- Problem: Electron-Apps sind schwer (~150 MB RAM nur für Shell),
  Flutter hat keine gute macOS-Menüleisten-Integration,
  Auto-Paste und globale Hotkeys unterscheiden sich stark

#### Option C – Nur Backend teilen
- Kernlogik (API-Calls, Settings, Pricing) als Swift Package auslagern,
  UI jeweils nativ neu bauen
- Aufwand: 4-8 Monate
- Ergebnis: Sauberste Architektur, größter initialer Aufwand

### Fazit
Windows lohnt sich für ein kleines Team aktuell nicht:
- Zielgruppe (Power-User, Sprache → Text) ist auf macOS deutlich größer
- Konkurrenz (SuperWhisper, Wispr Flow) hat ebenfalls keine Windows-Version
- Aufwand mindestens so groß wie die gesamte bisherige Blitztext-Entwicklung
- Apple Intelligence und WhisperKit als USP existieren auf Windows gar nicht

### Sinnvollere Alternativen zu Windows

| Platform | Aufwand | Warum sinnvoller |
|---|---|---|
| iPadOS | Mittel | Swift/SwiftUI läuft direkt, ~80% Code wiederverwendbar |
| iOS | Mittel | Gleiche Basis wie iPadOS |
| Web-App | Groß | Erreicht Windows-Nutzer ohne native App, OpenAI API direkt im Browser |

→ Eine Web-App wäre der pragmatischste Weg um Windows-Nutzer zu erreichen,
  ohne eine native Windows-App bauen zu müssen.

