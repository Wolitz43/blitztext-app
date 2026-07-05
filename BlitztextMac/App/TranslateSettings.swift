import Foundation

struct TranslateSettings: Codable {
    var customName: String = ""
    var targetLanguage: TargetLanguage = .english
    var tone: TranslateTone = .neutral
    var context: String = ""

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
}
