//
//  ActionDispatcher.swift
//  MSHNCNTRLBTR
//
//  Performs system actions in response to recognized gestures.
//

import AppKit
import IOKit
import IOKit.hidsystem

// From <IOKit/hidsystem/ev_keymap.h>
fileprivate let NX_KEYTYPE_SOUND_UP: Int32 = 0
fileprivate let NX_KEYTYPE_SOUND_DOWN: Int32 = 1
fileprivate let NX_KEYTYPE_BRIGHTNESS_UP: Int32 = 2
fileprivate let NX_KEYTYPE_BRIGHTNESS_DOWN: Int32 = 3

enum ActionDispatcher {
    static func perform(_ action: GestureAction) {
        // If the overview is showing and the user fires any other gesture,
        // close the overview first so the requested action takes effect.
        if action != .windowOverview, WindowOverviewController.shared.isPresenting {
            WindowOverviewController.shared.dismiss()
        }

        switch action {
        case .missionControl: triggerMissionControl()
        case .showDesktop: triggerShowDesktop()
        case .windowOverview: WindowOverviewController.shared.toggle()
        case .customLayout: WindowArranger.apply(AppSettings.shared.customLayoutStyle)
        case .volumeUp: postSystemDefinedKey(NX_KEYTYPE_SOUND_UP)
        case .volumeDown: postSystemDefinedKey(NX_KEYTYPE_SOUND_DOWN)
        case .brightnessUp: postSystemDefinedKey(NX_KEYTYPE_BRIGHTNESS_UP)
        case .brightnessDown: postSystemDefinedKey(NX_KEYTYPE_BRIGHTNESS_DOWN)
        }
    }

    // Launching Mission Control.app triggers Mission Control directly,
    // independent of any keyboard shortcut configuration.
    private static func triggerMissionControl() {
        let candidates = [
            "/System/Applications/Mission Control.app",
            "/Applications/Mission Control.app"
        ]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            NSLog("[MSHN] Mission Control.app not found")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: path),
            configuration: config
        ) { _, error in
            if let error {
                NSLog("[MSHN] Mission Control launch failed: \(error)")
            }
        }
    }

    // Show Desktop: post the Dock's distributed notification. If Dock ignores
    // it (older/newer macOS variants), fall back to an F11 keypress with the
    // Fn modifier — same combination Apple keyboards send.
    private static func triggerShowDesktop() {
        DistributedNotificationCenter.default().post(
            name: Notification.Name("com.apple.showdesktop.awake"),
            object: nil
        )
        // Belt-and-suspenders: also send fn+F11. Harmless if unbound (and
        // since the notification fires first, the user sees Show Desktop
        // even on Macs that don't have F11 set up).
        sendKey(virtualKey: 0x67, flags: .maskSecondaryFn)
    }

    private static func sendKey(virtualKey: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }

    private static func postSystemDefinedKey(_ key: Int32) {
        for isDown in [true, false] {
            let flagsValue: UInt = isDown ? 0xa00 : 0xb00
            let stateBits = (isDown ? 0xa : 0xb) << 8
            let data1 = Int((key << 16) | Int32(stateBits))
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: flagsValue),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ) else { continue }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
