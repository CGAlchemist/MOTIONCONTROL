//
//  MSHNCNTRLBTRApp.swift
//  MSHNCNTRLBTR
//
//  Created by MovieStudio on 6/7/26.
//

import SwiftUI
import AppKit

@main
struct MSHNCNTRLBTRApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        GestureCoordinator.shared.start()
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
        } label: {
            Image(systemName: "hand.draw")
        }
        .menuBarExtraStyle(.window)
    }
}
