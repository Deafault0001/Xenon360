// SettingsView.swift
// Xenon360 — Settings

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var emulator: Emulator
    @AppStorage("cpuSpeed")        var cpuSpeed:        Double = 1.0
    @AppStorage("burstSize")       var burstSize:        Int    = 10000
    @AppStorage("showFPS")         var showFPS:          Bool   = true
    @AppStorage("skipBIOS")        var skipBIOS:         Bool   = true
    @AppStorage("renderScale")     var renderScale:      Double = 1.0
    @AppStorage("hleKernel")       var hleKernel:        Bool   = true
    @AppStorage("logLevel")        var logLevel:         String = "info"
    @AppStorage("controllerLayout") var controllerLayout: String = "default"

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.07, green: 0.07, blue: 0.09).ignoresSafeArea()

                List {
                    // ── CPU ───────────────────────────────────────
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("CPU Speed Multiplier")
                                Spacer()
                                Text(String(format: "%.1f×", cpuSpeed))
                                    .foregroundStyle(.green)
                                    .fontDesign(.monospaced)
                            }
                            Slider(value: $cpuSpeed, in: 0.1...4.0, step: 0.1)
                                .tint(.green)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Burst Size")
                                Spacer()
                                Text("\(burstSize) instrs")
                                    .foregroundStyle(.green)
                                    .fontDesign(.monospaced)
                            }
                            Slider(value: Binding(
                                get: { Double(burstSize) },
                                set: { burstSize = Int($0) }
                            ), in: 1000...100000, step: 1000)
                                .tint(.green)
                            Text("Higher = faster but less responsive UI")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Toggle("HLE Kernel", isOn: $hleKernel)
                            .tint(.green)

                        Toggle("Skip BIOS / Boot Animation", isOn: $skipBIOS)
                            .tint(.green)

                    } header: {
                        Label("CPU / Interpreter", systemImage: "cpu.fill")
                    }
                    .listRowBackground(Color(white: 0.12))

                    // ── GPU ───────────────────────────────────────
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Render Scale")
                                Spacer()
                                Text(String(format: "%.1f×", renderScale))
                                    .foregroundStyle(.green)
                                    .fontDesign(.monospaced)
                            }
                            Slider(value: $renderScale, in: 0.5...2.0, step: 0.25)
                                .tint(.green)
                            Text("1.0× = native 720p, 2.0× = 1440p upscale")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Toggle("Show FPS Counter", isOn: $showFPS)
                            .tint(.green)

                    } header: {
                        Label("GPU / Display", systemImage: "display")
                    }
                    .listRowBackground(Color(white: 0.12))

                    // ── Input ─────────────────────────────────────
                    Section {
                        Picker("Controller Layout", selection: $controllerLayout) {
                            Text("Default").tag("default")
                            Text("Left-Handed").tag("lefty")
                            Text("Compact").tag("compact")
                        }
                        .pickerStyle(.menu)

                        NavigationLink("Touch Overlay Editor") {
                            Text("Coming soon")
                                .foregroundStyle(.secondary)
                        }

                        NavigationLink("MFi / Bluetooth Controller") {
                            Text("Connect a controller in iOS Settings → Bluetooth")
                                .foregroundStyle(.secondary)
                                .padding()
                        }

                    } header: {
                        Label("Input", systemImage: "gamecontroller.fill")
                    }
                    .listRowBackground(Color(white: 0.12))

                    // ── Logging ───────────────────────────────────
                    Section {
                        Picker("Log Level", selection: $logLevel) {
                            Text("Debug").tag("debug")
                            Text("Info").tag("info")
                            Text("Warnings Only").tag("warning")
                            Text("Errors Only").tag("error")
                        }
                        .pickerStyle(.menu)

                        Button(role: .destructive) {
                            emulator.log.removeAll()
                        } label: {
                            Label("Clear Log", systemImage: "trash")
                        }

                    } header: {
                        Label("Logging", systemImage: "terminal")
                    }
                    .listRowBackground(Color(white: 0.12))

                    // ── About ─────────────────────────────────────
                    Section {
                        LabeledContent("Version", value: "0.1.0-alpha")
                        LabeledContent("CPU Core", value: "JIT-less Interpreter")
                        LabeledContent("Architecture", value: "PowerPC Xenon")
                        LabeledContent("RAM Emulated", value: "512 MB GDDR3")
                        LabeledContent("Threads", value: "3 cores × 2 = 6 HW threads")

                        Link(destination: URL(string: "https://github.com")!) {
                            Label("Source Code (GitHub)", systemImage: "chevron.left.forwardslash.chevron.right")
                        }
                        .foregroundStyle(.green)

                    } header: {
                        Label("About Xenon360", systemImage: "info.circle.fill")
                    }
                    .listRowBackground(Color(white: 0.12))
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .preferredColorScheme(.dark)
        }
    }
}
