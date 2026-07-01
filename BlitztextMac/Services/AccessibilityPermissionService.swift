import AppKit
import ApplicationServices

@MainActor
enum AccessibilityPermissionService {
    private static var hasPromptedThisSession = false

    /// The name shown in System Settings → Privacy & Security → Accessibility.
    /// Helps distinguish between "Blitztext" (Release) and "Blitztext Dev" (Debug).
    static var displayAppName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Blitztext"
    }

    static func currentStatus() -> Bool {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            logPermissionHint()
        }
        return trusted
    }

    static func isTrusted(promptIfNeeded: Bool) -> Bool {
        let shouldPrompt = promptIfNeeded && !hasPromptedThisSession
        if shouldPrompt {
            hasPromptedThisSession = true
        }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: shouldPrompt] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            logPermissionHint()
        }
        return trusted
    }

    static func requestPermissionPrompt() -> Bool {
        hasPromptedThisSession = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            logPermissionHint()
        }
        return trusted
    }

    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static func logPermissionHint() {
        let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
        print("🔐 [Accessibility] \"\(displayAppName)\" (\(bundleId)) hat keine Berechtigung.")
        print("🔐 [Accessibility] Bitte in Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen aktivieren.")
        #if DEBUG
        print("🔐 [Accessibility] ⚠️ Debug-Builds benötigen eine EIGENE Berechtigung, getrennt von der Release-App!")
        print("🔐 [Accessibility] Suche nach \"\(displayAppName)\" in der Liste (nicht nach \"Blitztext\").")
        #endif
    }
}
