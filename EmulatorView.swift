// EmulatorView.swift
// Xenon360 — Emulator Screen + Controls

import SwiftUI
import MetalKit

struct EmulatorView: View {
    @EnvironmentObject var emulator: Emulator
    @State private var showLog = false
    @State private var controlsVisible = true
    @State private var controlHideTimer: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                // ── Game Display ───────────────────────────────────
                Group {
                    if emulator.state == .running || emulator.state == .paused {
                        GameDisplayView()
                    } else {
                        idleScreen
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // ── Overlay Controls ───────────────────────────────
                if controlsVisible {
                    VStack {
                        topBar
                        Spacer()
                        if emulator.state != .idle {
                            statsOverlay
                                .padding(.bottom, 100)
                        }
                        controlBar
                    }
                    .transition(.opacity)
                }
            }
            .onTapGesture { toggleControls() }
            .sheet(isPresented: $showLog) { LogView() }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - Idle Screen

    var idleScreen: some View {
        VStack(spacing: 20) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 64))
                .foregroundStyle(.white.opacity(0.1))

            if let title = emulator.loadedTitle {
                VStack(spacing: 6) {
                    Text(title.title)
                        .font(.title.bold())
                        .foregroundStyle(.white)
                    Text(String(format: "Entry: 0x%016X", title.entryPoint))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                        .fontDesign(.monospaced)
                }

                Button(action: { emulator.run() }) {
                    Label("Boot", systemImage: "play.fill")
                        .font(.title3.bold())
                        .padding(.horizontal, 36)
                        .padding(.vertical, 16)
                        .background(Color.green)
                        .foregroundStyle(.black)
                        .clipShape(Capsule())
                }
            } else {
                Text("No game loaded")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.3))
                Text("Import a XEX file from the Library tab")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.2))
            }
        }
    }

    // MARK: - Top Bar

    var topBar: some View {
        HStack {
            // Status badge
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusColor.opacity(0.8), radius: 4)
                Text(emulator.state.rawValue.uppercased())
                    .font(.caption2.bold())
                    .foregroundStyle(.white.opacity(0.7))
                    .fontDesign(.monospaced)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())

            Spacer()

            // Title
            if let title = emulator.loadedTitle {
                Text(title.title)
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer()

            // Log button
            Button(action: { showLog = true }) {
                Image(systemName: "terminal.fill")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(10)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Stats Overlay

    var statsOverlay: some View {
        HStack(spacing: 20) {
            StatBadge(label: "IPS",
                      value: formatIPS(emulator.stats.ips))
            StatBadge(label: "FPS",
                      value: String(format: "%.0f", emulator.stats.fps))
            StatBadge(label: "INSTRS",
                      value: formatCount(emulator.stats.totalInstructions))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }

    // MARK: - Control Bar

    var controlBar: some View {
        HStack(spacing: 0) {
            // Run / Pause
            ControlButton(
                icon: emulator.state == .running ? "pause.fill" : "play.fill",
                label: emulator.state == .running ? "Pause" : "Run",
                color: .green
            ) {
                if emulator.state == .running {
                    emulator.pause()
                } else {
                    emulator.run()
                }
            }

            Divider().frame(height: 40).opacity(0.3)

            // Stop
            ControlButton(icon: "stop.fill", label: "Stop", color: .red) {
                emulator.stop()
            }

            Divider().frame(height: 40).opacity(0.3)

            // Reset
            ControlButton(icon: "arrow.counterclockwise", label: "Reset", color: .orange) {
                emulator.reset()
            }

            Divider().frame(height: 40).opacity(0.3)

            // Screenshot
            ControlButton(icon: "camera.fill", label: "Screenshot", color: .blue) {
                // TODO: Metal framebuffer capture
            }
        }
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 0))
    }

    // MARK: - Helpers

    var statusColor: Color {
        switch emulator.state {
        case .running: return .green
        case .paused:  return .yellow
        case .error:   return .red
        case .loading: return .blue
        default:       return .gray
        }
    }

    func toggleControls() {
        controlHideTimer?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            controlsVisible = true
        }
        if emulator.state == .running {
            controlHideTimer = Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        controlsVisible = false
                    }
                }
            }
        }
    }

    func formatIPS(_ ips: Double) -> String {
        if ips > 1_000_000_000 { return String(format: "%.1fG", ips / 1e9) }
        if ips > 1_000_000     { return String(format: "%.1fM", ips / 1e6) }
        if ips > 1_000         { return String(format: "%.1fK", ips / 1e3) }
        return String(format: "%.0f", ips)
    }

    func formatCount(_ n: UInt64) -> String {
        if n > 1_000_000_000 { return String(format: "%.1fG", Double(n) / 1e9) }
        if n > 1_000_000     { return String(format: "%.1fM", Double(n) / 1e6) }
        if n > 1_000         { return String(format: "%.1fK", Double(n) / 1e3) }
        return "\(n)"
    }
}

// MARK: - Game Display (Metal stub)

struct GameDisplayView: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1)
        view.enableSetNeedsDisplay = true
        view.isPaused = false
        view.preferredFramesPerSecond = 60
        // TODO: attach Xenon GPU renderer (Xenos/D3D9 → Metal translator)
        return view
    }
    func updateUIView(_ uiView: MTKView, context: Context) {}
}

// MARK: - Supporting Views

struct StatBadge: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

struct ControlButton: View {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
    }
}

struct LogView: View {
    @EnvironmentObject var emulator: Emulator
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(emulator.log) { entry in
                            LogLine(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: emulator.log.count) { _, _ in
                    if let last = emulator.log.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            .background(Color(red: 0.05, green: 0.05, blue: 0.07))
            .navigationTitle("Emulator Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationBackground(Color(red: 0.05, green: 0.05, blue: 0.07))
    }
}

struct LogLine: View {
    let entry: Emulator.LogEntry

    var color: Color {
        switch entry.level {
        case .error:   return .red
        case .warning: return .yellow
        case .debug:   return .cyan.opacity(0.7)
        case .info:    return .white.opacity(0.8)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(timeString)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
                .frame(width: 52, alignment: .leading)

            Text(entry.level.rawValue.uppercased())
                .font(.system(size: 9, design: .monospaced).bold())
                .foregroundStyle(color)
                .frame(width: 36)

            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: entry.timestamp)
    }
}
