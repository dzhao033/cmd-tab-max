import Cocoa
import ApplicationServices

// Disable stdout buffering so log output reaches the file immediately.
setbuf(stdout, nil)

private let logTimestamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
}()

func log(_ message: String) {
    print("\(logTimestamp.string(from: Date())) \(message)")
}

private let tabKeyCode: Int64 = 48
private let skippedBundleIDs: Set<String> = [
    "com.apple.systemuiserver",
]

// MARK: - Accessibility permission check

// Written by `make install` right after it resets the grant, so there is
// nothing to wait for; consumed on startup so later logins still retry.
private let freshInstallMarker = "/tmp/CmdTabMax.fresh-install"

func requireAccessibility() {
    let freshInstall = (try? FileManager.default.removeItem(atPath: freshInstallMarker)) != nil

    // Retry silently — TCC may not be ready immediately at login.
    for attempt in 0..<20 {
        if AXIsProcessTrusted() { return }
        if freshInstall || attempt == 19 { break }
        waitServicingRunLoop(0.5)
    }

    // Show the System Settings prompt, then poll until the user grants.
    // Polling and continuing in-process avoids the TCC propagation race
    // that occurs when we exit and KeepAlive restarts us too quickly.
    log("Accessibility not granted — opening System Settings")
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    AXIsProcessTrustedWithOptions(opts)
    while !AXIsProcessTrusted() {
        waitServicingRunLoop(0.5)
    }
    log("Accessibility granted — continuing")
}

// AXIsProcessTrusted caches its answer until the process handles the system's
// trust-change notification, which arrives via the main run loop. Sleeping
// the thread would leave the cache stale forever, so spin the run loop instead.
func waitServicingRunLoop(_ seconds: TimeInterval) {
    let deadline = Date(timeIntervalSinceNow: seconds)
    // A run loop with no sources returns immediately; the timer keeps it waiting.
    let timer = Timer(fire: deadline, interval: 0, repeats: false) { _ in }
    RunLoop.current.add(timer, forMode: .default)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: deadline)
    }
    timer.invalidate()
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

// Element IDs are handed out sequentially over the app's lifetime (Chrome's
// windows were past 3000 after a few days), so keep scanning until a long run
// of IDs turns up no window rather than stopping at a fixed bound.
private let remoteWindowScanGap: UInt64 = 5000
private let remoteWindowScanLimit: UInt64 = 200_000

// kAXWindowsAttribute omits windows in other Spaces, so probe the app's AX
// element IDs directly (as AltTab does). `body` returns true to stop early.
func forEachRemoteWindow(pid: pid_t, _ body: (AXUIElement, CGWindowID) -> Bool) {
    var token = Data(count: 20)
    token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
    token.replaceSubrange(8..<12, with: withUnsafeBytes(of: UInt32(0x636f636f)) { Data($0) })
    var lastHit: UInt64 = 0
    var elementID: UInt64 = 0
    while elementID < remoteWindowScanLimit && elementID - lastHit < remoteWindowScanGap {
        defer { elementID += 1 }
        token.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementID) { Data($0) })
        guard let element = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &wid) == .success else { continue }
        lastHit = elementID
        if body(element, wid) { return }
    }
}

func axWindow(pid: pid_t, wid: CGWindowID) -> AXUIElement? {
    var found: AXUIElement?
    forEachRemoteWindow(pid: pid) { element, elementWID in
        if elementWID == wid { found = element }
        return found != nil
    }
    return found
}

@_silgen_name("SLPSPostEventRecordTo")
private func SLPSPostEventRecordTo(_ psn: inout ProcessSerialNumber, _ bytes: UnsafeMutablePointer<UInt8>) -> CGError

// Fronting an inactive app's window shows it without making it the app's key
// window, so the app keeps treating another window as focused (and reports
// that one later). Post the window-server events that make it key, as AltTab
// does.
func makeKeyWindow(_ wid: CGWindowID, psn: inout ProcessSerialNumber) {
    var bytes = [UInt8](repeating: 0, count: 0xf8)
    bytes[0x04] = 0xf8
    bytes[0x3a] = 0x10
    withUnsafeBytes(of: wid) { bytes.replaceSubrange(0x3c..<0x40, with: $0) }
    bytes.replaceSubrange(0x20..<0x30, with: repeatElement(0xff, count: 0x10))
    bytes[0x08] = 0x01
    _ = SLPSPostEventRecordTo(&psn, &bytes)
    bytes[0x08] = 0x02
    _ = SLPSPostEventRecordTo(&psn, &bytes)
}

func focusWindow(_ wid: CGWindowID, of app: NSRunningApplication, element: AXUIElement? = nil) {
    var psn = ProcessSerialNumber()
    guard GetProcessForPID(app.processIdentifier, &psn) == noErr else { return }
    _ = _SLPSSetFrontProcessWithOptions(&psn, wid, slpsUserGenerated)
    makeKeyWindow(wid, psn: &psn)
    if let window = element ?? axWindow(pid: app.processIdentifier, wid: wid) {
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

// MARK: - Window cycling

private let graveKeyCode: Int64 = 50

// Cmd-` only cycles windows within the current Space, so it can neither reach
// an app's fullscreen window nor leave it. Take over only when that matters.
func appNeedingWindowCycling() -> NSRunningApplication? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let pid = app.processIdentifier
    return fullscreenSpaces().contains { $0.windows[pid] != nil } ? app : nil
}

func cycleWindows(of app: NSRunningApplication, backwards: Bool) {
    let pid = app.processIdentifier
    let spaces = fullscreenSpaces()

    // Standard windows only: fullscreen Chrome also reports its toolbar and
    // overlay panels as AXWindows, which aren't real cycle targets.
    var elements: [CGWindowID: AXUIElement] = [:]
    func consider(_ window: AXUIElement, _ wid: CGWindowID) {
        var subroleRef: CFTypeRef?
        var minRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleRef)
        AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minRef)
        if (subroleRef as? String) == kAXStandardWindowSubrole as String && (minRef as? Bool) != true {
            elements[wid] = window
        }
    }

    // From a regular Space kAXWindowsAttribute also lists the app's fullscreen
    // windows, but from inside a fullscreen Space it lists only that Space's,
    // so fall back to the slower scan to find the desktop windows.
    var current = spaces.first(where: { $0.isCurrent })?.windows[pid]
    if current != nil {
        forEachRemoteWindow(pid: pid) { window, wid in consider(window, wid); return false }
    } else {
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement] {
            for window in windows {
                var wid: CGWindowID = 0
                if _AXUIElementGetWindow(window, &wid) == .success { consider(window, wid) }
            }
        }
    }

    // Sorted for a stable cycle; z-order would just flip between two windows.
    let wids = Set(elements.keys).union(spaces.compactMap { $0.windows[pid] }).sorted()
    guard wids.count > 1 else { return }

    // AX's focused window can lag behind Space switches, so ask the window
    // server which of the app's windows is frontmost on screen.
    if current == nil,
       let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
        current = onScreen.lazy
            .filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid }
            .compactMap { ($0[kCGWindowNumber as String] as? Int).map(CGWindowID.init) }
            .first { wids.contains($0) }
    }

    let next: CGWindowID
    if let index = current.flatMap({ wids.firstIndex(of: $0) }) {
        next = wids[(index + (backwards ? wids.count - 1 : 1)) % wids.count]
    } else {
        next = wids[0]
    }
    focusWindow(next, of: app, element: elements[next])
}

// MARK: - Switcher selection

// While Cmd-Tab is held, the Dock exposes the switcher as an
// AXProcessSwitcherList whose selected child is the highlighted app.
func switcherList() -> AXUIElement? {
    guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
    let axDock = AXUIElementCreateApplication(dock.processIdentifier)
    // Called from the event tap; don't let a busy Dock stall input.
    AXUIElementSetMessagingTimeout(axDock, 0.1)

    var childrenRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axDock, kAXChildrenAttribute as CFString, &childrenRef) == .success,
          let children = childrenRef as? [AXUIElement] else { return nil }
    return children.first { child in
        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(child, kAXSubroleAttribute as CFString, &subroleRef)
        return (subroleRef as? String) == "AXProcessSwitcherList"
    }
}

// The item carries only the app's name, so give up when that's ambiguous.
func selectedApp(in switcher: AXUIElement) -> NSRunningApplication? {
    var selectedRef: CFTypeRef?
    var titleRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(switcher, kAXSelectedChildrenAttribute as CFString, &selectedRef) == .success,
          let selected = (selectedRef as? [AXUIElement])?.first,
          AXUIElementCopyAttributeValue(selected, kAXTitleAttribute as CFString, &titleRef) == .success,
          let title = titleRef as? String else { return nil }
    let matches = NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular && $0.localizedName == title
    }
    return matches.count == 1 ? matches[0] : nil
}

// Regular apps, most recently activated first: the order the switcher uses.
var activationHistory: [pid_t] = []

// The app the in-progress Cmd-Tab will land on, if it can be determined.
func switchTarget() -> NSRunningApplication? {
    if let switcher = switcherList() {
        return selectedApp(in: switcher)
    }
    // A quick tap completes before the switcher is ever drawn, leaving
    // nothing to read; a single forward Tab always means the previous app.
    guard tabPresses == 1, !tabUsedShift else { return nil }
    return previousApp()
}

// Where a single forward Tab lands: the app used before the frontmost one.
func previousApp() -> NSRunningApplication? {
    guard activationHistory.count >= 2,
          activationHistory[0] == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
    return NSRunningApplication(processIdentifier: activationHistory[1])
}

// The fullscreen window to bring up when switching to `app`, if any: the one
// the user last left the app from, or any if the app has nothing visible here
// (a fullscreen window looks like no window at all to AX).
func fullscreenTarget(for app: NSRunningApplication, spaces: [FullscreenSpace]) -> CGWindowID? {
    let pid = app.processIdentifier
    let elsewhere = spaces.filter { !$0.isCurrent }.compactMap { $0.windows[pid] }
    guard !elsewhere.isEmpty else { return nil }
    if let last = lastFocusedWindow[pid], elsewhere.contains(last) { return last }
    if spaces.contains(where: { $0.isCurrent && $0.windows[pid] != nil }) || hasVisibleWindow(app: app) {
        return nil
    }
    return elsewhere.first
}

private let escapeKeyCode: CGKeyCode = 0x35

// Cmd-Esc dismisses the switcher without activating anything.
func cancelSwitcher() {
    let src = CGEventSource(stateID: .hidSystemState)
    guard let down = CGEvent(keyboardEventSource: src, virtualKey: escapeKeyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: src, virtualKey: escapeKeyCode, keyDown: false) else { return }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.post(tap: .cgSessionEventTap)
    up.post(tap: .cgSessionEventTap)
}

// If the switch should land on a fullscreen window, cancel the switcher and
// go there ourselves. Letting the Dock finish the switch activates the app in
// the current Space, flashing (and keeping focus on) a window here instead.
// The caller must swallow the event that would have completed the switch.
func takeOverSwitch() -> Bool {
    guard let app = switchTarget(),
          app != NSWorkspace.shared.frontmostApplication,
          let target = fullscreenTarget(for: app, spaces: fullscreenSpaces()) else { return false }
    log("Switching straight to fullscreen window of \(app.localizedName ?? "?")")
    cancelSwitcher()
    DispatchQueue.main.async { focusWindow(target, of: app) }
    return true
}

// MARK: - Quick Cmd-Tab

// Before the switcher is drawn the Dock ignores the Cmd-Esc cancel, so a
// quick tap would still activate the app in the current Space and flash a
// window there. When a quick tap would land on a fullscreen window, hold the
// Tab back from the Dock entirely and do the switch ourselves on release.
struct DeferredTab {
    let event: CGEvent
    let app: NSRunningApplication
    let window: CGWindowID
}

var deferredTab: DeferredTab?

// Longer than a quick tap; past it the user wants the switcher, so the Dock
// gets the Tab after all (delaying the switcher's appearance by this much).
private let quickTapWindow: TimeInterval = 0.2

// Marks events we re-post so the tap passes them through untouched.
private let repostedEventMarker: Int64 = 0x43544D58

func repost(_ event: CGEvent) {
    guard let copy = event.copy() else { return }
    copy.setIntegerValueField(.eventSourceUserData, value: repostedEventMarker)
    copy.post(tap: .cgSessionEventTap)
}

func releaseDeferredTab() {
    guard let deferred = deferredTab else { return }
    deferredTab = nil
    repost(deferred.event)
}

func deferTabIfQuickSwitchNeedsIt(_ event: CGEvent) -> Bool {
    guard let app = previousApp(),
          let window = fullscreenTarget(for: app, spaces: fullscreenSpaces()) else { return false }
    let deferred = DeferredTab(event: event, app: app, window: window)
    deferredTab = deferred
    DispatchQueue.main.asyncAfter(deadline: .now() + quickTapWindow) {
        if deferredTab?.event === deferred.event { releaseDeferredTab() }
    }
    return true
}

// MARK: - Event tap

var cmdTabWasPressed = false
var tabPresses = 0
var tabUsedShift = false
var expectingSwitch = false
var eventTap: CFMachPort?

let eventCallback: CGEventTapCallBack = { _, type, event, _ in
    if event.getIntegerValueField(.eventSourceUserData) == repostedEventMarker {
        return Unmanaged.passRetained(event)
    }
    switch type {
    case .keyDown:
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isCmdTab = keyCode == tabKeyCode && event.flags.contains(.maskCommand)
        if isCmdTab {
            if !cmdTabWasPressed {
                tabPresses = 0
                tabUsedShift = false
            }
            cmdTabWasPressed = true
            tabPresses += 1
            tabUsedShift = tabUsedShift || event.flags.contains(.maskShift)
        }
        if deferredTab != nil {
            // More than a quick tap: hand the Dock the Tab it missed, then
            // this key, in order.
            releaseDeferredTab()
            repost(event)
            return nil
        }
        if isCmdTab && tabPresses == 1 && !tabUsedShift && deferTabIfQuickSwitchNeedsIt(event) {
            return nil
        }
        if keyCode == graveKeyCode
            && event.flags.contains(.maskCommand)
            && event.flags.isDisjoint(with: [.maskControl, .maskAlternate]),
           let app = appNeedingWindowCycling() {
            let backwards = event.flags.contains(.maskShift)
            DispatchQueue.main.async { cycleWindows(of: app, backwards: backwards) }
            return nil
        }
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        // The keyDown path now does real work; recover if macOS ever
        // disables the tap for being slow instead of silently going dead.
        log("Event tap disabled (\(type.rawValue)), re-enabling")
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
    case .flagsChanged:
        if !event.flags.contains(.maskCommand) && cmdTabWasPressed {
            cmdTabWasPressed = false
            if let deferred = deferredTab {
                // The Dock never saw this switch; make it ourselves.
                deferredTab = nil
                log("Quick-switching to fullscreen window of \(deferred.app.localizedName ?? "?")")
                DispatchQueue.main.async { focusWindow(deferred.window, of: deferred.app) }
                break
            }
            // Still armed after a takeover, in case the cancel didn't land
            // and the Dock activated the app anyway.
            expectingSwitch = true
            if takeOverSwitch() {
                // Deliver the Cmd release after the queued Cmd-Esc, so the
                // switcher sees the cancel while Cmd is still down.
                event.copy()?.post(tap: .cgSessionEventTap)
                return nil
            }
        }
    case .leftMouseDown:
        // Clicking an icon in the switcher activates the app while Cmd is
        // still held, i.e. before the release above would arm the check.
        if cmdTabWasPressed {
            cmdTabWasPressed = false
            expectingSwitch = true
            if takeOverSwitch() { return nil }
        }
    default:
        break
    }
    return Unmanaged.passRetained(event)
}

// MARK: - App activation observer

// App awaiting a window check until the Space switch completes.
var pendingApp: NSRunningApplication?

// Each app's focused window as of when it last lost focus. By the time the
// activation notification arrives, macOS has already re-keyed a window in the
// current Space, so the app's own answer then no longer says where the user was.
var lastFocusedWindow: [pid_t: CGWindowID] = [:]

NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didDeactivateApplicationNotification,
    object: nil,
    queue: .main
) { notification in
    guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication else { return }
    let pid = app.processIdentifier
    var focusedRef: CFTypeRef?
    var wid: CGWindowID = 0
    // Leaving from the app's fullscreen Space is unambiguous, and the window
    // server knows it even when the app's idea of its key window is stale.
    if let fullscreenWID = fullscreenSpaces().first(where: { $0.isCurrent })?.windows[pid] {
        lastFocusedWindow[pid] = fullscreenWID
    } else if AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
       let focusedRef,
       _AXUIElementGetWindow(focusedRef as! AXUIElement, &wid) == .success {
        lastFocusedWindow[pid] = wid
    } else {
        lastFocusedWindow[pid] = nil
    }
}

NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didTerminateApplicationNotification,
    object: nil,
    queue: .main
) { notification in
    guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication else { return }
    lastFocusedWindow[app.processIdentifier] = nil
    activationHistory.removeAll { $0 == app.processIdentifier }
}

NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification,
    object: nil,
    queue: .main
) { notification in
    guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication else { return }
    if app.activationPolicy == .regular {
        activationHistory.removeAll { $0 == app.processIdentifier }
        activationHistory.insert(app.processIdentifier, at: 0)
    }

    guard expectingSwitch else { return }
    expectingSwitch = false
    // A newer switch supersedes any check still waiting on a Space change;
    // otherwise it fires on the next Space switch and targets the wrong app.
    pendingApp = nil

    // Fallback for when the switcher selection couldn't be read: activation
    // alone keeps the user in the current Space, so jump afterwards instead
    // of unminimizing or opening a window.
    let spaces = fullscreenSpaces()
    if spaces.contains(where: { $0.windows[app.processIdentifier] != nil }) {
        if let target = fullscreenTarget(for: app, spaces: spaces) {
            log("Switching to fullscreen window of \(app.localizedName ?? "?")")
            focusWindow(target, of: app)
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
            ensureVisibleWindowIfFrontmost(app: app)
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
    ensureVisibleWindowIfFrontmost(app: app)
}

// Deferred checks can outlive the switch that scheduled them; if the user has
// since moved on, the app's windows aren't in the current Space and would
// look missing.
func ensureVisibleWindowIfFrontmost(app: NSRunningApplication) {
    guard NSWorkspace.shared.frontmostApplication == app else { return }
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
    log("❌ Could not create event tap. Make sure Accessibility is granted.")
    exit(1)
}

eventTap = tap
let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

log("Event tap created, run loop starting")

RunLoop.main.run()
