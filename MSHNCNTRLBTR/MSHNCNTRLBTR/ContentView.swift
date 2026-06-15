//
//  ContentView.swift
//  MSHNCNTRLBTR
//
//  Created by MovieStudio on 6/7/26.
//

import SwiftUI
import AppKit

struct ContentView: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "hand.draw")
                    .imageScale(.large)
                    .foregroundStyle(.tint)
                Text("Motion Control")
                    .font(.title3.bold())
                Spacer()
                Toggle("Enabled", isOn: $settings.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Trackpad Gestures")
                    .font(.headline)

                ForEach(GestureAction.allCases) { action in
                    GestureRow(action: action, settings: settings)
                }
            }

            Divider()

            WindowOverviewSection(settings: settings)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Tip")
                    .font(.caption.bold())
                Text("To avoid conflicts, turn off the matching built-in gestures in System Settings → Trackpad → More Gestures. Grant Accessibility permission so the app can send system events.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}

private struct GestureRow: View {
    let action: GestureAction
    let settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label {
                    Text(action.displayName)
                } icon: {
                    Image(systemName: action.iconName)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Picker("", selection: Binding<GestureKey?>(
                    get: { settings.gesture(for: action) },
                    set: { settings.setGesture($0, for: action) }
                )) {
                    Text("None").tag(GestureKey?.none)
                    ForEach(GestureKey.allCases) { key in
                        Text(key.displayName).tag(GestureKey?.some(key))
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }

            if action == .customLayout {
                HStack {
                    Text("Layout")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: Binding<WindowLayout>(
                        get: { settings.customLayoutStyle },
                        set: { settings.customLayoutStyle = $0 }
                    )) {
                        ForEach(WindowLayout.allCases) { layout in
                            Text(layout.displayName).tag(layout)
                        }
                    }
                    .labelsHidden()
                }
                .padding(.leading, 24)
            }
        }
    }
}

private struct WindowOverviewSection: View {
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Window Overview Appearance")
                .font(.headline)

            HStack {
                Text("Layout")
                    .frame(width: 80, alignment: .leading)
                Picker("", selection: $settings.overviewLayoutStyle) {
                    ForEach(WindowOverviewLayout.allCases) { layout in
                        Text(layout.displayName).tag(layout)
                    }
                }
                .labelsHidden()
            }

            HStack {
                Text("Tile Size")
                    .frame(width: 80, alignment: .leading)
                Picker("", selection: $settings.overviewTileSize) {
                    ForEach(WindowOverviewTileSize.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            HStack(spacing: 16) {
                Toggle("Show Labels", isOn: $settings.overviewShowLabels)
                Toggle("Show Shadows", isOn: $settings.overviewShowShadows)
                Spacer()
            }
        }
    }
}

#Preview {
    ContentView()
}
