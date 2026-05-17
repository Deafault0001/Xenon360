// Emulator.swift
// Xenon360 — Top-Level Emulator Coordinator
//
// Manages the full Xbox 360 emulation session:
//   • Boots and coordinates all 6 hardware threads (3 cores × 2)
//   • Dispatches instruction execution bursts
//   • Provides a clean API for the SwiftUI layer

import Foundation
import Combine

// MARK: - Emulator State

public enum EmulatorState: String, Equatable {
    case idle       = "Idle"
    case loading    = "Loading"
    case running    = "Running"
    case paused     = "Paused"
    case stopped    = "Stopped"
    case error      = "Error"
}

// MARK: - Performance Stats

public struct EmulatorStats {
    public var ips: Double = 0           // instructions per second
    public var fps: Double = 0           // frames per second
    public var cpuUsage: Double = 0      // %
    public var memUsedMB: Double = 0
    public var totalInstructions: UInt64 = 0
    public var uptime: TimeInterval = 0
    public var threadStats: [ThreadStat] = []

    public struct ThreadStat {
        public let core: Int
        public let thread: Int
        public var pc: UInt64
        public var instructionsRun: UInt64
    }
}

// MARK: - Emulator

@MainActor
public class Emulator: ObservableObject {

    // ── State ──────────────────────────────────────────────────────
    @Published public private(set) var state:       EmulatorState = .idle
    @Published public private(set) var stats:       EmulatorStats = EmulatorStats()
    @Published public private(set) var loadedTitle: LoadedXEX?
    @Published public private(set) var log:         [LogEntry] = []
    @Published public private(set) var lastError:   String?

    // ── Subsystems ─────────────────────────────────────────────────
    public let memory = XenonMemory()
    public private(set) var cpu: XenonCPU!
    public private(set) var loader: XEXLoader!

    // ── Execution ──────────────────────────────────────────────────
    private var executionTask: Task<Void, Never>?
    private var startTime: Date?
    private var frameCount: UInt64 = 0
    private let burstSize = 10_000     // instructions per burst

    // ── Kernel HLE (High-Level Emulation) ─────────────────────────
    private var hle: KernelHLE!

    public struct LogEntry: Identifiable {
        public let id = UUID()
        public let timestamp: Date
        public let level: Level
        public let message: String

        public enum Level: String { case info, warning, error, debug }
    }

    public init() {
        cpu    = XenonCPU(memory: memory)
        loader = XEXLoader(memory: memory)
        hle    = KernelHLE(memory: memory, emulator: self)

        cpu.syscallHandler = { [weak self] thread, index in
            Task { @MainActor [weak self] in
                self?.hle.handleSyscall(thread: thread, index: index)
            }
        }

        logInfo("Xenon360 initialized — JIT-less interpreter mode")
        logInfo("CPU: IBM Xenon (3 cores × 2 threads @ 3.2 GHz equivalent)")
        logInfo("RAM: 512 MB GDDR3")
    }

    // MARK: - Loading

    public func loadXEX(url: URL) async {
        state = .loading
        logInfo("Loading: \(url.lastPathComponent)")

        do {
            let xex = try loader.load(url: url)
            loadedTitle = xex

            // Set up initial CPU state
            let mainThread = cpu.threads[0][0]
            mainThread.pc  = xex.entryPoint
            mainThread.sp  = 0x7FFF_0000 - 0x10   // stack top
            mainThread.gpr[2] = 0                  // TOC pointer (set later)

            // Log sections
            for s in xex.sections {
                logInfo(String(format: "  Section: %@ @ 0x%08X (size: 0x%X)%@",
                               s.name, s.virtualAddress, s.virtualSize,
                               s.isExecutable ? " [X]" : ""))
            }
            logInfo(String(format: "  Entry:   0x%016X", xex.entryPoint))
            logInfo(String(format: "  TitleID: 0x%08X", xex.titleID))
            logInfo("  Imports: \(xex.imports.count) symbols")

            state = .paused
            logInfo("Ready — press Run to start execution")
        } catch {
            lastError = error.localizedDescription
            state = .error
            logError("Failed to load XEX: \(error.localizedDescription)")
        }
    }

    // MARK: - Execution Control

    public func run() {
        guard state == .paused || state == .stopped else { return }
        state = .running
        startTime = startTime ?? Date()
        logInfo("Execution started")

        executionTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            // Run 3 cores concurrently (simplified: interleave in single task for iOS)
            while await self.stateIsRunning() {
                do {
                    try await self.runCoreSlice(core: 0, thread: 0)
                    try await self.runCoreSlice(core: 1, thread: 0)
                    try await self.runCoreSlice(core: 2, thread: 0)
                    await self.updateStats()
                } catch XenonException.haltRequested {
                    await MainActor.run { self.state = .stopped }
                    break
                } catch XenonException.systemCall(let idx) {
                    await MainActor.run {
                        self.logDebug(String(format: "Syscall: 0x%X", idx))
                    }
                } catch XenonException.illegalInstruction(let pc, let raw) {
                    await MainActor.run {
                        let msg = String(format: "Illegal instruction @ 0x%016X: 0x%08X", pc, raw)
                        self.logError(msg)
                        self.lastError = msg
                        self.state = .error
                    }
                    break
                } catch XenonException.unimplementedOpcode(let op, let xo) {
                    await MainActor.run {
                        self.logWarning(String(format: "Unimplemented opcode %d xo=%d @ PC=0x%016X",
                                               op, xo, self.cpu.threads[0][0].pc))
                    }
                    // Continue — skip and move on
                } catch {
                    await MainActor.run {
                        self.lastError = error.localizedDescription
                        self.state = .error
                        self.logError("Fatal: \(error)")
                    }
                    break
                }
                await Task.yield()   // yield to UI thread every burst
            }
        }
    }

    public func pause() {
        guard state == .running else { return }
        state = .paused
        logInfo("Paused at PC=\(String(format: "0x%016X", cpu.threads[0][0].pc))")
    }

    public func stop() {
        executionTask?.cancel()
        executionTask = nil
        state = .stopped
        logInfo("Stopped")
    }

    public func reset() {
        stop()
        cpu.threads.forEach { core in core.forEach { t in
            t.gpr = Array(repeating: 0, count: 32)
            t.fpr = Array(repeating: 0.0, count: 32)
            t.pc  = 0
            t.lr  = 0
            t.ctr = 0
            t.instructionsExecuted = 0
        }}
        frameCount = 0
        startTime  = nil
        stats      = EmulatorStats()
        if let xex = loadedTitle {
            cpu.threads[0][0].pc = xex.entryPoint
            cpu.threads[0][0].sp = 0x7FFF_0000 - 0x10
        }
        state = .paused
        logInfo("Reset complete")
    }

    // MARK: - Single Step (for debugger)

    public func stepOne() throws {
        guard state == .paused else { return }
        try cpu.step()
        updateStatsSync()
    }

    // MARK: - Internal

    private func stateIsRunning() async -> Bool {
        await MainActor.run { self.state == .running }
    }

    private func runCoreSlice(core: Int, thread: Int) async throws {
        let t = cpu.threads[core][thread]
        guard t.isRunning || (core == 0 && thread == 0) else { return }
        try cpu.runBurst(burstSize, thread: t)
    }

    private func updateStats() async {
        let now = Date()
        let elapsed = startTime.map { now.timeIntervalSince($0) } ?? 0
        let totalInstr = cpu.totalInstructions

        await MainActor.run {
            var s = EmulatorStats()
            s.totalInstructions = totalInstr
            s.uptime = elapsed
            s.ips = elapsed > 0 ? Double(totalInstr) / elapsed : 0
            s.fps = 30.0  // GPU stub
            s.memUsedMB = 0
            s.threadStats = self.cpu.threads.flatMap { core in
                core.map { t in
                    EmulatorStats.ThreadStat(
                        core: t.coreIndex,
                        thread: t.threadIndex,
                        pc: t.pc,
                        instructionsRun: t.instructionsExecuted
                    )
                }
            }
            self.stats = s
        }
    }

    private func updateStatsSync() {
        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
        stats.totalInstructions = cpu.totalInstructions
        stats.ips = elapsed > 0 ? Double(cpu.totalInstructions) / elapsed : 0
    }

    // MARK: - Logging

    public func logInfo(_ msg: String) {
        appendLog(.info, msg)
    }
    public func logWarning(_ msg: String) {
        appendLog(.warning, msg)
    }
    public func logError(_ msg: String) {
        appendLog(.error, msg)
    }
    public func logDebug(_ msg: String) {
        appendLog(.debug, msg)
    }

    private func appendLog(_ level: LogEntry.Level, _ msg: String) {
        let entry = LogEntry(timestamp: Date(), level: level, message: msg)
        log.append(entry)
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }
}

// MARK: - Kernel HLE

class KernelHLE {
    let memory: XenonMemory
    weak var emulator: Emulator?

    init(memory: XenonMemory, emulator: Emulator) {
        self.memory   = memory
        self.emulator = emulator
    }

    func handleSyscall(thread: XenonThread, index: UInt64) {
        // r3 = first argument, r3 = return value convention
        switch index {
        case 0x01: // NtCreateFile
            thread.gpr[3] = 0  // STATUS_SUCCESS
        case 0x02: // NtReadFile
            thread.gpr[3] = 0xC0000034  // STATUS_OBJECT_NAME_NOT_FOUND (stub)
        case 0x10: // ExAllocatePoolWithTag
            let size = thread.gpr[3]
            // Stub: return address in heap area
            thread.gpr[3] = 0x4000_0000
            Task { @MainActor [weak emulator] in
                emulator?.logDebug(String(format: "ExAllocatePool(size=0x%X)", size))
            }
        case 0x11: // ExFreePool
            thread.gpr[3] = 0
        default:
            Task { @MainActor [weak emulator] in
                emulator?.logDebug(String(format: "Unhandled syscall 0x%X", index))
            }
        }
    }
}
