import SwiftUI
import AppKit

@main
struct BlitztextMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let menuBarStatusController = MenuBarStatusController()
    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Check for conflicts with production version and duplicates
        checkForMultipleInstances()
        
        // Log configuration info
        let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Blitztext"
        print("📱 [Config] App Name: \(appName)")
        print("📱 [Config] Bundle ID: \(bundleId)")
        #if DEBUG
        print("📱 [Config] Build Type: DEBUG")
        #else
        print("📱 [Config] Build Type: RELEASE")
        #endif
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            menuBarStatusController.attach(to: button)
            button.action = #selector(handleMenuBarClick)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 340, height: 480)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MenuBarView(appState: appState))

        NSApp.setActivationPolicy(.accessory)

        appState.hotkeyService.onHotkeyEvent = { [weak self] event in
            self?.handleHotkeyEvent(event)
        }
        appState.hotkeyService.onToggleTranslation = { [weak self] in
            self?.appState.appSettings.translationEnabled.toggle()
        }
        appState.onMenuBarStatusChange = { [weak self] status in
            self?.menuBarStatusController.update(to: status)
        }
        appState.onPageChange = { [weak self] page in
            self?.updatePopoverSize(for: page)
        }
        appState.hotkeyService.start()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDismissPopover),
            name: .dismissPopover,
            object: nil
        )

        DispatchQueue.main.async { [weak self] in
            self?.showOnboardingIfNeeded()
        }
    }

    @objc private func handleDismissPopover() {
        appState.isPopoverShown = false
        popover.performClose(nil)
    }

    private func handleHotkeyEvent(_ event: HotkeyEvent) {
        switch event {
        case .down(let type):
            handleHotkeyDown(type)
        case .up(let type):
            handleHotkeyUp(type)
        case .cancel:
            handleHotkeyCancel()
        }
    }

    private func handleHotkeyDown(_ type: WorkflowType) {
        guard appState.isConfigured else { return }
        let mode = appState.appSettings.hotkeyMode

        switch mode {
        case .hold:
            appState.startWorkflow(type, source: .hotkeyBackground)
        case .toggle:
            if let active = appState.activeWorkflow,
               active.type == type,
               active.phase.isActive {
                active.stop()
            } else {
                appState.prepareForPopoverPresentation()
                appState.startWorkflow(type, source: .manual)
                showPopover()
            }
        }
    }

    private func handleHotkeyUp(_ type: WorkflowType) {
        let mode = appState.appSettings.hotkeyMode
        guard mode == .hold else { return }

        if let active = appState.activeWorkflow,
           active.type == type {
            if case .running = active.phase {
                active.stop()
            }
        }
    }

    private func handleHotkeyCancel() {
        appState.activeWorkflow?.stop()
    }

    @objc private func handleMenuBarClick() {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }
        
        // Right-click or Option-click: show context menu
        if event.type == .rightMouseUp || event.modifierFlags.contains(.option) {
            showContextMenu()
        } else {
            // Normal left-click: toggle popover
            togglePopover()
        }
    }
    
    private func showContextMenu() {
        let menu = NSMenu()
        
        menu.addItem(NSMenuItem(title: "Blitztext öffnen", action: #selector(togglePopover), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Einstellungen...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        
        let versionItem = NSMenuItem(title: "Version: v2.0-FIXED", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Beenden", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        
        // Remove menu after it's shown so normal clicks work again
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.menu = nil
        }
    }
    
    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            appState.isPopoverShown = false
        } else {
            appState.prepareForPopoverPresentation()
            showPopover()
        }
    }
    
    @objc private func openSettings() {
        appState.page = .settings
        if !popover.isShown {
            showPopover()
        }
    }
    
    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func showOnboardingIfNeeded() {
        guard appState.shouldShowOnboarding else { return }
        appState.prepareForPopoverPresentation()
        showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        appState.isPopoverShown = true
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updatePopoverSize(for page: PopoverPage) {
        let height: CGFloat = page == .settings ? 580 : 480
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            popover.contentSize = NSSize(width: 340, height: height)
        }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in
            appState.isPopoverShown = false
            switch appState.currentPhase {
            case .done, .error:
                appState.resetCurrentWorkflow()
            default:
                appState.page = .main
            }
        }
    }
    
    // MARK: - Multiple Instance Prevention
    
    private func checkForMultipleInstances() {
        let runningApps = NSWorkspace.shared.runningApplications
        let currentBundleId = Bundle.main.bundleIdentifier ?? "app.blitztext"
        
        // Check for same bundle ID instances (exact duplicates)
        let exactDuplicates = runningApps.filter { app in
            app.bundleIdentifier == currentBundleId
        }
        
        print("🔍 [MultiInstance] Current Bundle ID: \(currentBundleId)")
        print("🔍 [MultiInstance] Found \(exactDuplicates.count) instance(s) with same Bundle ID")
        
        // If running from Xcode (Debug), terminate production version
        #if DEBUG
        terminateProductionVersion()
        #endif
        
        // Handle exact duplicates (same bundle ID)
        if exactDuplicates.count > 1 {
            let currentPID = ProcessInfo.processInfo.processIdentifier
            let sortedByPID = exactDuplicates.sorted { $0.processIdentifier < $1.processIdentifier }
            
            if let oldestInstance = sortedByPID.first,
               oldestInstance.processIdentifier != currentPID {
                print("⚠️ [MultiInstance] Another instance (PID \(oldestInstance.processIdentifier)) is already running")
                print("⚠️ [MultiInstance] Terminating this instance (PID \(currentPID))")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NSApp.terminate(nil)
                }
                return
            } else {
                print("✅ [MultiInstance] This is the primary instance (PID \(currentPID))")
                for instance in exactDuplicates where instance.processIdentifier != currentPID {
                    print("🛑 [MultiInstance] Terminating duplicate instance (PID \(instance.processIdentifier))")
                    instance.terminate()
                }
            }
        } else {
            print("✅ [MultiInstance] Single instance confirmed")
        }
    }
    
    #if DEBUG
    /// Automatically terminates the production version when running from Xcode.
    /// Requires that the Debug build uses a different bundle identifier (e.g. "app.blitztext.dev")
    /// so that this method only targets the Release version.
    private func terminateProductionVersion() {
        let runningApps = NSWorkspace.shared.runningApplications
        let currentBundleId = Bundle.main.bundleIdentifier
        let currentPID = ProcessInfo.processInfo.processIdentifier
        
        // The production bundle ID – must differ from the Debug bundle ID
        let productionBundleId = "app.blitztext"
        
        // Safety check: if our own bundle ID matches production, skip termination
        // to avoid killing ourselves. This means the Debug bundle ID hasn't been
        // changed yet in Xcode Build Settings.
        if currentBundleId == productionBundleId {
            print("⚠️ [DevMode] Debug build has same Bundle ID as production (\(productionBundleId)).")
            print("⚠️ [DevMode] Set PRODUCT_BUNDLE_IDENTIFIER to 'app.blitztext.dev' for the Debug configuration in Xcode Build Settings.")
            return
        }
        
        for app in runningApps where app.processIdentifier != currentPID {
            guard let bundleId = app.bundleIdentifier else { continue }
            
            if bundleId == productionBundleId {
                print("🔧 [DevMode] Found production version: \(bundleId) (PID: \(app.processIdentifier))")
                print("🔧 [DevMode] Terminating production version to avoid conflicts...")
                app.terminate()
                
                // Give it a moment to terminate
                usleep(500_000) // 0.5 seconds
                
                if !app.isTerminated {
                    print("⚠️ [DevMode] Production version did not terminate gracefully, forcing...")
                    app.forceTerminate()
                }
            }
        }
    }
    #endif
}
