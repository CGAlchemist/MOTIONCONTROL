//
//  AppSettings.swift
//  MSHNCNTRLBTR
//

import Foundation
import Observation

@Observable
final class AppSettings {
    static let shared = AppSettings()

    var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled) }
    }

    var missionControl: GestureKey? {
        didSet { saveGesture(missionControl, for: .missionControl) }
    }
    var showDesktop: GestureKey? {
        didSet { saveGesture(showDesktop, for: .showDesktop) }
    }
    var windowOverview: GestureKey? {
        didSet { saveGesture(windowOverview, for: .windowOverview) }
    }
    var customLayout: GestureKey? {
        didSet { saveGesture(customLayout, for: .customLayout) }
    }
    var volumeUp: GestureKey? {
        didSet { saveGesture(volumeUp, for: .volumeUp) }
    }
    var volumeDown: GestureKey? {
        didSet { saveGesture(volumeDown, for: .volumeDown) }
    }
    var brightnessUp: GestureKey? {
        didSet { saveGesture(brightnessUp, for: .brightnessUp) }
    }
    var brightnessDown: GestureKey? {
        didSet { saveGesture(brightnessDown, for: .brightnessDown) }
    }

    var customLayoutStyle: WindowLayout {
        didSet { defaults.set(customLayoutStyle.rawValue, forKey: Keys.customLayoutStyle) }
    }

    var overviewLayoutStyle: WindowOverviewLayout {
        didSet { defaults.set(overviewLayoutStyle.rawValue, forKey: Keys.overviewLayoutStyle) }
    }
    var overviewTileSize: WindowOverviewTileSize {
        didSet { defaults.set(overviewTileSize.rawValue, forKey: Keys.overviewTileSize) }
    }
    var overviewShowLabels: Bool {
        didSet { defaults.set(overviewShowLabels, forKey: Keys.overviewShowLabels) }
    }
    var overviewShowShadows: Bool {
        didSet { defaults.set(overviewShowShadows, forKey: Keys.overviewShowShadows) }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Keys {
        static let enabled = "mshn.enabled"
        static let customLayoutStyle = "mshn.customLayoutStyle"
        static let overviewLayoutStyle = "mshn.overviewLayoutStyle"
        static let overviewTileSize = "mshn.overviewTileSize"
        static let overviewShowLabels = "mshn.overviewShowLabels"
        static let overviewShowShadows = "mshn.overviewShowShadows"
        static func gesture(_ action: GestureAction) -> String {
            "mshn.gesture.\(action.rawValue)"
        }
    }

    private init() {
        let d = UserDefaults.standard
        enabled = (d.object(forKey: Keys.enabled) as? Bool) ?? true
        missionControl = Self.loadGesture(for: .missionControl) ?? .threeFingerUp
        showDesktop = Self.loadGesture(for: .showDesktop)
        windowOverview = Self.loadGesture(for: .windowOverview)
        customLayout = Self.loadGesture(for: .customLayout)
        volumeUp = Self.loadGesture(for: .volumeUp) ?? .fourFingerUp
        volumeDown = Self.loadGesture(for: .volumeDown) ?? .fourFingerDown
        brightnessUp = Self.loadGesture(for: .brightnessUp)
        brightnessDown = Self.loadGesture(for: .brightnessDown)
        if let raw = d.string(forKey: Keys.customLayoutStyle),
           let layout = WindowLayout(rawValue: raw) {
            customLayoutStyle = layout
        } else {
            customLayoutStyle = .grid2x2
        }
        if let raw = d.string(forKey: Keys.overviewLayoutStyle),
           let layout = WindowOverviewLayout(rawValue: raw) {
            overviewLayoutStyle = layout
        } else {
            overviewLayoutStyle = .cards
        }
        if let raw = d.string(forKey: Keys.overviewTileSize),
           let size = WindowOverviewTileSize(rawValue: raw) {
            overviewTileSize = size
        } else {
            overviewTileSize = .medium
        }
        overviewShowLabels = (d.object(forKey: Keys.overviewShowLabels) as? Bool) ?? true
        overviewShowShadows = (d.object(forKey: Keys.overviewShowShadows) as? Bool) ?? true
    }

    private static func loadGesture(for action: GestureAction) -> GestureKey? {
        guard let raw = UserDefaults.standard.string(forKey: Keys.gesture(action)) else {
            return nil
        }
        return GestureKey(rawValue: raw)
    }

    private func saveGesture(_ key: GestureKey?, for action: GestureAction) {
        if let key {
            defaults.set(key.rawValue, forKey: Keys.gesture(action))
        } else {
            defaults.removeObject(forKey: Keys.gesture(action))
        }
    }

    func gesture(for action: GestureAction) -> GestureKey? {
        switch action {
        case .missionControl: return missionControl
        case .showDesktop: return showDesktop
        case .windowOverview: return windowOverview
        case .customLayout: return customLayout
        case .volumeUp: return volumeUp
        case .volumeDown: return volumeDown
        case .brightnessUp: return brightnessUp
        case .brightnessDown: return brightnessDown
        }
    }

    func setGesture(_ key: GestureKey?, for action: GestureAction) {
        if let key {
            for other in GestureAction.allCases where other != action {
                if gesture(for: other) == key {
                    assign(nil, to: other)
                }
            }
        }
        assign(key, to: action)
    }

    private func assign(_ key: GestureKey?, to action: GestureAction) {
        switch action {
        case .missionControl: missionControl = key
        case .showDesktop: showDesktop = key
        case .windowOverview: windowOverview = key
        case .customLayout: customLayout = key
        case .volumeUp: volumeUp = key
        case .volumeDown: volumeDown = key
        case .brightnessUp: brightnessUp = key
        case .brightnessDown: brightnessDown = key
        }
    }

    func action(for key: GestureKey) -> GestureAction? {
        GestureAction.allCases.first { gesture(for: $0) == key }
    }
}
