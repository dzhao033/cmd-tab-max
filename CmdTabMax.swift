import Cocoa
import ApplicationServices

// Disable stdout buffering so log output reaches the file immediately.
setbuf(stdout, nil)

private let tabKeyCode: Int64 = 48
private let skippedBundleIDs: Set<String> = [
    "com.apple.systemuiserver",
]

// MARK: - Accessibility permission check

func requireAccessibility() {
    // Retry silently — TCC may not be ready immediately at login.
    for _ in 0..<20 {
        if AXIsProcessTrusted() { return }
        Thread.sleep(forTimeInterval: 0.5)
    }

    // Show the System Settings prompt, then poll until the user grants.
    // Polling and continuing in-process avoids the TCC propagation race
    // that occurs when we exit and KeepAlive restarts us too quickly.
    print("Accessibility not granted — opening System Settings")
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    AXIsProcessTrustedWithOptions(opts)
    while !AXIsProcessTrusted() {
        Thread.sleep(forTimeInterval: 0.5)
    }
    print("Accessibility granted — continuing")
}

// MARK: - Window handling

func ensureVisibleWindow(app: NSRunningApplication) {
    guard !skippedBundleIDs.contains(app.bundleIdentifier ?? "") else { return }

    let axApp = AXUIElementCreateApplication(app.processIdentifier)

    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let windows = windowsRef as? [AXUIElement] else { return }

    var standardWindows: [AXUIElement] = []
    var minimizedWindows: [AXUIElement] = []
    for window in windows {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleRef)
        guard (roleRef as? String) == kAXWindowRole as String else { continue }
        standardWindows.append(window)

        var minRef: CFTypeRef?
        let isMinimized = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minRef) == .success
            && minRef != nil
            && CFBooleanGetValue((minRef as! CFBoolean))
        if isMinimized {
            minimizedWindows.append(window)
        }
    }

    if standardWindows.isEmpty {
        openNewWindow(for: app)
        return
    }

    // Only unminimize when every window is minimized — otherwise the
    // already-visible window the user expected is brought forward by the
    // normal app activation.
    if minimizedWindows.count == standardWindows.count {
        AXUIElementSetAttributeValue(minimizedWindows[0], kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }
}

// MARK: - Fullscreen Spaces

// Private SkyLight API; there is no public way to enumerate Spaces.
@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces") private func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray

private let fullscreenSpaceType = 4

struct FullscreenSpace {
    // Fullscreen window of each app in the Space (several under Split View).
    let windows: [pid_t: CGWindowID]
    let isCurrent: Bool
}

func fullscreenSpaces() -> [FullscreenSpace] {
    guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] else { return [] }
    var result: [FullscreenSpace] = []
    for display in displays {
        let currentID = (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int
        for space in display["Spaces"] as? [[String: Any]] ?? [] where space["type"] as? Int == fullscreenSpaceType {
            var windows: [pid_t: CGWindowID] = [:]
            let tiles = (space["TileLayoutManager"] as? [String: Any])?["TileSpaces"] as? [[String: Any]] ?? []
            for tile in tiles {
                if let pid = tile["pid"] as? Int, let wid = tile["TileWindowID"] as? Int {
                    windows[pid_t(pid)] = CGWindowID(wid)
                }
            }
            if let pid = space["pid"] as? Int, let wid = space["fs_wid"] as? Int, windows[pid_t(pid)] == nil {
                windows[pid_t(pid)] = CGWindowID(wid)
            }
            result.append(FullscreenSpace(windows: windows, isCurrent: space["ManagedSpaceID"] as? Int == currentID))
        }
    }
    return result
}

// Activation alone leaves the user on the current Space; fronting the
// specific window makes macOS switch to its fullscreen Space.
@_silgen_name("_SLPSSetFrontProcessWithOptions")
private func _SLPSSetFrontProcessWithOptions(_ psn: inout ProcessSerialNumber, _ wid: CGWindowID, _ mode: UInt32) -> CGError
private let slpsUserGenerated: UInt32 = 0x200
// Deprecated, so Swift hides it; still the only way to get a PSN for SkyLight.
@_silgen_name("GetProcessForPID")
private func GetProcessForPID(_ pid: pid_t, _ psn: inout ProcessSerialNumber) -> OSStatus

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: inout CGWindowID) -> AXError
@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

// kAXWindowsAttribute omits windows in other Spaces, so probe the app's AX
// element IDs directly for the one backing this window (as AltTab does).
func axWindow(pid: pid_t, wid: CGWindowID) -> AXUIElement? {
    var token = Data(count: 20)
    token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
    token.replaceSubrange(8..<12, with: withUnsafeBytes(of: UInt32(0x636f636f)) { Data($0) })
    for elementID in UInt64(0)..<1000 {
        token.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementID) { Data($0) })
        guard let element = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
        var elementWID: CGWindowID = 0
        if _AXUIElementGetWindow(element, &elementWID) == .success && elementWID == wid {
            return element
        }
    }
    return nil
}

func focusWindow(_ wid: CGWindowID, of app: NSRunningApplication) {
    var psn = ProcessSerialNumber()
    guard GetProcessForPID(app.processIdentifier, &psn) == noErr else { return }
    _ = _SLPSSetFrontProcessWithOptions(&psn, wid, slpsUserGenerated)
    if let window = axWindow(pid: app.processIdentifier, wid: wid) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }
}

func hasVisibleWindow(app: NSRunningApplication) -> Bool {
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let windows = windowsRef as? [AXUIElement] else { return false }
    return windows.contains { window in
        var roleRef: CFTypeRef?
        var minRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleRef)
        AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minRef)
        return (roleRef as? String) == kAXWindowRole as String
            && (minRef as? Bool) == false
    }
}

private let nKeyCode: CGKeyCode = 0x2D

func openNewWindow(for app: NSRunningApplication) {
    let src = CGEventSource(stateID: .hidSystemState)
    guard let down = CGEvent(keyboardEventSource: src, virtualKey: nKeyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: src, virtualKey: nKeyCode, keyDown: false) else { return }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.postToPid(app.processIdentifier)
    up.postToPid(app.processIdentifier)
}

// MARK: - Event tap

var cmdTabWasPressed = false
var expectingSwitch = false

let eventCallback: CGEventTapCallBack = { _, type, event, _ in
    switch type {
    case .keyDown:
        if event.getIntegerValueField(.keyboardEventKeycode) == tabKeyCode
            && event.flags.contains(.maskCommand) {
            cmdTabWasPressed = true
        }
    case .flagsChanged:
        if !event.flags.contains(.maskCommand) && cmdTabWasPressed {
            cmdTabWasPressed = false
            expectingSwitch = true
        }
    case .leftMouseDown:
        // Clicking an icon in the switcher activates the app while Cmd is
        // still held, i.e. before the release above would arm the check.
        if cmdTabWasPressed {
            cmdTabWasPressed = false
            expectingSwitch = true
        }
    default:
        break
    }
    return Unmanaged.passRetained(event)
}

// MARK: - App activation observer

// App awaiting a window check until the Space switch completes.
var pendingApp: NSRunningApplication?

NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification,
    object: nil,
    queue: .main
) { notification in
    guard expectingSwitch else { return }
    expectingSwitch = false
    guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication else { return }

    // AX only lists windows in the current Space, so a fullscreen window
    // looks like no window at all. If the app has nothing visible here,
    // jump to its fullscreen window instead of unminimizing or opening one.
    let spaces = fullscreenSpaces()
    if let space = spaces.first(where: { $0.windows[app.processIdentifier] != nil }) {
        if !space.isCurrent && !hasVisibleWindow(app: app) {
            print("Switching to fullscreen window of \(app.localizedName ?? "?")")
            focusWindow(space.windows[app.processIdentifier]!, of: app)
        }
        return
    }

    // Leaving a fullscreen Space: wait for the switch to finish, or the
    // target app's windows aren't visible to AX yet.
    if spaces.contains(where: { $0.isCurrent }) {
        pendingApp = app
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard pendingApp === app else { return }
            pendingApp = nil
            ensureVisibleWindow(app: app)
        }
        return
    }

    ensureVisibleWindow(app: app)
}

NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.activeSpaceDidChangeNotification,
    object: nil,
    queue: .main
) { _ in
    guard let app = pendingApp else { return }
    pendingApp = nil
    ensureVisibleWindow(app: app)
}

// MARK: - Entry point

requireAccessibility()

let eventsOfInterest: CGEventMask =
    (1 << CGEventType.keyDown.rawValue) |
    (1 << CGEventType.flagsChanged.rawValue) |
    (1 << CGEventType.leftMouseDown.rawValue)

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: eventsOfInterest,
    callback: eventCallback,
    userInfo: nil
) else {
    print("❌ Could not create event tap. Make sure Accessibility is granted.")
    exit(1)
}

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

print("Event tap created, run loop starting")

RunLoop.main.run()
