//
//  WindowArranger.swift
//  MSHNCNTRLBTR
//
//  Arranges windows on the active screen using the Accessibility API.
//

import AppKit
import ApplicationServices

enum WindowLayout: String, CaseIterable, Codable, Identifiable {
    case twoColumns
    case threeColumns
    case grid2x2
    case grid3x3
    case cascade
    case maximizeFocused

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .twoColumns: return "Tile All — 2 Columns"
        case .threeColumns: return "Tile All — 3 Columns"
        case .grid2x2: return "Tile All — 2 × 2 Grid"
        case .grid3x3: return "Tile All — 3 × 3 Grid"
        case .cascade: return "Cascade All"
        case .maximizeFocused: return "Maximize Focused"
        }
    }
}

enum WindowArranger {
    static func apply(_ layout: WindowLayout) {
        let screen = targetScreen()
        let frame = screen.visibleFrame

        switch layout {
        case .twoColumns:
            tileColumns(windowsOnScreen(screen), cols: 2, in: frame)
        case .threeColumns:
            tileColumns(windowsOnScreen(screen), cols: 3, in: frame)
        case .grid2x2:
            tileGrid(windowsOnScreen(screen), rows: 2, cols: 2, in: frame)
        case .grid3x3:
            tileGrid(windowsOnScreen(screen), rows: 3, cols: 3, in: frame)
        case .cascade:
            cascade(windowsOnScreen(screen), in: frame)
        case .maximizeFocused:
            maximizeFocused(in: frame)
        }
    }

    // MARK: - Layouts

    private static func tileColumns(_ windows: [AXUIElement], cols: Int, in frame: NSRect) {
        guard !windows.isEmpty, cols > 0 else { return }
        let perColumn = Int(ceil(Double(windows.count) / Double(cols)))
        let colWidth = frame.width / CGFloat(cols)

        for (i, window) in windows.enumerated() {
            let col = i / perColumn
            let row = i % perColumn
            let inThisCol = min(perColumn, windows.count - col * perColumn)
            let rowHeight = frame.height / CGFloat(inThisCol)
            let cocoa = NSRect(
                x: frame.minX + CGFloat(col) * colWidth,
                y: frame.minY + frame.height - CGFloat(row + 1) * rowHeight,
                width: colWidth,
                height: rowHeight
            )
            setFrame(window, axRect(from: cocoa))
        }
    }

    private static func tileGrid(_ windows: [AXUIElement], rows: Int, cols: Int, in frame: NSRect) {
        let capacity = rows * cols
        let cellWidth = frame.width / CGFloat(cols)
        let cellHeight = frame.height / CGFloat(rows)

        for (i, window) in windows.prefix(capacity).enumerated() {
            let row = i / cols
            let col = i % cols
            let cocoa = NSRect(
                x: frame.minX + CGFloat(col) * cellWidth,
                y: frame.minY + frame.height - CGFloat(row + 1) * cellHeight,
                width: cellWidth,
                height: cellHeight
            )
            setFrame(window, axRect(from: cocoa))
        }
    }

    private static func cascade(_ windows: [AXUIElement], in frame: NSRect) {
        let baseWidth = frame.width * 0.6
        let baseHeight = frame.height * 0.7
        let offset: CGFloat = 30

        for (i, window) in windows.enumerated() {
            let cocoa = NSRect(
                x: frame.minX + CGFloat(i) * offset,
                y: frame.minY + frame.height - baseHeight - CGFloat(i) * offset,
                width: baseWidth,
                height: baseHeight
            )
            setFrame(window, axRect(from: cocoa))
        }
    }

    private static func maximizeFocused(in frame: NSRect) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let win = winRef else { return }
        let window = win as! AXUIElement
        setFrame(window, axRect(from: frame))
    }

    // MARK: - Window enumeration

    private static func windowsOnScreen(_ screen: NSScreen) -> [AXUIElement] {
        var result: [AXUIElement] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            var winsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &winsRef) == .success,
                  let wins = winsRef as? [AXUIElement] else { continue }
            for w in wins {
                if isMinimized(w) { continue }
                guard let axFrameValue = currentFrame(w) else { continue }
                let cocoaFrame = cocoaRect(from: axFrameValue)
                if screen.frame.intersects(cocoaFrame) {
                    result.append(w)
                }
            }
        }
        return result
    }

    private static func isMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success else {
            return false
        }
        return (value as? Bool) ?? false
    }

    private static func currentFrame(_ window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef, let sizeVal = sizeRef else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    // MARK: - Coordinate conversion

    private static var primaryDisplayHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
    }

    private static func axRect(from cocoa: NSRect) -> CGRect {
        let axY = primaryDisplayHeight - cocoa.origin.y - cocoa.height
        return CGRect(x: cocoa.origin.x, y: axY, width: cocoa.width, height: cocoa.height)
    }

    private static func cocoaRect(from ax: CGRect) -> NSRect {
        let cocoaY = primaryDisplayHeight - ax.origin.y - ax.height
        return NSRect(x: ax.origin.x, y: cocoaY, width: ax.width, height: ax.height)
    }

    private static func setFrame(_ window: AXUIElement, _ axFrame: CGRect) {
        var origin = axFrame.origin
        var size = axFrame.size
        if let posValue = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
    }

    private static func targetScreen() -> NSScreen {
        let loc = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(loc) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}
