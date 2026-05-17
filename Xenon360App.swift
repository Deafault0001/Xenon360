// Xenon360App.swift
// Xenon360 — iOS/iPadOS 26 SwiftUI App Entry Point

import SwiftUI

@main
struct Xenon360App: App {
    @StateObject private var emulator = Emulator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(emulator)
        }
    }
}
