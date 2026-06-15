//
//  WindowOverview.swift
//  MSHNCNTRLBTR
//
//  Full-screen overlay that shows a thumbnail of every open window
//  grouped by app. Thumbnails refresh on a loop so they feel "live".
//

import AppKit
import SwiftUI
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

// Private accessibility API for mapping AXUIElement → CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

// MARK: - User-configurable appearance

enum WindowOverviewLayout: String, CaseIterable, Codable, Identifiable {
    case cards
    case plain
    case autoFit

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cards: return "Grouped Cards"
        case .plain: return "Plain Sections"
        case .autoFit: return "Auto-Fit Grid"
        }
    }
}

enum WindowOverviewTileSize: String, CaseIterable, Codable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    var width: CGFloat {
        switch self {
        case .small: return 160
        case .medium: return 200
        case .large: return 260
        }
    }

    var height: CGFloat {
        switch self {
        case .small: return 100
        case .medium: return 130
        case .large: return 170
        }
    }
}

// MARK: - NSWindow / NSHostingView subclasses that take first click

private final class OverviewNSWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Models

struct WindowSnapshot: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let title: String
    let image: NSImage?
}

struct AppSnapshot: Identifiable {
    let id: pid_t
    let appName: String
    let icon: NSImage?
    var windows: [WindowSnapshot]
}

@Observable
final class OverviewState {
    var apps: [AppSnapshot] = []
    var screenRecordingDenied: Bool = false
    var loading: Bool = true
}

// MARK: - Controller

@MainActor
final class WindowOverviewController {
    static let shared = WindowOverviewController()

    private var window: NSWindow?
    private var refreshTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private let state = OverviewState()

    var isPresenting: Bool { window != nil }

    private init() {}

    func toggle() {
        if window != nil {
            dismiss()
        } else {
            present()
        }
    }

    func present() {
        guard window == nil else { return }

        if !CGPreflightScreenCaptureAccess() {
            state.screenRecordingDenied = true
            _ = CGRequestScreenCaptureAccess()
        } else {
            state.screenRecordingDenied = false
        }

        state.apps = []
        state.loading = true

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let win = OverviewNSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        win.level = .floating
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = OverviewView(
            state: state,
            onSelect: { [weak self] target in self?.activate(target) },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        win.contentView = FirstMouseHostingView(rootView: view)

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                self?.dismiss()
                return nil
            }
            return event
        }

        self.window = win
        startRefresh()
    }

    func dismiss() {
        refreshTask?.cancel()
        refreshTask = nil
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        window?.orderOut(nil)
        window = nil
    }

    private func activate(_ target: WindowSnapshot) {
        dismiss()
        NSRunningApplication(processIdentifier: target.pid)?.activate()

        let appEl = AXUIElementCreateApplication(target.pid)
        var winsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &winsRef) == .success,
              let wins = winsRef as? [AXUIElement] else { return }
        for w in wins {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(w, &wid) == .success, wid == target.id {
                AXUIElementPerformAction(w, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
                break
            }
        }
    }

    // MARK: - Refresh loop

    private func startRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                let snapshots = await Self.captureSnapshots()
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self else { return }
                    self.state.apps = snapshots
                    self.state.loading = false
                }
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    // MARK: - Capture via ScreenCaptureKit

    private static func captureSnapshots() async -> [AppSnapshot] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
        } catch {
            NSLog("[MSHN] SCShareableContent failed: \(error)")
            return []
        }

        let ourPid = ProcessInfo.processInfo.processIdentifier
        let eligible = content.windows.filter { window in
            guard let app = window.owningApplication else { return false }
            guard app.processID != ourPid else { return false }
            guard window.windowLayer == 0 else { return false }
            guard window.frame.width >= 100, window.frame.height >= 100 else { return false }
            return true
        }

        var byPid: [pid_t: AppSnapshot] = [:]
        var order: [pid_t] = []

        for window in eligible {
            guard let app = window.owningApplication else { continue }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = max(1, Int(window.frame.width))
            config.height = max(1, Int(window.frame.height))
            config.showsCursor = false

            let cgImage: CGImage?
            do {
                cgImage = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: config
                )
            } catch {
                cgImage = nil
            }

            let nsImage: NSImage? = cgImage.map {
                NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
            }

            let snapshot = WindowSnapshot(
                id: CGWindowID(window.windowID),
                pid: app.processID,
                title: window.title ?? "",
                image: nsImage
            )

            if var existing = byPid[app.processID] {
                existing.windows.append(snapshot)
                byPid[app.processID] = existing
            } else {
                let icon = NSRunningApplication(processIdentifier: app.processID)?.icon
                byPid[app.processID] = AppSnapshot(
                    id: app.processID,
                    appName: app.applicationName,
                    icon: icon,
                    windows: [snapshot]
                )
                order.append(app.processID)
            }
        }

        return order.compactMap { byPid[$0] }
    }
}

// MARK: - SwiftUI

private struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

private struct OverviewView: View {
    @Bindable var state: OverviewState
    let onSelect: (WindowSnapshot) -> Void
    let onDismiss: () -> Void

    @State private var settings = AppSettings.shared
    @State private var appeared = false

    var body: some View {
        ZStack {
            // Real wallpaper blur via NSVisualEffectView
            VisualEffectBackground(material: .fullScreenUI, blendingMode: .behindWindow)
                .ignoresSafeArea()

            Group {
                if settings.overviewLayoutStyle == .autoFit {
                    AutoFitGrid(
                        state: state,
                        showLabels: settings.overviewShowLabels,
                        showShadows: settings.overviewShowShadows,
                        onSelect: onSelect
                    )
                } else {
                    sectionedLayout
                }
            }
            .scaleEffect(appeared ? 1.0 : 0.96)
            .opacity(appeared ? 1.0 : 0.0)
        }
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
        .onAppear {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                appeared = true
            }
        }
    }

    private var sectionedLayout: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if state.screenRecordingDenied {
                    permissionBanner
                }
                ForEach(state.apps) { app in
                    AppCluster(
                        app: app,
                        layout: settings.overviewLayoutStyle,
                        tileSize: settings.overviewTileSize,
                        showLabels: settings.overviewShowLabels,
                        showShadows: settings.overviewShowShadows,
                        onSelect: onSelect
                    )
                }
                if state.apps.isEmpty && !state.screenRecordingDenied {
                    Text(state.loading ? "Loading windows…" : "No open windows")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 80)
                }
            }
            .padding(40)
        }
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Screen Recording permission required")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Grant access in System Settings → Privacy & Security → Screen Recording to see live window previews.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.yellow.opacity(0.5), lineWidth: 1)
        )
    }
}

private struct AppCluster: View {
    let app: AppSnapshot
    let layout: WindowOverviewLayout
    let tileSize: WindowOverviewTileSize
    let showLabels: Bool
    let showShadows: Bool
    let onSelect: (WindowSnapshot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 22, height: 22)
                }
                Text(app.appName)
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(app.windows) { window in
                        WindowTile(
                            window: window,
                            tileSize: tileSize,
                            showLabel: showLabels,
                            showShadow: showShadows
                        ) { onSelect(window) }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(layout == .cards ? 14 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Group {
                if layout == .cards {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.white.opacity(0.08))
                }
            }
        )
        .overlay(
            Group {
                if layout == .cards {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(.white.opacity(0.14), lineWidth: 1)
                }
            }
        )
    }
}

private struct WindowTile: View {
    let window: WindowSnapshot
    let tileSize: WindowOverviewTileSize
    let showLabel: Bool
    let showShadow: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 5) {
                Group {
                    if let image = window.image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Rectangle().fill(.gray.opacity(0.4))
                    }
                }
                .frame(width: tileSize.width, height: tileSize.height)
                .background(.black.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(
                            isHovering ? Color.accentColor : Color.white.opacity(0.16),
                            lineWidth: isHovering ? 2 : 1
                        )
                )
                .shadow(
                    color: .black.opacity(showShadow ? (isHovering ? 0.55 : 0.38) : 0),
                    radius: showShadow ? (isHovering ? 14 : 7) : 0,
                    x: 0,
                    y: showShadow ? (isHovering ? 7 : 3) : 0
                )

                if showLabel {
                    Text(window.title.isEmpty ? "Untitled" : window.title)
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(width: tileSize.width, alignment: .leading)
                }
            }
            .scaleEffect(isHovering ? 1.06 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Auto-fit grid

private struct FlatWindow: Identifiable {
    let id: CGWindowID
    let window: WindowSnapshot
    let app: AppSnapshot
}

private struct AutoFitGrid: View {
    let state: OverviewState
    let showLabels: Bool
    let showShadows: Bool
    let onSelect: (WindowSnapshot) -> Void

    private let aspect: CGFloat = 200.0 / 130.0
    private let spacing: CGFloat = 14
    private let minTileWidth: CGFloat = 140
    private let labelHeight: CGFloat = 18

    private var flattened: [FlatWindow] {
        state.apps.flatMap { app in
            app.windows.map { FlatWindow(id: $0.id, window: $0, app: app) }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let available = CGSize(
                width: max(geo.size.width - 80, 100),
                height: max(geo.size.height - 80, 100)
            )
            let count = flattened.count
            let tile = computeTileSize(count: count, in: available)
            let cols = max(1, Int((available.width + spacing) / (tile.width + spacing)))
            let columns = Array(
                repeating: GridItem(.fixed(tile.width), spacing: spacing, alignment: .top),
                count: cols
            )

            ScrollView {
                if state.screenRecordingDenied {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Screen Recording permission required")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("Grant access in System Settings → Privacy & Security → Screen Recording to see live window previews.")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(.yellow.opacity(0.5), lineWidth: 1)
                    )
                    .padding(40)
                }

                if flattened.isEmpty && !state.screenRecordingDenied {
                    Text(state.loading ? "Loading windows…" : "No open windows")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 80)
                } else {
                    LazyVGrid(columns: columns, alignment: .center, spacing: spacing) {
                        ForEach(flattened) { item in
                            AutoFitTile(
                                window: item.window,
                                app: item.app,
                                tileWidth: tile.width,
                                tileHeight: tile.height,
                                showLabel: showLabels,
                                showShadow: showShadows
                            ) { onSelect(item.window) }
                        }
                    }
                    .padding(40)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// Find the largest tile size such that all windows fit on screen without scrolling,
    /// with `minTileWidth` as a floor (we'll scroll if even the floor doesn't fit).
    private func computeTileSize(count: Int, in available: CGSize) -> CGSize {
        guard count > 0 else { return CGSize(width: 240, height: 240 / aspect) }
        let extraPerTile = showLabels ? labelHeight + 5 : 0
        var best = CGSize(width: minTileWidth, height: minTileWidth / aspect + extraPerTile)
        for cols in 1...count {
            let rows = Int(ceil(Double(count) / Double(cols)))
            let tileWidth = (available.width - CGFloat(cols - 1) * spacing) / CGFloat(cols)
            guard tileWidth >= minTileWidth else { continue }
            let tileHeight = tileWidth / aspect + extraPerTile
            let totalHeight = CGFloat(rows) * tileHeight + CGFloat(rows - 1) * spacing
            if totalHeight <= available.height && tileWidth > best.width {
                best = CGSize(width: tileWidth, height: tileHeight)
            }
        }
        // Cap upper bound so a single window doesn't fill the entire screen.
        let maxWidth: CGFloat = 480
        if best.width > maxWidth {
            best = CGSize(width: maxWidth, height: maxWidth / aspect + extraPerTile)
        }
        return best
    }
}

private struct AutoFitTile: View {
    let window: WindowSnapshot
    let app: AppSnapshot
    let tileWidth: CGFloat
    let tileHeight: CGFloat
    let showLabel: Bool
    let showShadow: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    private var thumbHeight: CGFloat {
        showLabel ? tileHeight - 23 : tileHeight
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 5) {
                ZStack(alignment: .topLeading) {
                    Group {
                        if let image = window.image {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } else {
                            Rectangle().fill(.gray.opacity(0.4))
                        }
                    }
                    .frame(width: tileWidth, height: thumbHeight)
                    .background(.black.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 9))

                    if let icon = app.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 26, height: 26)
                            .padding(6)
                            .shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 1)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(
                            isHovering ? Color.accentColor : Color.white.opacity(0.16),
                            lineWidth: isHovering ? 2 : 1
                        )
                )
                .shadow(
                    color: .black.opacity(showShadow ? (isHovering ? 0.55 : 0.38) : 0),
                    radius: showShadow ? (isHovering ? 14 : 7) : 0,
                    x: 0,
                    y: showShadow ? (isHovering ? 7 : 3) : 0
                )

                if showLabel {
                    Text(window.title.isEmpty ? "Untitled" : window.title)
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(width: tileWidth, alignment: .leading)
                }
            }
            .scaleEffect(isHovering ? 1.04 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
