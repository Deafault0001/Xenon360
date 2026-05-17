// ContentView.swift
// Xenon360 — Root Navigation View

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var emulator: Emulator
    @State private var selectedTab: Tab = .library

    enum Tab: String, CaseIterable {
        case library   = "Library"
        case emulator  = "Emulator"
        case debugger  = "Debugger"
        case settings  = "Settings"

        var icon: String {
            switch self {
            case .library:  return "square.grid.2x2.fill"
            case .emulator: return "gamecontroller.fill"
            case .debugger: return "cpu.fill"
            case .settings: return "gearshape.fill"
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            LibraryView()
                .tabItem { Label(Tab.library.rawValue,
                                 systemImage: Tab.library.icon) }
                .tag(Tab.library)

            EmulatorView()
                .tabItem { Label(Tab.emulator.rawValue,
                                 systemImage: Tab.emulator.icon) }
                .tag(Tab.emulator)

            DebuggerView()
                .tabItem { Label(Tab.debugger.rawValue,
                                 systemImage: Tab.debugger.icon) }
                .tag(Tab.debugger)

            SettingsView()
                .tabItem { Label(Tab.settings.rawValue,
                                 systemImage: Tab.settings.icon) }
                .tag(Tab.settings)
        }
        .tint(Color("AccentGreen"))
        .preferredColorScheme(.dark)
    }
}
