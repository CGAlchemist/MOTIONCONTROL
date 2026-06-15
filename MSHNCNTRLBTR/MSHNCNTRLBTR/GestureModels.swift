//
//  GestureModels.swift
//  MSHNCNTRLBTR
//

import Foundation

enum SwipeDirection {
    case up, down, left, right

    var displayName: String {
        switch self {
        case .up: return "Swipe Up"
        case .down: return "Swipe Down"
        case .left: return "Swipe Left"
        case .right: return "Swipe Right"
        }
    }

    var axis: GestureAxis {
        switch self {
        case .up, .down: return .vertical
        case .left, .right: return .horizontal
        }
    }
}

enum GestureAxis {
    case horizontal, vertical
}

enum GestureKey: String, CaseIterable, Codable, Identifiable {
    case threeFingerUp
    case threeFingerDown
    case threeFingerLeft
    case threeFingerRight
    case fourFingerUp
    case fourFingerDown
    case fourFingerLeft
    case fourFingerRight

    var id: String { rawValue }

    var fingerCount: Int {
        switch self {
        case .threeFingerUp, .threeFingerDown, .threeFingerLeft, .threeFingerRight:
            return 3
        case .fourFingerUp, .fourFingerDown, .fourFingerLeft, .fourFingerRight:
            return 4
        }
    }

    var direction: SwipeDirection {
        switch self {
        case .threeFingerUp, .fourFingerUp: return .up
        case .threeFingerDown, .fourFingerDown: return .down
        case .threeFingerLeft, .fourFingerLeft: return .left
        case .threeFingerRight, .fourFingerRight: return .right
        }
    }

    var displayName: String {
        "\(fingerCount)-finger \(direction.displayName)"
    }

    static func key(fingers: Int, direction: SwipeDirection) -> GestureKey? {
        switch (fingers, direction) {
        case (3, .up): return .threeFingerUp
        case (3, .down): return .threeFingerDown
        case (3, .left): return .threeFingerLeft
        case (3, .right): return .threeFingerRight
        case (4, .up): return .fourFingerUp
        case (4, .down): return .fourFingerDown
        case (4, .left): return .fourFingerLeft
        case (4, .right): return .fourFingerRight
        default: return nil
        }
    }
}

enum GestureAction: String, CaseIterable, Codable, Identifiable {
    case missionControl
    case showDesktop
    case windowOverview
    case customLayout
    case volumeUp
    case volumeDown
    case brightnessUp
    case brightnessDown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .missionControl: return "Mission Control"
        case .showDesktop: return "Show Desktop"
        case .windowOverview: return "Window Overview"
        case .customLayout: return "Custom Layout"
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .brightnessUp: return "Brightness Up"
        case .brightnessDown: return "Brightness Down"
        }
    }

    var iconName: String {
        switch self {
        case .missionControl: return "rectangle.3.group"
        case .showDesktop: return "macwindow.on.rectangle"
        case .windowOverview: return "square.grid.2x2"
        case .customLayout: return "rectangle.split.2x2"
        case .volumeUp: return "speaker.wave.3.fill"
        case .volumeDown: return "speaker.wave.1.fill"
        case .brightnessUp: return "sun.max.fill"
        case .brightnessDown: return "sun.min.fill"
        }
    }

    // Continuous actions scrub incrementally as the user keeps moving;
    // discrete actions fire once per gesture.
    var isContinuous: Bool {
        switch self {
        case .volumeUp, .volumeDown, .brightnessUp, .brightnessDown:
            return true
        case .missionControl, .showDesktop, .windowOverview, .customLayout:
            return false
        }
    }
}
