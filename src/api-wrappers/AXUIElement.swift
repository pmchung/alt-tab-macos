import Cocoa
import ApplicationServices.HIServices.AXUIElement
import ApplicationServices.HIServices.AXValue
import ApplicationServices.HIServices.AXError
import ApplicationServices.HIServices.AXRoleConstants
import ApplicationServices.HIServices.AXAttributeConstants
import ApplicationServices.HIServices.AXActionConstants

// if the window server is busy, it may not reply to AX calls. We retry right before the call times-out and returns a bogus value
func retryAxCallUntilTimeout(_ group: DispatchGroup? = nil, _ timeoutInSeconds: Double = Double(AXUIElement.globalTimeoutInSeconds), _ fn: @escaping () throws -> Void, _ startTime: DispatchTime = DispatchTime.now()) {
    group?.enter()
    BackgroundWork.axCallsQueue.async {
        retryAxCallUntilTimeout_(group, timeoutInSeconds, fn, startTime)
    }
}

func retryAxCallUntilTimeout_(_ group: DispatchGroup?, _ timeoutInSeconds: Double, _ fn: @escaping () throws -> Void, _ startTime: DispatchTime = DispatchTime.now()) {
    do {
        try fn()
        group?.leave()
    } catch {
        let timePassedInSeconds = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000_000
        if timePassedInSeconds < timeoutInSeconds {
            BackgroundWork.axCallsQueue.asyncAfter(deadline: .now() + .milliseconds(10)) {
                retryAxCallUntilTimeout_(group, timeoutInSeconds, fn, startTime)
            }
        }
    }
}

extension AXUIElement {
    static let globalTimeoutInSeconds = Float(120)

    // default timeout for AX calls is 6s. We increase it in order to avoid retrying every 6s, thus saving resources
    static func setGlobalTimeout() {
        // we add 5s to make sure to not do an extra retry
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), globalTimeoutInSeconds + 5)
    }

    static let normalLevel = CGWindowLevelForKey(.normalWindow)

    func axCallWhichCanThrow<T>(_ result: AXError, _ successValue: inout T) throws -> T? {
        switch result {
            case .success: return successValue
            // .cannotComplete can happen if the app is unresponsive; we throw in that case to retry until the call succeeds
            case .cannotComplete: throw AxError.runtimeError
            // for other errors it's pointless to retry
            default: return nil
        }
    }

    func cgWindowId() throws -> CGWindowID? {
        var id = CGWindowID(0)
        return try axCallWhichCanThrow(_AXUIElementGetWindow(self, &id), &id)
    }

    func pid() throws -> pid_t? {
        var pid = pid_t(0)
        return try axCallWhichCanThrow(AXUIElementGetPid(self, &pid), &pid)
    }

    func attribute<T>(_ key: String, _ _: T.Type) throws -> T? {
        var value: AnyObject?
        return try axCallWhichCanThrow(AXUIElementCopyAttributeValue(self, key as CFString, &value), &value) as? T
    }

    private func value<T>(_ key: String, _ target: T, _ type: AXValueType) throws -> T? {
        if let a = try attribute(key, AXValue.self) {
            var value = target
            AXValueGetValue(a, type, &value)
            return value
        }
        return nil
    }

    static func isActualWindow(_ runningApp: NSRunningApplication, _ wid: CGWindowID, _ level: CGWindowLevel, _ title: String?, _ subrole: String?, _ role: String?, _ size: CGSize?) -> Bool {
        // Some non-windows have title: nil (e.g. some OS elements)
        // Some non-windows have subrole: nil (e.g. some OS elements), "AXUnknown" (e.g. Bartender), "AXSystemDialog" (e.g. Intellij tooltips)
        // Minimized windows or windows of a hidden app have subrole "AXDialog"
        // Activity Monitor main window subrole is "AXDialog" for a brief moment at launch; it then becomes "AXStandardWindow"

        // Some non-windows have cgWindowId == 0 (e.g. windows of apps starting at login with the checkbox "Hidden" checked)
        return wid != 0 &&
            size != nil && size!.width > 100 && size!.height > 100 &&
            (books(runningApp) || keynote(runningApp) || iina(runningApp) || (
                // CGWindowLevel == .normalWindow helps filter out iStats Pro and other top-level pop-overs, and floating windows
                level == AXUIElement.normalLevel &&
                    jetbrainApp(runningApp, title, subrole) &&
                    ([kAXStandardWindowSubrole, kAXDialogSubrole].contains(subrole) ||
                        openBoard(runningApp) ||
                        adobeAudition(runningApp, subrole) ||
                        steam(runningApp, title, role) ||
                        worldOfWarcraft(runningApp, role) ||
                        battleNetBootstrapper(runningApp, role) ||
                        firefoxFullscreenVideo(runningApp, role) ||
                        vlcFullscreenVideo(runningApp, role) ||
                        androidEmulator(runningApp, title) ||
                        sanGuoShaAirWD(runningApp) ||
                        dvdFab(runningApp) ||
                        drBetotte(runningApp))))
    }

    private static func jetbrainApp(_ runningApp: NSRunningApplication, _ title: String?, _ subrole: String?) -> Bool {
        // jetbrain apps sometimes generate non-windows that pass all checks in isActualWindow
        // they have no title, so we can filter them out based on that
        return runningApp.bundleIdentifier?.range(of: "^com\\.(jetbrains\\.|google\\.android\\.studio).*?$", options: .regularExpression) == nil ||
            (subrole == kAXStandardWindowSubrole || title != nil && title != "")
    }

    private static func iina(_ runningApp: NSRunningApplication) -> Bool {
        // IINA.app can have videos float (level == 2 instead of 0)
        // there is also complex animations during which we may or may not consider the window not a window
        return runningApp.bundleIdentifier == "com.colliderli.iina"
    }

    private static func keynote(_ runningApp: NSRunningApplication) -> Bool {
        // apple Keynote has a fake fullscreen window when in presentation mode
        // it covers the screen with a AXUnknown window instead of using standard fullscreen mode
        return runningApp.bundleIdentifier == "com.apple.iWork.Keynote"
    }

    private static func openBoard(_ runningApp: NSRunningApplication) -> Bool {
        // OpenBoard is a ported app which doesn't use standard macOS windows
        return runningApp.bundleIdentifier == "org.oe-f.OpenBoard"
    }

    private static func adobeAudition(_ runningApp: NSRunningApplication, _ subrole: String?) -> Bool {
        return runningApp.bundleIdentifier == "com.adobe.Audition" && subrole == kAXFloatingWindowSubrole
    }

    private static func books(_ runningApp: NSRunningApplication) -> Bool {
        // Books.app has animations on window creation. This means windows are originally created with subrole == AXUnknown or isOnNormalLevel == false
        return runningApp.bundleIdentifier == "com.apple.iBooksX"
    }

    private static func worldOfWarcraft(_ runningApp: NSRunningApplication, _ role: String?) -> Bool {
        return runningApp.bundleIdentifier == "com.blizzard.worldofwarcraft" && role == kAXWindowRole
    }

    private static func battleNetBootstrapper(_ runningApp: NSRunningApplication, _ role: String?) -> Bool {
        // Battlenet bootstrapper windows have subrole == AXUnknown
        return runningApp.bundleIdentifier == "net.battle.bootstrapper" && role == kAXWindowRole
    }

    private static func drBetotte(_ runningApp: NSRunningApplication) -> Bool {
        return runningApp.bundleIdentifier == "com.ssworks.drbetotte"
    }

    private static func dvdFab(_ runningApp: NSRunningApplication) -> Bool {
        return runningApp.bundleIdentifier == "com.goland.dvdfab.macos"
    }

    private static func sanGuoShaAirWD(_ runningApp: NSRunningApplication) -> Bool {
        return runningApp.bundleIdentifier == "SanGuoShaAirWD"
    }

    private static func steam(_ runningApp: NSRunningApplication, _ title: String?, _ role: String?) -> Bool {
        // All Steam windows have subrole == AXUnknown
        // some dropdown menus are not desirable; they have title == "", or sometimes role == nil when switching between menus quickly
        return runningApp.bundleIdentifier == "com.valvesoftware.steam" && title != "" && role != nil
    }

    private static func firefoxFullscreenVideo(_ runningApp: NSRunningApplication, _ role: String?) -> Bool {
        // Firefox fullscreen video have subrole == AXUnknown if fullscreen'ed when the base window is not fullscreen
        return (runningApp.bundleIdentifier?.hasPrefix("org.mozilla.firefox") ?? false) && role == kAXWindowRole
    }

    private static func vlcFullscreenVideo(_ runningApp: NSRunningApplication, _ role: String?) -> Bool {
        // VLC fullscreen video have subrole == AXUnknown if fullscreen'ed
        return (runningApp.bundleIdentifier?.hasPrefix("org.videolan.vlc") ?? false) && role == kAXWindowRole
    }

    private static func androidEmulator(_ runningApp: NSRunningApplication, _ title: String?) -> Bool {
        // android emulator small vertical menu is a "window" with empty title; we exclude it
        return title != "" && Applications.isAndroidEmulator(runningApp)
    }

    func position() throws -> CGPoint? {
        return try value(kAXPositionAttribute, CGPoint.zero, .cgPoint)
    }

    func size() throws -> CGSize? {
        return try value(kAXSizeAttribute, CGSize.zero, .cgSize)
    }

    func title() throws -> String? {
        return try attribute(kAXTitleAttribute, String.self)
    }

    func parent() throws -> AXUIElement? {
        return try attribute(kAXParentAttribute, AXUIElement.self)
    }

    func children() throws -> [AXUIElement]? {
        return try attribute(kAXChildrenAttribute, [AXUIElement].self)
    }

    func windows() throws -> [AXUIElement]? {
        return try attribute(kAXWindowsAttribute, [AXUIElement].self)
    }

    func isMinimized() throws -> Bool {
        return try attribute(kAXMinimizedAttribute, Bool.self) == true
    }

    func isFullscreen() throws -> Bool {
        return try attribute(kAXFullscreenAttribute, Bool.self) == true
    }

    func focusedWindow() throws -> AXUIElement? {
        return try attribute(kAXFocusedWindowAttribute, AXUIElement.self)
    }

    func role() throws -> String? {
        return try attribute(kAXRoleAttribute, String.self)
    }

    func subrole() throws -> String? {
        return try attribute(kAXSubroleAttribute, String.self)
    }

    func appIsRunning() throws -> Bool? {
        return try attribute(kAXIsApplicationRunningAttribute, Bool.self)
    }

    func closeButton() throws -> AXUIElement? {
        return try attribute(kAXCloseButtonAttribute, AXUIElement.self)
    }

    func focusWindow() {
        performAction(kAXRaiseAction)
    }

    func subscribeToNotification(_ axObserver: AXObserver, _ notification: String, _ callback: (() -> Void)? = nil, _ runningApplication: NSRunningApplication? = nil, _ wid: CGWindowID? = nil, _ startTime: DispatchTime = DispatchTime.now()) throws {
        let result = AXObserverAddNotification(axObserver, self, notification as CFString, nil)
        if result == .success || result == .notificationAlreadyRegistered {
            callback?()
        } else if result != .notificationUnsupported && result != .notImplemented {
            throw AxError.runtimeError
        }
    }

    func setAttribute(_ key: String, _ value: Any) {
        AXUIElementSetAttributeValue(self, key as CFString, value as CFTypeRef)
    }

    func performAction(_ action: String) {
        AXUIElementPerformAction(self, action as CFString)
    }
}

enum AxError: Error {
    case runtimeError
}
