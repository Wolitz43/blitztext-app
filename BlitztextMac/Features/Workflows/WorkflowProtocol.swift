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
    var translationTargetLanguage: TargetLanguage = .english
    var selectedMicrophoneID: String? = nil

    init(
        hotkeyMode: HotkeyMode = .hold,
        hasSeenOnboarding: Bool = false,
        secureLocalModeEnabled: Bool = false,
        selectedLocalTranscriptionModelName: String = LocalTranscriptionService.recommendedFastModelName,
        hasAutoSelectedFastLocalModel: Bool = false,
        translationEnabled: Bool = false,
        translationTargetLanguage: TargetLanguage = .english,
        selectedMicrophoneID: String? = nil
    ) {
        self.hotkeyMode = hotkeyMode
        self.hasSeenOnboarding = hasSeenOnboarding
        self.secureLocalModeEnabled = secureLocalModeEnabled
        self.selectedLocalTranscriptionModelName = selectedLocalTranscriptionModelName
        self.hasAutoSelectedFastLocalModel = hasAutoSelectedFastLocalModel
        self.translationEnabled = translationEnabled
        self.translationTargetLanguage = translationTargetLanguage
        self.selectedMicrophoneID = selectedMicrophoneID
    }

    enum CodingKeys: String, CodingKey {
        case hotkeyMode
        case hasSeenOnboarding
        case secureLocalModeEnabled
        case selectedLocalTranscriptionModelName
        case hasAutoSelectedFastLocalModel
        case translationEnabled
        case translationTargetLanguage
        case selectedMicrophoneID
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
        translationTargetLanguage = try container.decodeIfPresent(
            TargetLanguage.self,
            forKey: .translationTargetLanguage
        ) ?? .english
        selectedMicrophoneID = try container.decodeIfPresent(String.self, forKey: .selectedMicrophoneID)
    }
}

enum TranscriptionBackend: String, Codable {
    case remote
    case local
}

// MARK: - Translation Step Settings (shared by all 4 workflows)

struct TranslationStepSettings: Codable {
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
