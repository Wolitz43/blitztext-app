# Blitztext – Geplante Features
# Stand: 01.07.2026

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
