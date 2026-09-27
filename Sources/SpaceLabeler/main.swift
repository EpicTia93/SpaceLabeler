import AppKit
import ApplicationServices

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
    var key: String { "display-\(display)-desktop-\(number)" }
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
}

// Mission Control is owned by Dock. Its accessibility tree exposes desktop
// thumbnails while the Spaces strip is expanded. We read it; we never modify Dock.
@MainActor
final class MissionControlScanner {
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
                // Collapsed Spaces expose text and sometimes a shared strip group.
                // Neither is an actual desktop preview, so require preview geometry.
                if let thumbnail = possibleFrames.first(where: {
                    $0.width >= 120 && $0.height >= 80 && $0.height <= 300 &&
                    (1.25...2.6).contains($0.width / $0.height)
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
        var result: [Desktop] = []
        for hit in hits {
            guard let display = screens.firstIndex(where: { screen in
                let bounds = screen.frame
                let primaryTop = screens.first?.frame.maxY ?? 0
                let axBounds = CGRect(x: bounds.minX, y: primaryTop - bounds.maxY,
                                      width: bounds.width, height: bounds.height)
                return axBounds.intersects(hit.frame) && hit.frame.midY < axBounds.minY + min(300, bounds.height * 0.4)
            }) else { continue }
            let desktop = Desktop(number: hit.number, display: display, frame: hit.frame)
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
        return result.sorted { ($0.display, $0.number) < ($1.display, $1.number) }
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
    private var mouseMonitor: Any?
    private var holdTimer: Timer?
    private var heldDesktop: Desktop?
    private var holdStart = CGPoint.zero
    private var desktops: [Desktop] = []
    private var lastSignature = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🏷"
        statusItem.button?.toolTip = "Space Labeler"
        statusItem.menu = NSMenu()
        refreshMenu()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouse(event) }
        }
        if !AXIsProcessTrusted() { requestAccessibility(nil) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        holdTimer?.invalidate()
        timer?.invalidate()
    }

    private func poll() {
        guard AXIsProcessTrusted() else { overlay.hide(); return }
        let found = scanner.scan()
        let signature = found.map { "\($0.key):\($0.frame)" }.joined(separator: "|")
        guard signature != lastSignature else { return }
        lastSignature = signature
        if found.isEmpty {
            overlay.hide()
            cancelHold()
        }
        else {
            desktops = found
            overlay.show(found, preferences: preferences)
        }
        refreshMenu()
    }

    private func redrawVisibleLabels() {
        let visible = scanner.scan()
        if visible.isEmpty { overlay.hide() }
        else { overlay.show(visible, preferences: preferences) }
    }

    private func handleMouse(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            cancelHold()
            let point = NSEvent.mouseLocation
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
            guard let desktop = desktops.first(where: {
                let rect = CGRect(x: $0.frame.minX, y: primaryTop - $0.frame.maxY,
                                  width: $0.frame.width, height: $0.frame.height)
                return rect.contains(point)
            }), !scanner.scan().isEmpty else { return }
            heldDesktop = desktop
            holdStart = point
            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let target = self.heldDesktop else { return }
                    self.cancelHold()
                    // Recheck because Mission Control may have closed during the hold.
                    guard self.scanner.scan().contains(where: { $0.key == target.key }) else { return }
                    self.editLabel(for: target)
                }
            }
        case .leftMouseDragged:
            let point = NSEvent.mouseLocation
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
        let hint = NSMenuItem(title: "Press and hold a Desktop preview to label it", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
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
