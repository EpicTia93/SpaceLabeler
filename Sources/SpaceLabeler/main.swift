import AppKit
import ApplicationServices
import ColorSync

enum LabelPosition: String, CaseIterable {
    case topLeft = "Top left"
    case topCenter = "Top center"
    case topRight = "Top right"
    case middleLeft = "Middle left"
    case center = "Center"
    case middleRight = "Middle right"
    case bottomLeft = "Bottom left"
    case bottomCenter = "Bottom center"
    case bottomRight = "Bottom right"
}

enum ColorMode: String {
    case varied = "Different colors"
    case uniform = "Same color"
}

struct Desktop: Hashable {
    let number: Int
    let display: Int
    let frame: CGRect // Accessibility coordinates: origin at the upper left of the primary display.
    let spaceUUID: String
    let displayUUID: String
    var key: String { spaceUUID }
    var legacyKey: String { "display-\(display)-desktop-\(number)" }
}

@MainActor
final class Preferences {
    private let defaults = UserDefaults.standard
    var position: LabelPosition {
        get { LabelPosition(rawValue: defaults.string(forKey: "position") ?? "Center") ?? .center }
        set { defaults.set(newValue.rawValue, forKey: "position") }
    }
    var colorMode: ColorMode {
        get { ColorMode(rawValue: defaults.string(forKey: "colorMode") ?? "Different colors") ?? .varied }
        set { defaults.set(newValue.rawValue, forKey: "colorMode") }
    }
    var sharedColor: NSColor {
        get {
            guard let data = defaults.data(forKey: "sharedColor"),
                  let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
            else { return NSColor.systemBlue }
            return color
        }
        set {
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: newValue, requiringSecureCoding: true) {
                defaults.set(data, forKey: "sharedColor")
            }
        }
    }
    func label(for desktop: Desktop) -> String {
        defaults.string(forKey: "label.\(desktop.key)") ?? ""
    }
    func setLabel(_ value: String, for desktop: Desktop) {
        let key = "label.\(desktop.key)"
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { defaults.removeObject(forKey: key) }
        else { defaults.set(trimmed, forKey: key) }
    }

    func migrateLegacyLabels(for desktops: [Desktop]) {
        for group in Dictionary(grouping: desktops, by: \.displayUUID) {
            let displayUUID = group.key
            let marker = "migratedLabels.\(displayUUID)"
            guard !defaults.bool(forKey: marker), let first = group.value.first else { continue }
            let prefix = "label.display-\(first.display)-desktop-"
            for desktop in group.value {
                let oldKey = "label.\(desktop.legacyKey)"
                let newKey = "label.\(desktop.key)"
                if defaults.object(forKey: newKey) == nil,
                   let label = defaults.string(forKey: oldKey) {
                    defaults.set(label, forKey: newKey)
                }
            }
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
                defaults.removeObject(forKey: key)
            }
            defaults.set(true, forKey: marker)
        }
    }
}

// Dock's numbered AX previews are positional. The Spaces preference keeps the
// UUIDs in that same order, so a deleted desktop cannot transfer its label to
// the desktop that takes its number.
@MainActor
final class SpaceIdentityResolver {
    private func displayUUID(_ screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    func resolve(_ desktops: [DesktopPreview], screens: [NSScreen]) -> [Desktop]? {
        guard CFPreferencesAppSynchronize("com.apple.spaces" as CFString),
              let configuration = CFPreferencesCopyAppValue(
                "SpacesDisplayConfiguration" as CFString, "com.apple.spaces" as CFString
              ) as? [String: Any],
              let management = configuration["Management Data"] as? [String: Any],
              let monitors = management["Monitors"] as? [[String: Any]]
        else { return nil }

        var resolved: [Desktop] = []
        for (display, previews) in Dictionary(grouping: desktops, by: \.display) {
            guard screens.indices.contains(display),
                  let screenUUID = displayUUID(screens[display]),
                  let screenNumber = screens[display].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            let identifier = screenNumber.uint32Value == CGMainDisplayID() ? "Main" : screenUUID
            guard let monitor = monitors.first(where: {
                ($0["Display Identifier"] as? String)?.caseInsensitiveCompare(identifier) == .orderedSame
            }), let spaces = monitor["Spaces"] as? [[String: Any]] else { return nil }
            let uuids = spaces.compactMap { space -> String? in
                guard (space["type"] as? Int) == 0 else { return nil }
                return space["uuid"] as? String
            }
            guard !uuids.isEmpty, previews.count == uuids.count,
                  Set(previews.map(\.number)) == Set(1...uuids.count),
                  Set(uuids).count == uuids.count else { return nil }
            for preview in previews {
                resolved.append(Desktop(number: preview.number, display: display,
                                        frame: preview.frame, spaceUUID: uuids[preview.number - 1],
                                        displayUUID: screenUUID))
            }
        }
        return resolved.sorted { ($0.display, $0.number) < ($1.display, $1.number) }
    }
}

struct DesktopPreview {
    let number: Int
    let display: Int
    let frame: CGRect
    var key: String { "display-\(display)-desktop-\(number)" }
}

// Mission Control is owned by Dock. Its accessibility tree exposes desktop
// thumbnails while the Spaces strip is expanded. We read it; we never modify Dock.
@MainActor
final class MissionControlScanner {
    private let identities = SpaceIdentityResolver()
    private func value(_ element: AXUIElement, _ key: CFString) -> AnyObject? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key, &result) == .success else { return nil }
        return result
    }

    private func string(_ element: AXUIElement, _ key: CFString) -> String? {
        value(element, key) as? String
    }

    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute as CFString),
              let size = value(element, kAXSizeAttribute as CFString),
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    func scan() -> [Desktop] {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return [] }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.3)
        var hits: [(number: Int, frame: CGRect)] = []
        var visited = 0

        func walk(_ element: AXUIElement, ancestors: [CGRect], depth: Int) {
            guard depth < 12, visited < 600 else { return }
            visited += 1
            let ownFrame = frame(element)
            let candidates = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
                .compactMap { string(element, $0 as CFString) }
            for title in candidates {
                guard let range = title.range(of: #"^Desktop\s+(\d+)$"#, options: .regularExpression),
                      range.lowerBound == title.startIndex,
                      range.upperBound == title.endIndex,
                      let number = Int(title.split(separator: " ").last ?? "") else { continue }
                let possibleFrames = ([ownFrame].compactMap { $0 } + ancestors.reversed())
                // Match Dock's thumbnail container. The actual preview dimensions
                // vary with display size and the number of desktops.
                if let thumbnail = possibleFrames.first(where: {
                    $0.width >= 70 && $0.height >= 40 && $0.height <= 300
                }) {
                    hits.append((number, thumbnail))
                }
            }
            guard let children = value(element, kAXChildrenAttribute as CFString) as? [AXUIElement] else { return }
            let nextAncestors = ownFrame.map { ancestors + [$0] } ?? ancestors
            for child in children { walk(child, ancestors: nextAncestors, depth: depth + 1) }
        }
        walk(root, ancestors: [], depth: 0)

        // Keep only thumbnail-sized frames in the upper portion of each screen.
        let screens = NSScreen.screens
        var result: [DesktopPreview] = []
        for hit in hits {
            guard let display = screens.firstIndex(where: { screen in
                let bounds = screen.frame
                let primaryTop = screens.first?.frame.maxY ?? 0
                let axBounds = CGRect(x: bounds.minX, y: primaryTop - bounds.maxY,
                                      width: bounds.width, height: bounds.height)
                return axBounds.intersects(hit.frame) && hit.frame.midY < axBounds.minY + min(300, bounds.height * 0.4)
            }) else { continue }
            let desktop = DesktopPreview(number: hit.number, display: display, frame: hit.frame)
            if !result.contains(where: { $0.key == desktop.key }) { result.append(desktop) }
        }
        // A shared AX container can look like a preview on some macOS versions.
        // If two desktops resolve to substantially the same rectangle, wait for
        // the strip to expand rather than stacking badges in one location.
        let overlapping = result.contains { first in
            result.contains { second in
                first.key != second.key && first.display == second.display &&
                first.frame.intersection(second.frame).width > first.frame.width * 0.5 &&
                first.frame.intersection(second.frame).height > first.frame.height * 0.5
            }
        }
        guard !overlapping else { return [] }
        return identities.resolve(result, screens: screens) ?? []
    }
}

final class BadgeView: NSView {
    var title = "" { didSet { needsDisplay = true } }
    var fill = NSColor.systemBlue { didSet { needsDisplay = true } }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
        let luminance = fill.usingColorSpace(.deviceRGB).map {
            0.2126 * $0.redComponent + 0.7152 * $0.greenComponent + 0.0722 * $0.blueComponent
        } ?? 0
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: luminance > 0.62 ? NSColor.black : NSColor.white
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2,
                                            y: (bounds.height - size.height) / 2),
                                 withAttributes: attributes)
    }
}

@MainActor
final class OverlayManager {
    private var windows: [NSPanel] = []
    private let palette: [NSColor] = [
        .systemOrange, .systemGreen, .systemBlue, .systemPink,
        .systemPurple, .systemTeal, .systemYellow, .systemRed
    ]

    func show(_ desktops: [Desktop], preferences: Preferences) {
        hide()
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        for desktop in desktops {
            let label = preferences.label(for: desktop)
            guard !label.isEmpty else { continue }
            let thumbnail = desktop.frame
            let width = min(max(CGFloat(label.count) * 8 + 28, 60), max(40, thumbnail.width - 10))
            let height: CGFloat = 30
            let margin: CGFloat = 5
            let axY: CGFloat
            switch preferences.position {
            case .topLeft, .topCenter, .topRight: axY = thumbnail.minY + margin
            case .middleLeft, .center, .middleRight: axY = thumbnail.midY - height / 2
            case .bottomLeft, .bottomCenter, .bottomRight: axY = thumbnail.maxY - height - margin
            }
            let axX: CGFloat
            switch preferences.position {
            case .topLeft, .middleLeft, .bottomLeft: axX = thumbnail.minX + margin
            case .topCenter, .center, .bottomCenter: axX = thumbnail.midX - width / 2
            case .topRight, .middleRight, .bottomRight: axX = thumbnail.maxX - width - margin
            }
            let appKitFrame = CGRect(x: axX,
                                     y: primaryTop - axY - height,
                                     width: width, height: height)
            let panel = NSPanel(contentRect: appKitFrame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            panel.level = .screenSaver
            let badge = BadgeView(frame: CGRect(origin: .zero, size: appKitFrame.size))
            badge.title = label
            badge.fill = preferences.colorMode == .uniform
                ? preferences.sharedColor
                : palette[(desktop.number - 1) % palette.count]
            panel.contentView = badge
            panel.orderFrontRegardless()
            windows.append(panel)
        }
    }

    func hide() {
        for window in windows { window.orderOut(nil); window.close() }
        windows.removeAll()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences()
    private let scanner = MissionControlScanner()
    private let overlay = OverlayManager()
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var mouseMonitor: Any?
    private var holdTimer: Timer?
    private var heldDesktop: Desktop?
    private var holdStart = CGPoint.zero
    private var desktops: [Desktop] = []
    private var lastSignature = ""
    private var lastAccessibilityState: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let url = Bundle.main.url(forResource: "top-bar-logo", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            icon.size = NSSize(width: 21, height: 20)
            statusItem.button?.image = icon
            statusItem.button?.imageScaling = .scaleProportionallyDown
        } else {
            statusItem.button?.title = "🏷"
        }
        statusItem.button?.toolTip = "Space Labeler"
        statusItem.menu = NSMenu()
        refreshMenu()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        installMouseObserver()
        refreshMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let eventTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        holdTimer?.invalidate()
        timer?.invalidate()
    }

    private func installMouseObserver() {
        let mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue) |
            (CGEventMask(1) << CGEventType.leftMouseUp.rawValue) |
            (CGEventMask(1) << CGEventType.leftMouseDragged.rawValue)
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let app = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
                MainActor.assumeIsolated {
                    app.handleMouse(type: type, point: event.location)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        if let eventTap {
            eventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            if let eventTapSource {
                CFRunLoopAddSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
        } else {
            // Some Macs deny passive event taps. Keep a usable fallback.
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
            ) { [weak self] event in
                MainActor.assumeIsolated {
                    let type: CGEventType
                    switch event.type {
                    case .leftMouseDown: type = .leftMouseDown
                    case .leftMouseUp: type = .leftMouseUp
                    default: type = .leftMouseDragged
                    }
                    self?.handleMouse(type: type, point: CGPoint(
                        x: NSEvent.mouseLocation.x,
                        y: (NSScreen.screens.first?.frame.maxY ?? 0) - NSEvent.mouseLocation.y
                    ))
                }
            }
        }
    }

    private func poll() {
        let trusted = AXIsProcessTrusted()
        if trusted != lastAccessibilityState {
            lastAccessibilityState = trusted
            refreshMenu()
        }
        guard trusted else {
            overlay.hide()
            lastSignature = ""
            return
        }
        let found = scanner.scan()
        if !found.isEmpty { preferences.migrateLegacyLabels(for: found) }
        let signature = found.map { "\($0.key):\($0.frame)" }.joined(separator: "|")
        guard signature != lastSignature else { return }
        lastSignature = signature
        if found.isEmpty {
            overlay.hide()
        }
        else {
            desktops = found
            overlay.show(found, preferences: preferences)
        }
        refreshMenu()
    }

    private func redrawVisibleLabels() {
        let visible = scanner.scan()
        if !visible.isEmpty { preferences.migrateLegacyLabels(for: visible) }
        if visible.isEmpty { overlay.hide() }
        else { overlay.show(visible, preferences: preferences) }
    }

    private func handleMouse(type: CGEventType, point: CGPoint) {
        switch type {
        case .leftMouseDown:
            cancelHold()
            guard !lastSignature.isEmpty else { return }
            guard let desktop = desktops.first(where: {
                $0.frame.insetBy(dx: -6, dy: -6).contains(point)
            }) else { return }
            heldDesktop = desktop
            holdStart = point
            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let target = self.heldDesktop else { return }
                    self.cancelHold()
                    guard AXIsProcessTrusted() else { return }
                    self.editLabel(for: target)
                }
            }
        case .leftMouseDragged:
            if hypot(point.x - holdStart.x, point.y - holdStart.y) > 8 { cancelHold() }
        case .leftMouseUp:
            cancelHold()
        default: break
        }
    }

    private func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        heldDesktop = nil
    }

    private func refreshMenu() {
        let menu = NSMenu()
        let heading = NSMenuItem(title: "Space Labeler", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())
        let access = NSMenuItem(
            title: AXIsProcessTrusted() ? "Accessibility: enabled" : "Accessibility: denied to this build",
            action: nil, keyEquivalent: ""
        )
        access.isEnabled = false
        menu.addItem(access)
        if !AXIsProcessTrusted() {
            let help = NSMenuItem(title: "If already enabled, remove and add this app again", action: nil, keyEquivalent: "")
            help.isEnabled = false
            menu.addItem(help)
        }
        let hint = NSMenuItem(title: "Press and hold a Desktop preview to label it", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        let mouseStatus = NSMenuItem(
            title: eventTap == nil ? "Hold detection: AppKit fallback" : "Hold detection: Quartz event tap",
            action: nil, keyEquivalent: ""
        )
        mouseStatus.isEnabled = false
        menu.addItem(mouseStatus)
        let editMenu = NSMenuItem(title: "Edit labels…", action: nil, keyEquivalent: "")
        let desktopMenu = NSMenu()
        if desktops.isEmpty {
            let help = NSMenuItem(title: "Open expanded Mission Control first", action: nil, keyEquivalent: "")
            help.isEnabled = false
            desktopMenu.addItem(help)
        } else {
            for (index, desktop) in desktops.enumerated() {
                let label = preferences.label(for: desktop)
                let item = NSMenuItem(
                    title: "Desktop \(desktop.number)" + (label.isEmpty ? "" : " — \(label)"),
                    action: #selector(editLabelFromMenu(_:)), keyEquivalent: ""
                )
                item.target = self
                item.tag = index
                desktopMenu.addItem(item)
            }
        }
        menu.setSubmenu(desktopMenu, for: editMenu)
        menu.addItem(editMenu)
        menu.addItem(.separator())
        let placement = NSMenuItem(title: "Label position", action: nil, keyEquivalent: "")
        let placementMenu = NSMenu()
        for (index, position) in LabelPosition.allCases.enumerated() {
            let item = NSMenuItem(title: position.rawValue, action: #selector(setPosition(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = preferences.position == position ? .on : .off
            placementMenu.addItem(item)
        }
        menu.setSubmenu(placementMenu, for: placement)
        menu.addItem(placement)
        let colors = NSMenuItem(title: "Label colors", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu()
        for (index, mode) in [ColorMode.varied, .uniform].enumerated() {
            let item = NSMenuItem(title: mode.rawValue, action: #selector(setColorMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = preferences.colorMode == mode ? .on : .off
            colorMenu.addItem(item)
        }
        colorMenu.addItem(.separator())
        let picker = NSMenuItem(title: "Choose shared color…", action: #selector(chooseSharedColor(_:)), keyEquivalent: "")
        picker.target = self
        colorMenu.addItem(picker)
        menu.setSubmenu(colorMenu, for: colors)
        menu.addItem(colors)
        menu.addItem(.separator())
        let permission = NSMenuItem(title: "Open Accessibility Settings…", action: #selector(requestAccessibility(_:)), keyEquivalent: "")
        permission.target = self
        menu.addItem(permission)
        let quit = NSMenuItem(title: "Quit Space Labeler", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func editLabel(for desktop: Desktop) {
        let alert = NSAlert()
        alert.messageText = "Label Desktop \(desktop.number)"
        alert.informativeText = "Leave this empty to show no label."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 270, height: 25))
        field.stringValue = preferences.label(for: desktop)
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            preferences.setLabel(field.stringValue, for: desktop)
            redrawVisibleLabels()
            refreshMenu()
        }
    }

    @objc private func editLabelFromMenu(_ sender: NSMenuItem) {
        guard desktops.indices.contains(sender.tag) else { return }
        editLabel(for: desktops[sender.tag])
    }

    @objc private func setPosition(_ sender: NSMenuItem) {
        preferences.position = LabelPosition.allCases[sender.tag]
        redrawVisibleLabels()
        refreshMenu()
    }

    @objc private func setColorMode(_ sender: NSMenuItem) {
        preferences.colorMode = sender.tag == 0 ? .varied : .uniform
        redrawVisibleLabels()
        refreshMenu()
    }

    @objc private func chooseSharedColor(_ sender: NSMenuItem) {
        let panel = NSColorPanel.shared
        panel.color = preferences.sharedColor
        panel.setTarget(self)
        panel.setAction(#selector(sharedColorChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func sharedColorChanged(_ sender: NSColorPanel) {
        preferences.sharedColor = sender.color
        if preferences.colorMode == .uniform { redrawVisibleLabels() }
    }

    @objc private func requestAccessibility(_ sender: Any?) {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
