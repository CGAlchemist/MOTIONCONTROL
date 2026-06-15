//
//  GestureCoordinator.swift
//  MSHNCNTRLBTR
//

import Foundation
import Observation
import ApplicationServices

@MainActor
final class GestureCoordinator {
    static let shared = GestureCoordinator()

    private init() {}

    func start() {
        checkAccessibility(prompt: true)

        MultitouchManager.shared.onAction = { action in
            ActionDispatcher.perform(action)
        }
        pushBindings()
        observeSettings()
        MultitouchManager.shared.start()
    }

    private func checkAccessibility(prompt: Bool) {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        NSLog("[MSHN] Accessibility trusted = \(trusted)")
    }

    private func pushBindings() {
        let settings = AppSettings.shared
        var bindings: [GestureKey: GestureAction] = [:]
        for action in GestureAction.allCases {
            if let key = settings.gesture(for: action) {
                bindings[key] = action
            }
        }
        MultitouchManager.shared.setBindings(bindings, enabled: settings.enabled)
    }

    private func observeSettings() {
        let settings = AppSettings.shared
        withObservationTracking {
            _ = settings.enabled
            for action in GestureAction.allCases {
                _ = settings.gesture(for: action)
            }
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.pushBindings()
                self?.observeSettings()
            }
        }
    }
}
